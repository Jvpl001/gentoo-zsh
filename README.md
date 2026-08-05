# This is mostly vibe codded.
# LTO-Compiled Zsh on Gentoo

you can make it work in other distroes but I can't careless.

Configuring my zsh and fastfetch in gentoo. if you use gentoo and st you probably
can still follow along. this is just what I use. it's not much. mostly just
auto completion and substring history.

I'll try to explain **why** every piece exists, for people how want to learn
(I myself have no idea what I'm doing). You can also run the `zsh_install.sh` 

---

## 1. Prerequisites

You need Clang and LLVM's linker. first and for most. Run:

```bash
doas emerge -av llvm-core/clang llvm-core/lld
```

Check if they're present:

```bash
command -v clang && command -v ld.lld
```

---

## 2. The compiler environment

Portage lets you override your compiler flags for a single package without
touching your `make.conf` flags. To do that you need an environment file.
run these as root:

```bash
mkdir /etc/portage/env/
touch /etc/portage/env/clang_flto.conf
nvim  /etc/portage/env/clang_flto.conf
```

**`/etc/portage/env/clang_flto.conf`**
```bash
CC="clang"
CXX="clang++"
# AI is explaining listen and learn.
# -fdata-sections & -ffunction-sections isolate every function/variable into
# its own section, so the linker can find and drop the ones nothing uses.
COMMON_FLAGS="-O3 -pipe -march=haswell -mtune=haswell -fno-plt -D_FORTIFY_SOURCE=3 -flto=full -fdata-sections -ffunction-sections"

CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"

# -fuse-ld=lld swaps in LLVM's linker (faster, and required for -icf).
# -Wl,--gc-sections actually drops the dead sections isolated above.
# -Wl,-icf=all (Identical Code Folding) merges functions that compile down
#   to identical machine code, shrinking the binary further.
LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,-z,pack-relative-relocs -Wl,-z,now -Wl,-z,relro -flto=full -fuse-ld=lld -Wl,--gc-sections -Wl,-icf=all"
```
let portage know we want to use the environment file:
**`/etc/portage/package.env/zsh`**
```
app-shells/zsh clang_flto.conf
```

A few notes on what's in there:

| Flag | Why |
|---|---|
| `-fno-plt` + `-Wl,-z,now` | Resolves all dynamic symbols at load time instead of lazily. Together they avoid the PLT trampoline entirely — a small but free win since we're already forcing eager binding. |
| `-D_FORTIFY_SOURCE=3` | Adds runtime bounds checking on libc calls like `memcpy`. Needs `-O2`+, which you have. |
| `-Wl,-z,relro` | Read-only relocations after startup — hardens the binary, ~free at runtime. |
| `-Wl,-z,pack-relative-relocs` | Shrinks the relocation table for a smaller binary on modern linkers/glibc. |
| `-mtune=haswell` | Technically redundant `-march=haswell` already implies tuning for Haswell. Harmless to leave in, but you can drop it. |

claude made this chart and it looks cool. I'm keeping it.(even where it rosted me)

**I didn't bother with PGO or BOLT.** In general syscalls are the
real bottleneck and we aren't really cpu-bound. not to mention fastfetch.

---

## 3. Trimming the USE flags

Gentoo's `zsh` ebuild ships with several optional features you almost
certainly don't use as an interactive shell user:

**`/etc/portage/package.use/zsh`**
```
app-shells/zsh -caps -doc -examples -gdbm -maildir -pcre
```

| Flag | What it does | Why disable it |
|---|---|---|
| `caps` | POSIX capabilities support | Irrelevant unless you're doing privilege-dropping in shell scripts |
| `doc` / `examples` | Installs man pages / example configs | Pure disk bloat, doesn't touch the binary but no reason to keep |
| `gdbm` | Lets Zsh scripts back associative arrays with a GNU dbm file on disk | You'll never use this interactively |
| `maildir` | Maildir-format mailbox support in Zsh's mail-checking code | Nobody uses shell-native mail checking anymore |
| `pcre` | Perl-compatible regex support in Zsh pattern matching | Adds a `libpcre2` dependency and binary size; Zsh's native globbing/regex covers everyday use |

---

you can tell where is AI generated simply because it writes Zsh and not zsh. lmfao.

## 4. Emerging everything

```bash
doas emerge -av app-shells/zsh app-shells/gentoo-zsh-completions app-misc/fastfetch
```

**Don't forget `app-misc/fastfetch`** — (if you want it)
and if you don't. comment it out from the .zshrc
I don't want to jank this one with:
```bash
command -v fastfetch &> /dev/null && [[ $SHLVL -eq 1 ]] && fastfetch
```
`app-shells/gentoo-zsh-completions` trust me I tried to manage that
myself and it did not go well. I just added the option if you want to
compile it.

set zsh as your default login shell:

```bash
chsh -s /usr/bin/zsh
```

(Log out and back in for this to take effect.)

---

## 5. The history substring search plugin

you need to run this for your first install so when you enter zsh
it wont throw errors(I janked a solution). but after that the
zsh-plugin-update takes care if it. also `app-shells/zsh-history-substring-search`
in the `guru` overlay didn't work and my way of doing it is way cooler.

```bash
mkdir -p ~/.zsh/plugins
curl -fsSL https://raw.githubusercontent.com/zsh-users/zsh-history-substring-search/master/zsh-history-substring-search.zsh -o ~/.zsh/plugins/zsh-history-substring-search.zsh
```

now you might be wondering why I'm not sourcing the compiled .zwc files?
it's because source command automatically detects and loads the compiled
.zwc alongside it if it's newer than the .zsh text file. so yeah.
I actually had to ask AI so you don't have to.

**Periodically run `compaudit`** manually, since `compinit -C` skips it on
  every startup. A local attacker could plant a malicious completion script
  using insecure (group/world-writable) directories in
  your `fpath` (just in case have this in mind):
  ```bash
  compaudit
  ```

---

## 6. Verifying it actually worked
I(claude) added this just for fun and it is completely useless.
At this point you have your zsh working basically.
### A. Confirm Clang actually built it

`readelf -p .comment` is the commonly-suggested check, but on Gentoo it will
often come back empty regardless of compiler, because **Portage strips
binaries by default** (`FEATURES="strip"` in `make.conf`, on unless you've
turned it off) — stripping removes `.comment` along with debug symbols. An
empty `.comment` section is *not* proof of anything; don't rely on it.

A build log is actually reliable:

```bash
doas emerge -av --oneshot app-shells/zsh
# then check the build log for the actual compiler invocation:
grep -m3 "clang" /var/log/portage/build/app-shells/zsh-*/temp/build.log 2>/dev/null \
  || zcat /var/log/portage/app-shells:zsh-*.log.gz 2>/dev/null | grep -m3 clang
```

Or simpler — just confirm the USE flags and env file actually applied before
the build even starts:

```bash
equery uses zsh          # confirms -caps -doc -examples -gdbm -maildir -pcre
portageq envvar CC       # sanity check for your global default, not per-package
```

### B. Confirm the USE flags stripped the dependencies

```bash
ldd $(which zsh)
```

Neither `libpcre` nor `libgdbm` should appear. You should see something close
to just `libtinfow`, `libm`, `libc`, and the dynamic linker.

### C. Benchmark startup

```bash
time ( repeat 100 zsh -i -c exit )
```

Divide the total by 100 for per-shell time. A stock Oh My Zsh setup usually
runs 200–500ms; this setup should land around 3-8ms for Zsh itself — remember
`fastfetch` inside `.zshrc` adds another ~20-30ms on top of that per launch,
so if you benchmark with `fastfetch` still active, don't mistake its cost for
Zsh's.


---

### 7. The Ricer Toolkit: Workflow, Aliases, & Management

I also told ai to generate this. My brain is cooked. give me a break. please.
I did all this in one afternoon.

#### 1. Custom Management Commands

Managing compiled bytecode and caching can be tedious. This setup includes three custom functions to automate the entire lifecycle of the shell environment.

* **`zsh-compile`**: The local optimizer. It safely byte-compiles the `~/.zshrc`, the completion cache (`~/.zcompdump`), and local plugins into `.zwc` bytecode. It automatically scans for leftover `.old` backup files and provides a clean, interactive prompt to delete them.


* **`zsh-system-compile`**: The Portage bridge. When Portage installs a new package, it drops plain-text completion files into `/usr/share/zsh/site-functions/`. This command (requiring `doas`) sweeps that root directory and hard-compiles any new completions. Afterward, it safely regenerates the local user's completion map and automatically triggers `zsh-compile` to byte-compile the new map.


* **`zsh-plugin-update`**: The standalone plugin manager. It reaches out to GitHub to check for upstream updates to the `zsh-history-substring-search` script. It compares the remote file against the local one, prompts for an update if changes are detected, and automatically recompiles the plugin if you choose to update.



#### 2. Aliases, Keybinds, & Quality of Life

The environment is heavily customized for readability and speed, utilizing native Zsh features that cost absolutely nothing in startup time.

**Keybinds (Terminal Agnostic):**

* **Intelligent History:** The Up/Down arrows are bound to a substring search. Type any part of a previous command (e.g., `emerge`) and press Up to filter history instantly. This is explicitly mapped to support both standard terminal emulators and `st` (suckless terminal) application-mode escape sequences.


* **Native Navigation:** Standard keys that often break on fresh Zsh installs (Home, End, Delete, Ctrl+Arrows) are hardcoded to function perfectly out of the box.



**Aliases:**

* **Aesthetics:** Core utilities (`ls`, `grep`, `tree`, `diff`) are forced to use intelligent automatic coloring.


* **Hardware & Disks:** Includes `df -h` and `free -h` for human-readable stats, plus a custom `llblk` command that formats `lsblk` into an ultra-clean grid while hiding noisy loop devices.


* **Safety Nets:** Destructive commands (`cp`, `mv`, `rm`) are aliased to prompt before overwriting or deleting multiple files. Root-level ownership changes require `--preserve-root` to prevent accidental system nukes.


* **Gentoo Specifics:** Shortcuts for Portage, including `sync` (`doas emerge --sync`), `search` (bypassing aliases with `\emerge -s`), and `pretend`.



**Quality of Life (`setopts`):**

* **Auto-CD & Directory Stacks:** Type a directory name (e.g., `Downloads`) without typing `cd` to jump to it. The shell remembers your directory history, allowing you to easily bounce back to previous locations.


* **Clean History:** Duplicate commands are ignored, and extra spaces are stripped before saving to the history file, keeping your search results highly relevant.



#### 3. How It All Comes Together (The Workflow)

This architecture completely eliminates the need for bloated frameworks like Oh My Zsh. It operates on a simple, three-step daily workflow:

1. **Daily Driving:** Open the terminal. It loads in sub-10 milliseconds because everything is read from `.zwc` memory maps. You can seamlessly navigate directories without typing `cd`, write comments in your prompt using `#`, and use the Up arrow to instantly recall complex commands.


2. **After Modifying Configs:** If you edit your `.zshrc` to add a new alias or change a color, simply run `zsh-compile`. The script handles the bytecode compilation and cleans up the mess.
3. **After System Updates:** When you run an `emerge` update that installs new software, run `zsh-system-compile`. It will optimize the newly installed Gentoo completions, rebuild your local cache, and ensure the `<TAB>` key remains instantaneous.

## 8. The Automated Installer (`zsh_install.sh`)

If you prefer not to configure the system manually or want to deploy this setup quickly, you can run the included `zsh_install.sh` script. It is a highly portable, deterministic UNIX shell script that automates the entire deployment process securely. 

Here is what it handles under the hood:
* **Cryptographic Verification:** The script establishes an isolated, no-exec `tmpfs` workspace in memory. It then independently pulls the developer's public GPG key from GitHub, compares the fingerprint against a hardcoded anchor, and verifies the SHA256 checksums of all source files before any installation begins.
* **Self-Updating:** Before running, the script checks the remote repository for a newer, signed version of itself and safely restarts if an update is found.
* **Privilege Segregation:** The script enforces being run as a standard user. It handles all local user configurations normally, only escalating privileges (via `doas` or `sudo`) exactly when needed to write to `/etc/` or invoke Portage.
* **Non-Destructive Deployment:** Every existing configuration file that the script replaces is automatically preserved as a timestamped `.old` backup.
* **Dry-Run Mode:** You can pass the `--dry-run` flag to safely audit exactly what files the script will create or modify without making any actual changes to your system.

---

## Credits & Acknowledgments

* **[zsh-history-substring-search](https://github.com/zsh-users/zsh-history-substring-search)** — Vendored under the [BSD 3-Clause License](configs/plugins/zsh-history-substring-search.zsh). Copyright (c) 2009 Peter Stephenson, Guido van Steen, Suraj N. Kurapati, Sorin Ionescu, Vincent Guerci, Geza Lore, Bengt Brodersen.
