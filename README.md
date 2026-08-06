# Zsh on Gentoo: Clang + Full LTO Build

A from-scratch Zsh setup for Gentoo, built with Clang and full LTO for fast
startup, paired with a minimal, dependency-trimmed feature set: history
substring search, sane keybindings, and a small toolkit for managing
byte-compiled configs. Written for [`st`](https://st.suckless.org/) but works
in any terminal.

The Gentoo-specific parts (compiler environment files, USE flags,
byte-compilation) only apply on Gentoo. The `.zshrc` itself — the plugin,
aliases, and keybindings — will work on any distribution; just install Zsh
through your own package manager instead of following Section 1.

An automated installer (`zsh_install.sh`) is included if you'd rather not
do this by hand — see [Automated Installer](#automated-installer).

---

## Prerequisites

You need Clang and LLVM's linker:

```bash
doas emerge -av llvm-core/clang llvm-core/lld
```

Confirm they're on your `PATH`:

```bash
command -v clang && command -v ld.lld
```

---

## Manual Setup

### Compiler environment

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

> `-march=haswell` targets a specific CPU generation — change it to match
> your machine (or use `-march=native` if you're building and running on
> the same box).

Tell Portage to use it for this package:

**`/etc/portage/package.env/zsh`**

```
app-shells/zsh clang_flto.conf
```

A few notes on what's in there:

| Flag | Why |
|---|---|
| `-fno-plt` + `-Wl,-z,now` | Resolves dynamic symbols at load time instead of lazily, avoiding the PLT trampoline — free since eager binding is already forced. |
| `-D_FORTIFY_SOURCE=3` | Adds runtime bounds checking on libc calls like `memcpy`. Requires `-O2`+, already set. |
| `-Wl,-z,relro` | Marks relocations read-only after startup — hardens the binary at effectively no cost. |
| `-Wl,-z,pack-relative-relocs` | Shrinks the relocation table for a smaller binary on modern linkers/glibc. |
| `-mtune=haswell` | Redundant — `-march=haswell` already implies it. Harmless to leave in. |

PGO and BOLT are deliberately left out — in an interactive shell, syscalls
are the real bottleneck, not CPU-bound execution, so the extra build
complexity isn't worth it.

### Trimming the USE flags

Gentoo's `zsh` ebuild ships several optional features an interactive shell
user almost certainly doesn't need:

**`/etc/portage/package.use/zsh`**

```
app-shells/zsh -caps -doc -examples -gdbm -maildir -pcre
```

| Flag | What it does | Why disable it |
|---|---|---|
| `caps` | POSIX capabilities support | Irrelevant unless you're privilege-dropping in shell scripts |
| `doc` / `examples` | Man pages / example configs | Pure disk bloat |
| `gdbm` | Backs associative arrays with a GNU dbm file on disk | Not used interactively |
| `maildir` | Maildir-format mailbox support in Zsh's mail-checking | Nobody uses shell-native mail checking anymore |
| `pcre` | Perl-compatible regex in pattern matching | Pulls in `libpcre2`; native globbing covers everyday use |

### Installing the packages

```bash
doas emerge -av app-shells/zsh app-shells/gentoo-zsh-completions app-misc/fastfetch
```

`app-misc/fastfetch` is optional — if you skip it, comment out the
corresponding line in `.zshrc`. `app-shells/gentoo-zsh-completions` is also
optional but recommended; managing Gentoo's completion files by hand isn't
worth the hassle.

Set Zsh as your login shell:

```bash
chsh -s /usr/bin/zsh
```

Log out and back in for this to take effect.

### History substring search plugin

The `zsh-history-substring-search` package in the `guru` overlay proved
unreliable in testing, so this vendors the plugin directly from upstream:

```bash
mkdir -p ~/.zsh/plugins
curl -fsSL https://raw.githubusercontent.com/zsh-users/zsh-history-substring-search/master/zsh-history-substring-search.zsh -o ~/.zsh/plugins/zsh-history-substring-search.zsh
```

It's sourced from the plain-text `.zsh` file rather than a pre-compiled
`.zwc`, because Zsh's `source` command automatically loads the compiled
`.zwc` alongside it if one exists and is newer than the source — no need to
reference the bytecode directly (`zsh-compile`, below, handles that).

Run the command above once on a fresh install so the plugin file exists
before `.zshrc` tries to source it. After that, `zsh-plugin-update` keeps
it current.

**Periodically run `compaudit` manually** — `compinit -C` skips this check
on every startup for speed, so a malicious completion script planted in an
insecure (group/world-writable) `fpath` directory won't be caught
automatically:

```bash
compaudit
```

---

## Verifying the Build

`readelf -p .comment` is the commonly suggested way to confirm Clang built
a binary, but on Gentoo it often comes back empty regardless of compiler
because Portage strips binaries by default — an empty `.comment` section
isn't proof of anything. A build log is reliable instead:

```bash
doas emerge -av --oneshot app-shells/zsh
grep -m3 "clang" /var/log/portage/build/app-shells/zsh-*/temp/build.log 2>/dev/null \
  || zcat /var/log/portage/app-shells:zsh-*.log.gz 2>/dev/null | grep -m3 clang
```

Or simpler — confirm the USE flags and env file applied before the build
starts:

```bash
equery uses zsh          # confirms -caps -doc -examples -gdbm -maildir -pcre
portageq envvar CC
```

Confirm the USE flags actually stripped the dependencies:

```bash
ldd $(which zsh)
```

Neither `libpcre` nor `libgdbm` should appear.

Benchmark startup:

```bash
time ( repeat 100 zsh -i -c exit )
```

Divide by 100 for per-shell time — this setup should land around 3–8 ms
for Zsh itself. `fastfetch` adds another ~20–30 ms on top of that, so
don't mistake its cost for Zsh's if it's still enabled while benchmarking.

---

## Shell Features

### Custom management commands

* **`zsh-compile`** — byte-compiles `~/.zshrc`, the completion cache
  (`~/.zcompdump`), and local plugins into `.zwc`. Also scans for leftover
  `.old` backup files and offers to delete them.
* **`zsh-system-compile`** — the Portage bridge. Compiles any new
  completion files Portage drops into `/usr/share/zsh/site-functions/`,
  cleans up orphaned `.zwc` files, regenerates the local completion
  cache, and triggers `zsh-compile`. Requires `doas`.
* **`zsh-plugin-update`** — checks GitHub for upstream changes to
  `zsh-history-substring-search`, prompts before updating, and
  recompiles the plugin if you accept.

### Aliases, keybindings & options

**Keybindings:** Up/Down are bound to substring history search — type
part of a previous command (e.g. `emerge`) and press Up to filter
instantly. Both standard and `st`-application-mode escape sequences are
bound. Home, End, Delete, and Ctrl+Arrow are also bound explicitly, since
they often don't work out of the box on a fresh install.

**Aliases:**
- `ls`, `grep`, `egrep`, `tree`, `diff` default to color output; `ll`,
  `la`, `l` give long/hidden/grid listing variants.
- `df`/`free` default to human-readable output; `lsblk` hides loop
  devices; `llblk` is a cleaner custom `lsblk` view.
- `cp`/`mv` prompt before overwriting; `rm` prompts once for 3+ files
  rather than per-file; `chown`/`chmod`/`chgrp` require `--preserve-root`.
- `emerge` → `doas emerge -v`; `sync` → `doas emerge --sync`; `search` →
  `\emerge -s`; `pretend` → `\emerge -pv`.
- `shutdown`/`reboot` are wrapped with `doas`.

**Shell options:** `AUTO_CD` lets you type a directory name to `cd` into
it; `AUTO_PUSHD`/`PUSHD_IGNORE_DUPS` keep a clean directory stack.
Duplicate history entries are ignored, extra whitespace is stripped, and
`#` can be used to write comments at the prompt.

### Workflow

1. **Daily driving** — loads from `.zwc` bytecode in a few milliseconds.
2. **After editing configs** — run `zsh-compile`.
3. **After system updates** — run `zsh-system-compile` to keep
   tab-completion fast.

---

## Automated Installer

`zsh_install.sh` automates everything above. It verifies the release
cryptographically before touching anything: it mounts an isolated,
`noexec` tmpfs workspace, imports the maintainer's GPG key and checks it
against a fingerprint pinned in the script (independently cross-checked
against the key GitHub publishes for that account), verifies the
signature on the release checksum manifest, then verifies the SHA-256
checksum of every file. It refuses to run as root, only escalates
privileges (`doas`/`sudo`) for writes under `/etc/` or Portage calls,
backs up any file it replaces as a timestamped `.old` copy, and checks for
a newer signed release of itself before running.

```bash
./zsh_install.sh              # run the installer
./zsh_install.sh --dry-run    # show what would change, without changing anything
./zsh_install.sh --help       # usage
```

A log of each run is written to
`${XDG_STATE_HOME:-$HOME/.local/state}/gentoo-zsh/install.log`.

---

## Credits & Acknowledgments

- **[zsh-history-substring-search](https://github.com/zsh-users/zsh-history-substring-search)**
  — vendored under the BSD 3-Clause License. Copyright (c) 2009 Peter
  Stephenson, Guido van Steen, Suraj N. Kurapati, Sorin Ionescu, Vincent
  Guerci, Geza Lore, Bengt Brodersen.
