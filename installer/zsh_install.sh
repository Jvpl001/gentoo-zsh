#!/bin/sh
# gentoo-zsh 0.0.1
# Verified, idempotent Gentoo zsh bootstrap.

set -eu

VERSION=0.0.1
REPO_URL=${REPO_URL:-https://github.com/my_username/gentoo-zsh.git}
RAW_URL=${RAW_URL:-https://raw.githubusercontent.com/my_username/gentoo-zsh/main}
REPO_DIR=${REPO_DIR:-"$HOME/git/gentoo-zsh"}
RELEASE_KEY_FPR=${RELEASE_KEY_FPR:-}
STATE_DIR=${XDG_STATE_HOME:-"$HOME/.local/state"}/gentoo-zsh
LOG_FILE=$STATE_DIR/install.log
STAGES=8
STAGE=0
DRY_RUN=0
NO_UPDATE=${GZ_SKIP_SELF_UPDATE:-0}
ELEVATE=
SOURCE_DIR=
TMP_DIR=
GNUPGHOME=

C_RED= C_GREEN= C_YELLOW= C_BLUE= C_MAGENTA= C_CYAN= C_FG= C_DIM= C_BOLD= C_RESET=
TTY=0 FANCY=0 COLS=80 LINES=24

usage() {
    cat <<EOF2
usage: ${0##*/} [--dry-run] [--no-update] [--help]

  --dry-run    show changes without applying them
  --no-update  skip the self-update check
  --help       show this help
EOF2
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --dry-run) DRY_RUN=1 ;;
        --no-update) NO_UPDATE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

init_ui() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        TTY=1
        if [ -z "${NO_COLOR:-}" ]; then
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
        if command -v tput >/dev/null 2>&1; then
            COLS=$(tput cols 2>/dev/null || printf 80)
            LINES=$(tput lines 2>/dev/null || printf 24)
            [ "$COLS" -ge 40 ] 2>/dev/null && [ "$LINES" -ge 8 ] 2>/dev/null && FANCY=1
        fi
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
fatal() { status FATAL "$@" >&2; exit 1; }

progress() {
    percent=$((STAGE * 100 / STAGES))
    width=$((COLS / 2))
    [ "$width" -lt 20 ] && width=20
    [ "$width" -gt 60 ] && width=60
    filled=$((percent * width / 100))
    empty=$((width - filled))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')
    text=$(printf '%3d%% [%s]' "$percent" "$bar")

    if [ "$FANCY" -eq 1 ]; then
        col=$(((COLS - ${#text}) / 2))
        [ "$col" -lt 0 ] && col=0
        tput sc 2>/dev/null || return 0
        tput cup $((LINES - 1)) "$col" 2>/dev/null || {
            tput rc 2>/dev/null || :
            return 0
        }
        printf '%s%s%s' "$C_MAGENTA" "$text" "$C_RESET"
        tput rc 2>/dev/null || :
    else
        printf '%s%s%s\n' "$C_DIM" "$text" "$C_RESET"
    fi
}

stage() {
    STAGE=$((STAGE + 1))
    printf '\n%s::%s %s%s%s\n' "$C_MAGENTA" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
    log "== $* =="
    progress
}

cleanup() {
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

on_signal() {
    warn 'interrupted; installed files were not rolled back'
    exit 130
}

trap cleanup 0
trap 'cleanup; exit 129' HUP
trap on_signal INT TERM

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s[DRY]%s' "$C_BLUE" "$C_RESET"
        for arg do printf ' %s' "$arg"; done
        printf '\n'
        return 0
    fi
    "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || fatal "required command not found: $1"; }

fetch() {
    url=$1
    out=$2
    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 10 --max-time 120 "$url" -o "$out"
}

setup() {
    umask 077
    mkdir -p "$STATE_DIR" || fatal "cannot create state directory: $STATE_DIR"
    : >"$LOG_FILE" || fatal "cannot write log: $LOG_FILE"
    init_ui
    [ "$(id -u)" -ne 0 ] || fatal 'run as a normal user'

    for command_name in git curl sha256sum gpg cmp awk sed grep cut date mkdir cp mv chmod id getent chsh emerge tee ldd mktemp tr; do
        need "$command_name"
    done

    [ -n "$RELEASE_KEY_FPR" ] || fatal 'release-key fingerprint is not configured'

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gentoo-zsh.XXXXXX") || fatal 'cannot create temporary directory'
    GNUPGHOME=$TMP_DIR/gnupg
    mkdir -m 700 "$GNUPGHOME" || fatal 'cannot create temporary GnuPG home'
    export GNUPGHOME

    status INFO "gentoo-zsh $VERSION"
    status INFO "log: $LOG_FILE"
    [ "$DRY_RUN" -eq 0 ] || warn 'dry run: no system or user files will be changed'
}

normalize_fingerprint() {
    printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

import_release_key() {
    key_file=$1
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
    [ -s "$manifest" ] || fatal "checksum manifest is missing or empty: $manifest"
    [ -s "$signature" ] || fatal "checksum signature is missing or empty: $signature"
    gpg --batch --quiet --verify "$signature" "$manifest" >/dev/null 2>&1 ||
        fatal 'checksum manifest signature verification failed'
    ok 'checksum manifest signature verified'
}

verify_tree() {
    root=$1
    manifest=$root/security/sha256sums.txt
    signature=$root/security/sha256sums.txt.asc
    key=$root/security/release-key.asc

    [ -d "$root" ] || fatal "source tree is unavailable: $root"
    import_release_key "$key"
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
    [ -f "$root/portage/clang_flto.conf" ] &&
    [ -f "$root/VERSION" ]
}

self_update() {
    stage 'signed update check'
    [ "$NO_UPDATE" -eq 0 ] || {
        ok 'self-update skipped'
        return
    }

    update=$TMP_DIR/update
    mkdir -p "$update/installer" "$update/security" || fatal 'cannot prepare update directory'

    if ! fetch "$RAW_URL/VERSION" "$update/VERSION" ||
       ! fetch "$RAW_URL/security/release-key.asc" "$update/security/release-key.asc" ||
       ! fetch "$RAW_URL/security/sha256sums.txt" "$update/security/sha256sums.txt" ||
       ! fetch "$RAW_URL/security/sha256sums.txt.asc" "$update/security/sha256sums.txt.asc" ||
       ! fetch "$RAW_URL/installer/zsh_install.sh" "$update/installer/zsh_install.sh"; then
        warn 'remote update metadata is unavailable; continuing with the current installer'
        return
    fi

    import_release_key "$update/security/release-key.asc"
    verify_signature "$update/security/sha256sums.txt" "$update/security/sha256sums.txt.asc"

    expected=$(awk '$2=="installer/zsh_install.sh" || $2=="VERSION" {print; found[$2]=1} END {if (!found["installer/zsh_install.sh"] || !found["VERSION"]) exit 1}' \
        "$update/security/sha256sums.txt") || fatal 'installer or VERSION checksum is absent from the signed manifest'

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

choose_source() {
    stage 'source acquisition'

    current=$(pwd)
    if source_tree_present "$current"; then
        verify_tree "$current"
        SOURCE_DIR=$current
        ok 'using the verified current directory'
        return
    fi

    mkdir -p "${REPO_DIR%/*}" || fatal "cannot create repository parent: ${REPO_DIR%/*}"

    if [ ! -d "$REPO_DIR/.git" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            SOURCE_DIR=$TMP_DIR/repository
            git clone --quiet "$REPO_URL" "$SOURCE_DIR" || fatal 'git clone failed'
            source_tree_present "$SOURCE_DIR" || fatal 'repository is missing required release files'
            verify_tree "$SOURCE_DIR"
            ok "verified remote repository; would install it at $REPO_DIR"
            return
        fi
        git clone --quiet "$REPO_URL" "$REPO_DIR" || fatal 'git clone failed'
    else
        dirty=$(git -C "$REPO_DIR" status --porcelain) || fatal 'cannot inspect repository state'
        [ -z "$dirty" ] || fatal "repository contains local changes: $REPO_DIR"
        run git -C "$REPO_DIR" pull --quiet --ff-only ||
            fatal 'repository update is not a clean fast-forward'
    fi

    source_tree_present "$REPO_DIR" || fatal 'repository is missing required release files'
    verify_tree "$REPO_DIR"
    SOURCE_DIR=$REPO_DIR
    ok "verified repository: $REPO_DIR"
}

privileges() {
    stage 'privilege gate'

    if command -v doas >/dev/null 2>&1; then
        ELEVATE=doas
    elif command -v sudo >/dev/null 2>&1; then
        ELEVATE=sudo
    else
        fatal 'neither doas nor sudo is installed'
    fi

    [ "$DRY_RUN" -eq 1 ] || "$ELEVATE" true || fatal "$ELEVATE authentication failed"
    ok "privileged operations grouped through $ELEVATE"
}

install_root_file() {
    src=$1
    dest=$2

    [ -f "$src" ] || fatal "source file is missing: $src"
    if [ -f "$dest" ] && cmp -s "$src" "$dest" 2>/dev/null; then
        ok "$dest is current"
        return
    fi

    stamp=$(date +%Y%m%d-%H%M%S)
    run "$ELEVATE" mkdir -p "${dest%/*}" || fatal "cannot create directory: ${dest%/*}"

    if [ -f "$dest" ]; then
        run "$ELEVATE" cp -p "$dest" "$dest.old.$stamp" || fatal "cannot preserve existing file: $dest"
        warn "preserved previous file as $dest.old.$stamp"
    fi

    run "$ELEVATE" cp "$src" "$dest" || fatal "cannot install file: $dest"
    [ "$DRY_RUN" -eq 1 ] || cmp -s "$src" "$dest" || fatal "post-copy verification failed: $dest"
    ok "installed $dest"
}

root_phase() {
    stage 'toolchain and portage'

    if ! command -v clang >/dev/null 2>&1 || ! command -v ld.lld >/dev/null 2>&1; then
        run "$ELEVATE" emerge -q llvm-core/clang llvm-core/lld || fatal 'clang/lld emerge failed'
    fi

    [ "$DRY_RUN" -eq 1 ] || {
        command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1
    } || fatal 'clang or ld.lld is unavailable after emerge'
    ok 'clang and lld available'

    install_root_file "$SOURCE_DIR/portage/clang_flto.conf" /etc/portage/env/clang_flto.conf

    printf '%s\n' 'app-shells/zsh clang_flto.conf' >"$TMP_DIR/package.env.zsh" || fatal 'cannot stage package.env'
    printf '%s\n' 'app-shells/zsh -caps -doc -examples -gdbm -maildir -pcre' >"$TMP_DIR/package.use.zsh" || fatal 'cannot stage package.use'
    install_root_file "$TMP_DIR/package.env.zsh" /etc/portage/package.env/zsh
    install_root_file "$TMP_DIR/package.use.zsh" /etc/portage/package.use/zsh

    run "$ELEVATE" emerge -q app-shells/zsh app-shells/gentoo-zsh-completions app-misc/fastfetch ||
        fatal 'package emerge failed; inspect /var/log/portage and re-run'
    [ "$DRY_RUN" -eq 1 ] || command -v zsh >/dev/null 2>&1 || fatal 'zsh is unavailable after emerge'
    ok 'zsh, completions, and fastfetch installed'
}

install_user_file() {
    src=$1
    dest=$2

    [ -f "$src" ] || fatal "source file is missing: $src"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        ok "$dest is current"
        return
    fi

    stamp=$(date +%Y%m%d-%H%M%S)
    run mkdir -p "${dest%/*}" || fatal "cannot create directory: ${dest%/*}"

    if [ -f "$dest" ] || [ -L "$dest" ]; then
        run mv "$dest" "$dest.old.$stamp" || fatal "cannot preserve existing file: $dest"
        warn "preserved previous file as $dest.old.$stamp"
    fi

    run cp "$src" "$dest" || fatal "cannot install file: $dest"
    [ "$DRY_RUN" -eq 1 ] || cmp -s "$src" "$dest" || fatal "post-copy verification failed: $dest"
    ok "installed $dest"
}

user_phase() {
    stage 'user configuration'

    install_user_file "$SOURCE_DIR/configs/.zshrc" "$HOME/.zshrc"
    install_user_file "$SOURCE_DIR/configs/fastfetch/config.jsonc" "$HOME/.config/fastfetch/config.jsonc"

    plugin_dir=$HOME/.zsh/plugins
    plugin=$plugin_dir/zsh-history-substring-search.zsh
    plugin_tmp=$TMP_DIR/zsh-history-substring-search.zsh
    run mkdir -p "$plugin_dir" || fatal "cannot create plugin directory: $plugin_dir"

    fetch https://raw.githubusercontent.com/zsh-users/zsh-history-substring-search/master/zsh-history-substring-search.zsh "$plugin_tmp" ||
        fatal 'history plugin download failed'
    [ "$DRY_RUN" -eq 1 ] || zsh -n "$plugin_tmp" || fatal 'history plugin failed zsh syntax validation'
    install_user_file "$plugin_tmp" "$plugin"
    ok 'user configuration deployed'
}

shell_phase() {
    stage 'shell handover'

    zsh_path=$(command -v zsh 2>/dev/null || printf /usr/bin/zsh)
    [ "$DRY_RUN" -eq 1 ] || [ -x "$zsh_path" ] || fatal "zsh is not executable: $zsh_path"

    if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '%s[DRY]%s register %s in /etc/shells\n' "$C_BLUE" "$C_RESET" "$zsh_path"
        else
            printf '%s\n' "$zsh_path" | "$ELEVATE" tee -a /etc/shells >/dev/null ||
                fatal 'cannot register zsh in /etc/shells'
        fi
        ok "registered $zsh_path in /etc/shells"
    fi

    current=$(getent passwd "$(id -un)" | cut -d: -f7) || fatal 'cannot determine current login shell'
    if [ "$current" != "$zsh_path" ]; then
        run "$ELEVATE" chsh -s "$zsh_path" "$(id -un)" || fatal 'cannot change login shell'
    fi
    ok "login shell: $zsh_path"
}

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
        ok 'zsh linkage matches the trimmed USE configuration'
    fi

    ok 'all fatal checks passed'
}

finish() {
    STAGE=$STAGES
    progress
    printf '\n%s%sINSTALL COMPLETE%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    status INFO "repository kept at $REPO_DIR"
    status INFO 'existing files were preserved as timestamped backups'
    status INFO 'log out and back in, or run: exec zsh'
}

main() {
    setup
    printf '%s%sGENTOO-ZSH%s\n' "$C_BOLD" "$C_FG" "$C_RESET"
    status INFO 'signed manifest / clang + lld / full LTO'
    self_update
    choose_source
    privileges
    root_phase
    user_phase
    shell_phase
    verify_install
    finish
}

main
