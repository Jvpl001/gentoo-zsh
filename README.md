# Zsh on Gentoo: Clang + Full LTO Build

A from-scratch Zsh setup for Gentoo, built with Clang and full LTO for fast
startup, paired with a minimal, dependency-trimmed feature set: history
substring search, sane keybindings, and a small toolkit for managing
byte-compiled configs. Written for [`st`](https://st.suckless.org/) but works
in any terminal.

The concepts here — compiler environment files, USE flag trimming,
byte-compilation — are Gentoo/Portage-specific. The Zsh configuration itself
(`.zshrc`, the plugin, the aliases) will work on any distribution; you'll
just need to install Zsh through your own package manager instead of
following Section 3.

An automated installer (`zsh_install.sh`) is included for anyone who'd
rather not do the setup by hand — see [Section 6](#6-automated-installer).

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Manual Setup](#2-manual-setup)
3. [Verifying the Build](#3-verifying-the-build)
4. [Shell Features](#4-shell-features)
5. [Automated Installer](#5-automated-installer)
6. [Credits & Acknowledgments](#6-credits--acknowledgments)

---

## 1. Prerequisites

You need Clang and LLVM's linker:

```bash
doas emerge -av llvm-core/clang llvm-core/lld
```

Confirm they're on your `PATH`:

```bash
command -v clang && command -v ld.lld
```

---

## 2. Manual Setup

### 2.1 Compiler Environment

Portage lets you override compiler flags for a single package without
touching your global `make.conf`, via an environment file. As root:

```bash
mkdir -p /etc/portage/env/
nvim /etc/portage/env/clang_flto.conf
```

**`/etc/portage/env/clang_flto.conf`**

```bash
CC="clang"
CXX="clang++"

# -fdata-sections / -ffunction-sections isolate every function and variable
# into its own linker section, so the linker can identify and drop the ones
# nothing references.
COMMON_FLAGS="-O3 -pipe -march=haswell -mtune=haswell -fno-plt -D_FORTIFY_SOURCE=3 -flto=full -fdata-sections -ffunction-sections"

CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"

# -fuse-ld=lld swaps in LLVM's linker (faster, and required for -icf).
# -Wl,--gc-sections drops the dead sections isolated above.
# -Wl,-icf=all (Identical Code Folding) merges functions that compile down
# to identical machine code, shrinking the binary further.
LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,-z,pack-relative-relocs -Wl,-z,now -Wl,-z,relro -flto=full -fuse-ld=lld -Wl,--gc-sections -Wl,-icf=all"
```

> **Note:** `-march=haswell` targets a specific CPU generation. Change it to
> match the machine you're building on (or use `-march=native` if you're
> building and running on the same box).

Then tell Portage to use it for this package:

**`/etc/portage/package.env/zsh`**

```
app-shells/zsh clang_flto.conf
```

A few notes on what's in there:

| Flag | Why |
|---|---|
| `-fno-plt` + `-Wl,-z,now` | Resolves all dynamic symbols at load time instead of lazily, avoiding the PLT trampoline entirely — a small, free win since eager binding is already forced. |
| `-D_FORTIFY_SOURCE=3` | Adds runtime bounds checking on libc calls like `memcpy`. Requires `-O2` or higher, which is already set. |
| `-Wl,-z,relro` | Marks relocations read-only after startup — hardens the binary at effectively no runtime cost. |
| `-Wl,-z,pack-relative-relocs` | Shrinks the relocation table for a smaller binary on modern linkers/glibc. |
| `-mtune=haswell` | Technically redundant — `-march=haswell` already implies tuning for Haswell. Harmless to leave in, but can be dropped. |

PGO and BOLT were deliberately left out. In an interactive shell, syscalls
are the real bottleneck, not CPU-bound execution — so the extra build
complexity isn't worth it here.

### 2.2 Trimming the USE Flags

Gentoo's `zsh` ebuild ships several optional features an interactive shell
user almost certainly doesn't need:

**`/etc/portage/package.use/zsh`**

```
app-shells/zsh -caps -doc -examples -gdbm -maildir -pcre
```

| Flag | What it does | Why disable it |
|---|---|---|
| `caps` | POSIX capabilities support | Irrelevant unless you're doing privilege-dropping in shell scripts |
| `doc` / `examples` | Installs man pages / example configs | Pure disk bloat — doesn't affect the binary but there's no reason to keep it |
| `gdbm` | Lets Zsh back associative arrays with a GNU dbm file on disk | Not used interactively |
| `maildir` | Maildir-format mailbox support in Zsh's mail-checking code | Nobody uses shell-native mail checking anymore |
| `pcre` | Perl-compatible regex support in Zsh pattern matching | Pulls in `libpcre2` and adds binary size; Zsh's native globbing/regex covers everyday use |

### 2.3 Installing the Packages

```bash
doas emerge -av app-shells/zsh app-shells/gentoo-zsh-completions app-misc/fastfetch
```

`app-misc/fastfetch` is optional — if you don't want it, drop it from the
command above and comment out the corresponding line in `.zshrc` (see
[Section 4](#4-shell-features)).

`app-shells/gentoo-zsh-completions` is also optional but recommended;
managing Gentoo's completion files by hand is more trouble than it's worth.

Set Zsh as your login shell:

```bash
chsh -s /usr/bin/zsh
```

Log out and back in for this to take effect.

### 2.4 History Substring Search Plugin

The `zsh-history-substring-search` package in the `guru` overlay proved
unreliable in testing, so this setup vendors the plugin directly from
upstream instead:

```bash
mkdir -p ~/.zsh/plugins
curl -fsSL https://raw.githubusercontent.com/zsh-users/zsh-history-substring-search/master/zsh-history-substring-search.zsh -o ~/.zsh/plugins/zsh-history-substring-search.zsh
```

The plugin is sourced from its plain-text `.zsh` file rather than a
pre-compiled `.zwc`, because Zsh's `source` command automatically loads the
compiled `.zwc` alongside it if one exists and is newer than the source
file. There's no need to reference the bytecode directly — see
[`zsh-compile`](#41-custom-management-commands) for how it gets compiled.

You'll need to run the command above once on a fresh install so the plugin
file exists before `.zshrc` tries to source it. After that, the
`zsh-plugin-update` function (below) keeps it current.

**Periodically run `compaudit` manually.** `compinit -C` skips this check on
every startup for speed, so it won't catch it automatically. A local
attacker could plant a malicious completion script in an insecure
(group- or world-writable) directory on your `fpath`:

```bash
compaudit
```

---

## 3. Verifying the Build

### 3.1 Confirm Clang Actually Built It

`readelf -p .comment` is the commonly suggested check, but on Gentoo it will
often come back empty regardless of compiler, because Portage strips
binaries by default (`FEATURES="strip"` in `make.conf`, on unless you've
disabled it) — stripping removes `.comment` along with debug symbols. An
empty `.comment` section is **not** proof of anything either way.

A build log is reliable:

```bash
doas emerge -av --oneshot app-shells/zsh
# then check the build log for the actual compiler invocation:
grep -m3 "clang" /var/log/portage/build/app-shells/zsh-*/temp/build.log 2>/dev/null \
  || zcat /var/log/portage/app-shells:zsh-*.log.gz 2>/dev/null | grep -m3 clang
```

Or simpler — confirm the USE flags and environment file applied before the
build even starts:

```bash
equery uses zsh          # confirms -caps -doc -examples -gdbm -maildir -pcre
portageq envvar CC       # sanity check for the global default, not per-package
```

### 3.2 Confirm the USE Flags Stripped the Dependencies

```bash
ldd $(which zsh)
```

Neither `libpcre` nor `libgdbm` should appear. Expect something close to
just `libtinfow`, `libm`, `libc`, and the dynamic linker.

### 3.3 Benchmark Startup

```bash
time ( repeat 100 zsh -i -c exit )
```

Divide the total by 100 for per-shell time. A stock Oh My Zsh setup usually
runs 200–500 ms; this setup should land around 3–8 ms for Zsh itself.
`fastfetch` inside `.zshrc` adds another ~20–30 ms per launch on top of
that — if `fastfetch` is still enabled while benchmarking, don't mistake
its cost for Zsh's.

---

## 4. Shell Features

This setup deliberately avoids frameworks like Oh My Zsh in favor of a
small set of native Zsh features and three helper functions that manage
byte-compilation.

### 4.1 Custom Management Commands

* **`zsh-compile`** — the local optimizer. Byte-compiles `~/.zshrc`, the
  completion cache (`~/.zcompdump`), and local plugins into `.zwc`
  bytecode. It also scans for leftover `.old` backup files and offers an
  interactive prompt to delete them.

* **`zsh-system-compile`** — the Portage bridge. When Portage installs a
  new package, it drops plain-text completion files into
  `/usr/share/zsh/site-functions/`. This command (requires `doas`) sweeps
  that directory, compiles any new completions, cleans up orphaned `.zwc`
  files whose source no longer exists, regenerates the local completion
  cache, and triggers `zsh-compile` to byte-compile the result.

* **`zsh-plugin-update`** — the plugin manager. Checks GitHub for upstream
  changes to `zsh-history-substring-search`, prompts before updating if a
  difference is found, and recompiles the plugin automatically if you
  accept the update.

### 4.2 Aliases, Keybindings & Options

**Keybindings (terminal-agnostic):**

- *Substring history search* — Up/Down are bound to
  `history-substring-search-{up,down}`. Type part of a previous command
  (e.g. `emerge`) and press Up to filter history instantly. Both standard
  terminal escape sequences and `st`'s application-mode sequences are
  bound, so it works the same in either mode.
- *Standard navigation* — Home, End, Delete, and Ctrl+Arrow are bound
  explicitly, since these often don't work out of the box on a fresh Zsh
  install.

**Aliases:**

- *Aesthetics* — `ls`, `grep`, `egrep`, `tree`, and `diff` default to
  color output. `ll`, `la`, and `l` give long/hidden/grid listing variants.
- *Hardware & disks* — `df` and `free` default to human-readable output;
  `lsblk` hides loop devices (`-e7`); `llblk` is a custom, cleaner
  `lsblk` view (`NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT`).
- *Safety nets* — `cp` and `mv` prompt before overwriting a file. `rm`
  prompts once when removing three or more files (`-I`) rather than for
  every single file (`-i`), which is less disruptive. `chown`, `chmod`,
  and `chgrp` all require `--preserve-root`.
- *Gentoo specifics* — `emerge` defaults to `doas emerge -v`; `sync` runs
  `doas emerge --sync`; `search` bypasses the alias with `\emerge -s`;
  `pretend` runs `\emerge -pv`.
- *System control* — `shutdown` and `reboot` are wrapped with `doas`.

**Shell options (`setopt`):**

- *Navigation* — `AUTO_CD` lets you type a directory name to `cd` into it
  without typing `cd`; `AUTO_PUSHD` and `PUSHD_IGNORE_DUPS` maintain a
  clean directory stack you can pop back through.
- *History* — duplicate commands are ignored, extra whitespace is
  stripped before saving, and repeated consecutive lookups are collapsed,
  keeping search results relevant.
- *Interactive comments* — `#` can be used to write notes directly at the
  prompt.

### 4.3 Day-to-Day Workflow

1. **Daily driving** — the shell loads from `.zwc` bytecode in a few
   milliseconds. Navigate without typing `cd`, annotate commands with
   `#`, and recall previous commands with the Up arrow.
2. **After editing configs** — run `zsh-compile` to recompile the
   bytecode and clean up stray `.old` files.
3. **After system updates** — run `zsh-system-compile` after any `emerge`
   that installs new completions, to keep tab-completion fast.

---

## 5. Automated Installer

`zsh_install.sh` automates everything in Sections 1–4 for anyone who'd
rather not configure the system by hand.

### 5.1 What It Does

- **Cryptographic verification** — mounts an isolated, `noexec` tmpfs
  workspace in memory, independently fetches the maintainer's GPG key
  from GitHub to cross-check it against a fingerprint pinned in the
  script, verifies the signature on the release checksum manifest, and
  verifies the SHA-256 checksum of every file before installing anything.
- **Self-updating** — before running, checks the remote repository for a
  newer signed release of the installer itself and, if verification
  passes, restarts using the updated copy.
- **Privilege separation** — refuses to run as root. User-level
  configuration is handled as your normal user; privileges are escalated
  (via `doas` or `sudo`, whichever is available) only for writes under
  `/etc/` or for invoking Portage.
- **Non-destructive deployment** — any existing file the script would
  overwrite is preserved first as a timestamped `<file>.old.<timestamp>`
  backup, and every write is verified by comparing checksums afterward.
- **Post-install verification** — checks `.zshrc` syntax, confirms
  `fastfetch` and its config are present, runs `compaudit`, and confirms
  the installed `zsh` binary doesn't link `libpcre` or `libgdbm`.

### 5.2 Usage

```bash
./zsh_install.sh              # run the installer
./zsh_install.sh --dry-run    # show what would change, without changing anything
./zsh_install.sh --help       # usage
```

A log of each run is written to `${XDG_STATE_HOME:-$HOME/.local/state}/gentoo-zsh/install.log`.

### 5.3 Security Model

On each run, the installer:

1. Refuses to execute as root.
2. Mounts a `noexec,nosuid,nodev` tmpfs workspace for all verification
   work (falls back to ordinary disk only if `GZ_ALLOW_INSECURE_TMP=1` is
   set, and warns when it does).
3. Imports the maintainer's release GPG key and checks its fingerprint
   against the one pinned in the script.
4. Independently fetches the maintainer's public key from
   `https://github.com/<user>.gpg` and confirms it matches the same
   fingerprint, as a second, out-of-band anchor.
5. Verifies the GPG signature on the release's SHA-256 checksum manifest.
6. Verifies the checksum of every file in the release against that signed
   manifest before deploying anything.

If any of these checks fail, the installer stops rather than proceeding
with an unverified file.

### 5.4 Environment Variables

All of the following can be overridden by exporting them before running
the script; the defaults are shown.

| Variable | Default | Purpose |
|---|---|---|
| `REPO_URL` | `https://github.com/jvpl001/gentoo-zsh.git` | Source repository to clone/pull |
| `RAW_URL` | `.../main` (raw content) | Where self-update checks for a newer release |
| `REPO_DIR` | `$HOME/git/gentoo-zsh` | Local clone location |
| `RELEASE_KEY_FPR` | *(pinned in script)* | Expected GPG key fingerprint for release signing |
| `GITHUB_USER` | *(derived from `REPO_URL`)* | GitHub account to anchor the key check against |
| `GZ_ALLOW_INSECURE_TMP` | `0` | Set to `1` to allow falling back to disk if the tmpfs mount fails |
| `GZ_SKIP_SELF_UPDATE` | `0` | Set to `1` to skip the self-update check |

---

## 6. Credits & Acknowledgments

- **[zsh-history-substring-search](https://github.com/zsh-users/zsh-history-substring-search)**
  — vendored under the BSD 3-Clause License. Copyright (c) 2009 Peter
  Stephenson, Guido van Steen, Suraj N. Kurapati, Sorin Ionescu, Vincent
  Guerci, Geza Lore, Bengt Brodersen.
