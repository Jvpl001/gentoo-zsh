#!/bin/sh
# gentoo-zsh 0.0.2
# Portable UNIX shell with deterministic behavior.

set -eu

VERSION=0.0.2
REPO_URL=${REPO_URL:-https://github.com/jvpl001/gentoo-zsh.git}
RAW_URL=${RAW_URL:-https://raw.githubusercontent.com/jvpl001/gentoo-zsh/main}
REPO_DIR=${REPO_DIR:-"$HOME/git/gentoo-zsh"}
RELEASE_KEY_FPR=${RELEASE_KEY_FPR:-3AE1C31BCB1BA4E28D03999292B34C8F075C2F93}
STATE_DIR=${XDG_STATE_HOME:-"$HOME/.local/state"}/gentoo-zsh
LOG_FILE=$STATE_DIR/install.log
GH_ANCHOR_USER=${GITHUB_USER:-}
ALLOW_INSECURE_TMP=${GZ_ALLOW_INSECURE_TMP:-0}

readonly VERSION REPO_URL RAW_URL REPO_DIR RELEASE_KEY_FPR STATE_DIR LOG_FILE ALLOW_INSECURE_TMP

DRY_RUN=0
NO_UPDATE=${GZ_SKIP_SELF_UPDATE:-0}
ELEVATE=
SOURCE_DIR=
TMP_DIR=
TMP_MOUNTED=0
GNUPGHOME=
SHELL_CHANGED=1

C_RED= C_GREEN= C_YELLOW= C_BLUE= C_MAGENTA= C_CYAN= C_FG= C_DIM= C_BOLD= C_RESET=

################################
# UI
################################

usage() {
  cat <<EOF2
usage: ${0##*/} [--dry-run] [--help]

  --dry-run    show changes without applying them
  --help       show this help
EOF2
}

while [ "$#" -gt 0 ]; do
  case $1 in
  --dry-run) DRY_RUN=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  esac
  shift
done

setup_terminal() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$(printf '\033[38;2;234;27;27m')
    C_GREEN=$(printf '\033[38;2;44;233;42m')
    C_YELLOW=$(printf '\033[38;2;235;93;20m')
    C_BLUE=$(printf '\033[38;2;11;88;229m')
    C_MAGENTA=$(printf '\033[38;2;124;33;216m')
    C_CYAN=$(printf '\033[38;2;42;211;171m')
    C_FG=$(printf '\033[38;2;192;245;198m')
    C_DIM=$(printf '\033[2m')
    C_BOLD=$(printf '\033[1m')
    C_RESET=$(printf '\033[0m')
  fi
}

log() { printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || :; }

status() {
  kind=$1
  shift
  case $kind in
  OK) color=$C_GREEN ;;
  WARNING) color=$C_YELLOW ;;
  FATAL) color=$C_RED ;;
  INFO) color=$C_CYAN ;;
  *) color=$C_FG ;;
  esac
  printf '%s[%s]%s %s\n' "$color" "$kind" "$C_RESET" "$*"
  log "[$kind] $*"
}

ok() { status OK "$@"; }
warn() { status WARNING "$@" >&2; }
fatal() {
  status FATAL "$@" >&2
  exit 1
}

stage() {
  printf '\n%s::%s %s%s%s\n' "$C_MAGENTA" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
  log "== $* =="
}

################################
# Helpers
################################

cleanup() {
  if [ "$TMP_MOUNTED" -eq 1 ] && [ -n "${TMP_DIR:-}" ]; then
    "$ELEVATE" umount "$TMP_DIR" >/dev/null 2>&1 || :
  fi
  [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || :
}

on_signal() {
  warn 'interrupted; installed files were not rolled back'
  exit 130
}

trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap on_signal INT TERM

need() { command -v "$1" >/dev/null 2>&1 || fatal "required command not found: $1"; }

check_core_dependencies() { need awk sed grep cut tr cmp mkdir cp mv chmod id date mktemp tee getent chsh; }
require_network() { need git curl; }
require_crypto() { need sha256sum gpg; }
require_gentoo() { need emerge; }
require_mount() { need mount umount; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    status INFO "would execute: $*"
  else
    "$@"
  fi
}

run_elevated() {
  if [ "$DRY_RUN" -eq 1 ]; then
    status INFO "would execute as root: $*"
  else
    "$ELEVATE" "$@"
  fi
}

setup_logging() {
  mkdir -p "$STATE_DIR" || fatal "cannot create state directory: $STATE_DIR"
  : >"$LOG_FILE" || fatal "cannot write log: $LOG_FILE"
}

setup() {
  umask 077
  setup_logging
  setup_terminal
  [ "$(id -u)" -ne 0 ] || fatal 'installer must be run as a normal user (not root)'
  check_core_dependencies
  [ -n "$RELEASE_KEY_FPR" ] || fatal 'release-key fingerprint is not configured'

  status INFO "gentoo-zsh $VERSION"
  status INFO "log: $LOG_FILE"
  [ "$DRY_RUN" -eq 0 ] || warn 'dry run: no system or user files will be changed'
}

setup_secure_tmp() {
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gentoo-zsh.XXXXXX") || fatal 'cannot create temporary directory'

  if [ "$DRY_RUN" -eq 1 ]; then
    status INFO "verification workspace (ordinary, dry run): $TMP_DIR"
    return 0
  fi

  require_mount
  if run_elevated mount -t tmpfs -o "size=128m,mode=0700,uid=$(id -u),gid=$(id -g),noexec,nosuid,nodev" tmpfs "$TMP_DIR"; then
    TMP_MOUNTED=1
    ok "verification workspace is an isolated, memory-only, noexec mount: $TMP_DIR"
    return 0
  fi

  if [ "$ALLOW_INSECURE_TMP" -eq 1 ]; then
    warn "tmpfs mount failed; continuing on ordinary disk because GZ_ALLOW_INSECURE_TMP=1"
    return 0
  fi

  fatal "could not mount a hardened tmpfs at $TMP_DIR — refusing to verify or extract release files on ordinary disk (set GZ_ALLOW_INSECURE_TMP=1 to override)"
}

setup_gpg() {
  GNUPGHOME=$TMP_DIR/gnupg
  mkdir -m 700 "$GNUPGHOME" || fatal 'cannot create temporary GnuPG home'
  export GNUPGHOME
  readonly GNUPGHOME
}

fetch() {
  url=$1
  out=$2
  desc=${3:-$url}
  require_network
  if ! curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 10 --max-time 120 "$url" -o "$out" >>"$LOG_FILE" 2>&1; then
    warn "download failed: $desc"
    return 1
  fi
}

deploy_file() {
  src=$1
  dest=$2
  elevated=${3:-0}

  [ -f "$src" ] || fatal "source file is missing: $src"

  if [ -f "$dest" ] && cmp -s "$src" "$dest" 2>/dev/null; then
    ok "$dest is current"
    return 0
  fi

  stamp=$(date +%Y%m%d-%H%M%S)
  dest_dir=${dest%/*}
  stage_file=$dest_dir/.$(basename "$dest").new.$stamp

  if [ "$elevated" -eq 1 ]; then
    run_elevated mkdir -p "$dest_dir"
    if [ -f "$dest" ] || [ -L "$dest" ]; then
      run_elevated cp -p "$dest" "$dest.old.$stamp"
      warn "preserved previous file as $dest.old.$stamp"
    fi
    run_elevated cp "$src" "$stage_file"
    run_elevated mv -f "$stage_file" "$dest"
  else
    run mkdir -p "$dest_dir"
    if [ -f "$dest" ] || [ -L "$dest" ]; then
      run cp -p "$dest" "$dest.old.$stamp"
      warn "preserved previous file as $dest.old.$stamp"
    fi
    run cp "$src" "$stage_file"
    run mv -f "$stage_file" "$dest"
  fi

  [ "$DRY_RUN" -eq 1 ] || cmp -s "$src" "$dest" || fatal "post-copy verification failed: $dest"
  ok "installed $dest"
}

################################
# Verification
################################

normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

github_user() {
  [ -z "$GH_ANCHOR_USER" ] || {
    printf '%s\n' "$GH_ANCHOR_USER"
    return 0
  }
  printf '%s\n' "$REPO_URL" |
    sed -n \
      -e 's#^https\{0,1\}://github\.com/\([^/]*\)/.*#\1#p' \
      -e 's#^git@github\.com:\([^/]*\)/.*#\1#p'
}

verify_github_anchor() {
  gh_user=$(github_user)
  if [ -z "$gh_user" ]; then
    warn 'could not determine a GitHub username from REPO_URL — skipping the independent key anchor check'
    return 0
  fi

  anchor=$TMP_DIR/github-account.gpg
  if ! fetch "https://github.com/$gh_user.gpg" "$anchor" "GitHub account public key ($gh_user)"; then
    warn 'could not reach github.com to independently confirm the release key — proceeding on the pinned fingerprint alone'
    return 0
  fi
  [ -s "$anchor" ] || {
    warn "github.com/$gh_user.gpg returned nothing — skipping the independent key anchor check"
    return 0
  }

  anchor_fpr=$(gpg --batch --quiet --with-colons --import-options show-only --import "$anchor" 2>/dev/null |
    awk -F: '$1=="fpr" {print $10; exit}')
  if [ -z "$anchor_fpr" ]; then
    warn "github.com/$gh_user.gpg had no readable fingerprint — skipping the independent key anchor check"
    return 0
  fi

  expected=$(normalize_fingerprint "$RELEASE_KEY_FPR")
  actual=$(normalize_fingerprint "$anchor_fpr")
  [ "$actual" = "$expected" ] ||
    fatal "the key GitHub publishes for $gh_user does not match the pinned release fingerprint — refusing to continue"
  ok "pinned fingerprint independently confirmed against github.com/$gh_user.gpg"
}

import_release_key() {
  key_file=$1
  require_crypto
  [ -s "$key_file" ] || fatal "release public key is missing or empty: $key_file"

  imported=$(gpg --batch --quiet --with-colons --import-options show-only --import "$key_file" 2>/dev/null |
    awk -F: '$1=="fpr" {print $10; exit}')
  [ -n "$imported" ] || fatal 'release public key has no readable fingerprint'

  expected=$(normalize_fingerprint "$RELEASE_KEY_FPR")
  actual=$(normalize_fingerprint "$imported")
  [ "$actual" = "$expected" ] || fatal 'release public-key fingerprint does not match the pinned fingerprint'

  gpg --batch --quiet --import "$key_file" >/dev/null 2>&1 || fatal 'release public-key import failed'
  ok "release key verified: $actual"
}

verify_signature() {
  manifest=$1
  signature=$2
  require_crypto
  [ -s "$manifest" ] || fatal "checksum manifest is missing or empty: $manifest"
  [ -s "$signature" ] || fatal "checksum signature is missing or empty: $signature"
  gpg --batch --quiet --verify "$signature" "$manifest" >/dev/null 2>&1 ||
    fatal 'checksum manifest signature verification failed'
  ok 'checksum manifest signature verified'
}

verify_release() {
  root=$1
  manifest=$root/security/sha256sums.txt
  signature=$root/security/sha256sums.txt.asc
  key=$root/security/release-key.asc

  require_crypto
  [ -d "$root" ] || fatal "source tree is unavailable: $root"
  import_release_key "$key"
  verify_github_anchor
  verify_signature "$manifest" "$signature"
  (cd "$root" && sha256sum -c security/sha256sums.txt >/dev/null 2>&1) ||
    fatal "SHA256 verification failed: $root"
  ok 'all signed payload checksums verified'
}

source_tree_present() {
  root=$1
  [ -f "$root/security/sha256sums.txt" ] &&
    [ -f "$root/security/sha256sums.txt.asc" ] &&
    [ -f "$root/security/release-key.asc" ] &&
    [ -f "$root/installer/zsh_install.sh" ] &&
    [ -f "$root/configs/.zshrc" ] &&
    [ -f "$root/configs/fastfetch/config.jsonc" ] &&
    [ -f "$root/configs/plugins/zsh-history-substring-search.zsh" ] &&
    [ -f "$root/portage/clang_flto.conf" ] &&
    [ -f "$root/VERSION" ]
}

################################
# Repository
################################

self_update() {
  stage 'signed update check'
  [ "$NO_UPDATE" -eq 0 ] || {
    ok 'self-update skipped'
    return
  }

  require_network
  require_crypto

  update=$TMP_DIR/update
  mkdir -p "$update/installer" "$update/security" || fatal 'cannot prepare update directory'

  if ! fetch "$RAW_URL/VERSION" "$update/VERSION" "remote VERSION" ||
    ! fetch "$RAW_URL/security/release-key.asc" "$update/security/release-key.asc" "release public key" ||
    ! fetch "$RAW_URL/security/sha256sums.txt" "$update/security/sha256sums.txt" "checksum manifest" ||
    ! fetch "$RAW_URL/security/sha256sums.txt.asc" "$update/security/sha256sums.txt.asc" "manifest signature" ||
    ! fetch "$RAW_URL/installer/zsh_install.sh" "$update/installer/zsh_install.sh" "remote installer"; then
    warn 'remote update metadata unavailable'
    status INFO 'continuing with verified local release'
    return
  fi

  import_release_key "$update/security/release-key.asc"
  verify_github_anchor
  verify_signature "$update/security/sha256sums.txt" "$update/security/sha256sums.txt.asc"

  expected=$(awk '$2=="installer/zsh_install.sh" || $2=="VERSION" {print; found[$2]=1} END {if (!found["installer/zsh_install.sh"] || !found["VERSION"]) exit 1}' \
    "$update/security/sha256sums.txt") || fatal 'installer or VERSION checksum is absent from signed manifest'

  (cd "$update" && printf '%s\n' "$expected" | sha256sum -c - >/dev/null 2>&1) ||
    fatal 'remote installer or VERSION failed SHA256 verification'

  remote_version=$(sed -n '1p' "$update/VERSION")
  [ -n "$remote_version" ] || fatal 'remote VERSION is empty'

  if [ "$remote_version" != "$VERSION" ] || ! cmp -s "$update/installer/zsh_install.sh" "$0" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      ok "signed installer $remote_version is available"
      return
    fi

    next_installer=$STATE_DIR/zsh_install.next
    cp "$update/installer/zsh_install.sh" "$next_installer" || fatal 'cannot stage updated installer'
    chmod 700 "$next_installer" || fatal 'cannot make updated installer executable'
    ok "signed installer $remote_version verified; restarting"
    GZ_SKIP_SELF_UPDATE=1 exec "$next_installer"
    fatal 'cannot execute updated installer'
  fi

  ok "installer is current ($VERSION)"
}

find_local_repository() {
  dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/security/sha256sums.txt" ] && [ -f "$dir/VERSION" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

clone_repository() {
  target=$1
  require_network

  staging=$TMP_DIR/repository
  git clone --quiet "$REPO_URL" "$staging" || fatal 'git clone failed'
  source_tree_present "$staging" || fatal 'repository missing release files'
  verify_release "$staging"

  if [ "$DRY_RUN" -eq 1 ]; then
    status INFO "verified remote repository; would install at $target"
    SOURCE_DIR=$staging
    return 0
  fi

  mkdir -p "${target%/*}" || fatal "cannot create parent directory: ${target%/*}"
  mv "$staging" "$target" || fatal "cannot move verified repository into place: $target"
  SOURCE_DIR=$target
}

update_repository() {
  target=$1
  require_network

  dirty=$(git -C "$target" status --porcelain) || fatal 'cannot inspect repository state'
  [ -z "$dirty" ] || fatal "repository contains local uncommitted changes: $target"

  if [ "$DRY_RUN" -eq 1 ]; then
    status INFO "would pull latest updates into $target"
  else
    git -C "$target" pull --quiet --ff-only || fatal 'repository update is not a clean fast-forward'
    source_tree_present "$target" || fatal 'repository missing release files'
    verify_release "$target"
  fi
  SOURCE_DIR=$target
}

choose_source() {
  stage 'source acquisition'

  current=$(find_local_repository) || current=""
  if [ -n "$current" ] && source_tree_present "$current"; then
    verify_release "$current"
    SOURCE_DIR=$current
    ok "using verified repository at $current"
    return 0
  fi

  if [ ! -d "$REPO_DIR/.git" ]; then
    clone_repository "$REPO_DIR"
  else
    update_repository "$REPO_DIR"
  fi

  ok "verified repository: $SOURCE_DIR"
}

################################
# Installation
################################

privileges() {
  stage 'privilege gate'

  if command -v doas >/dev/null 2>&1; then
    ELEVATE=doas
  elif command -v sudo >/dev/null 2>&1; then
    ELEVATE=sudo
  else
    fatal 'neither doas nor sudo is installed'
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    "$ELEVATE" true || fatal "$ELEVATE authentication failed"
  fi
  ok "using $ELEVATE for privileged operations"
}

root_phase() {
  stage 'toolchain and portage'
  require_gentoo

  if ! command -v clang >/dev/null 2>&1 || ! command -v ld.lld >/dev/null 2>&1; then
    run_elevated emerge -q llvm-core/clang llvm-core/lld || fatal 'clang/lld emerge failed'
  fi

  [ "$DRY_RUN" -eq 1 ] || { command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; } || fatal 'clang or ld.lld is unavailable after emerge'
  ok 'clang and lld available'

  deploy_file "$SOURCE_DIR/portage/clang_flto.conf" /etc/portage/env/clang_flto.conf 1

  printf '%s\n' 'app-shells/zsh clang_flto.conf' >"$TMP_DIR/package.env.zsh" || fatal 'cannot stage package.env'
  printf '%s\n' 'app-shells/zsh -caps -doc -examples -gdbm -maildir -pcre' >"$TMP_DIR/package.use.zsh" || fatal 'cannot stage package.use'

  deploy_file "$TMP_DIR/package.env.zsh" /etc/portage/package.env/zsh 1
  deploy_file "$TMP_DIR/package.use.zsh" /etc/portage/package.use/zsh 1

  run_elevated emerge -q app-shells/zsh app-shells/gentoo-zsh-completions app-misc/fastfetch || fatal 'package emerge failed; inspect /var/log/portage'

  [ "$DRY_RUN" -eq 1 ] || { command -v zsh >/dev/null 2>&1 || fatal 'zsh is unavailable after emerge'; }
  ok 'zsh, completions, and fastfetch installed'
}

user_phase() {
  stage 'user configuration'

  deploy_file "$SOURCE_DIR/configs/.zshrc" "$HOME/.zshrc" 0
  deploy_file "$SOURCE_DIR/configs/fastfetch/config.jsonc" "$HOME/.config/fastfetch/config.jsonc" 0

  plugin_dir=$HOME/.zsh/plugins
  plugin=$plugin_dir/zsh-history-substring-search.zsh
  plugin_src=$SOURCE_DIR/configs/plugins/zsh-history-substring-search.zsh

  run mkdir -p "$plugin_dir" || fatal "cannot create plugin directory: $plugin_dir"

  [ "$DRY_RUN" -eq 1 ] || zsh -n "$plugin_src" || fatal 'history plugin failed zsh syntax validation'
  deploy_file "$plugin_src" "$plugin" 0

  ok 'user configuration deployed'
}

shell_phase() {
  stage 'shell handover'

  zsh_path=$(command -v zsh 2>/dev/null || printf /usr/bin/zsh)
  [ "$DRY_RUN" -eq 1 ] || [ -x "$zsh_path" ] || fatal "zsh is not executable: $zsh_path"

  if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      status INFO "would register $zsh_path in /etc/shells"
    else
      printf '%s\n' "$zsh_path" | "$ELEVATE" tee -a /etc/shells >/dev/null || fatal 'cannot register zsh in /etc/shells'
    fi
    ok "registered $zsh_path in /etc/shells"
  else
    ok "$zsh_path is registered in /etc/shells"
  fi

  current=$(getent passwd "$(id -un)" | cut -d: -f7) || fatal 'cannot determine current login shell'
  if [ "$current" != "$zsh_path" ]; then
    if run_elevated chsh -s "$zsh_path" "$(id -un)"; then
      ok "login shell changed to $zsh_path"
    else
      SHELL_CHANGED=0
      warn "chsh failed — your login shell is still $current, not $zsh_path"
      warn "chsh sometimes wants its own confirmation on top of $ELEVATE, or refuses to run non-interactively through it. Try by hand:"
      warn "  chsh -s $zsh_path              (self-service, prompts for your own password)"
      warn "  $ELEVATE chsh -s $zsh_path $(id -un)   (if the above refuses)"
    fi
  else
    ok "login shell is already $zsh_path"
  fi
}

################################
# Verification (Post)
################################

verify_install() {
  stage 'verification'

  [ "$DRY_RUN" -eq 1 ] && {
    ok 'verification skipped in dry-run mode'
    return
  }

  zsh -n "$HOME/.zshrc" || fatal '.zshrc failed syntax validation'
  command -v fastfetch >/dev/null 2>&1 || fatal 'fastfetch is unavailable'
  [ -s "$HOME/.config/fastfetch/config.jsonc" ] || fatal 'fastfetch configuration is missing or empty'

  if zsh -fc 'autoload -Uz compaudit; [ -z "$(compaudit)" ]'; then
    ok 'completion paths passed compaudit'
  else
    warn 'compaudit found insecure completion paths'
  fi

  if ldd "$(command -v zsh)" 2>/dev/null | grep -Eq 'libpcre|libgdbm'; then
    warn 'zsh still links pcre or gdbm'
  else
    ok 'zsh linkage matches trimmed USE configuration'
  fi

  ok 'all fatal checks passed'
}

################################
# Finish
################################

finish() {
  printf '\n%s%s== GENTOO-ZSH %s INSTALLED ==%s\n\n' "$C_BOLD" "$C_GREEN" "$VERSION" "$C_RESET"
  status INFO "repository kept at $REPO_DIR"
  status INFO 'existing files were preserved as timestamped backups'
  if [ "$SHELL_CHANGED" -eq 1 ]; then
    status INFO 'log out and back in, or run: exec zsh'
  else
    status WARNING 'chsh did not succeed — see the shell handover warning above before you log out'
  fi
}

main() {
  setup
  privileges
  setup_secure_tmp
  setup_gpg

  printf '%s%sGENTOO-ZSH%s\n' "$C_BOLD" "$C_FG" "$C_RESET"
  status INFO 'signed manifest / clang + lld / full LTO'

  self_update
  choose_source
  root_phase
  user_phase
  shell_phase
  verify_install

  finish
}

main
