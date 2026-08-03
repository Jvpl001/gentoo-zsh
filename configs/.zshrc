# ==============================================================================
# 1. HISTORY SETTINGS (Big History)
# ==============================================================================
# Exporting these ensures they initialize correctly even in subshells
export HISTFILE=~/.zsh_history
export HISTSIZE=100000
export SAVEHIST=100000
setopt appendhistory      
setopt incappendhistory   
setopt histignorealldups  

# ==============================================================================
# 2. AUTO-COMPLETION (Fast)
# ==============================================================================
fpath=(/usr/share/zsh/site-functions $fpath)

autoload -Uz compinit
compinit -C 

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'

# ==============================================================================
# 3. HISTORY SUBSTRING SEARCH (Local & Fast)
# ==============================================================================
# Source the file directly from your local home directory
source ~/.zsh/plugins/zsh-history-substring-search.zsh

# st terminal sends different escape sequences for arrow keys. We bind BOTH.
bindkey '^[[A' history-substring-search-up   # Standard Up
bindkey '^[[B' history-substring-search-down # Standard Down
bindkey '^[OA' history-substring-search-up   # st Application Up
bindkey '^[OB' history-substring-search-down # st Application Down
# --- Standard Keybindings (Fixes the '~' bug on fresh installs) ---
bindkey '^[[H' beginning-of-line       # Home key
bindkey '^[[F' end-of-line             # End key
bindkey '^[[3~' delete-char            # Delete key
bindkey '^[[1;5C' forward-word         # Ctrl + Right Arrow
bindkey '^[[1;5D' backward-word        # Ctrl + Left Arrow

# ==============================================================================
# 4. SUCKLESS ST-MATCHING PROMPT
# ==============================================================================
# Exact hex colors mapped directly from your st config array
ST_CYAN="%F{#2ad3ab}"    # color 6
ST_RED="%F{#ea1b1b}"     # color 1
ST_GREEN="%F{#2ce92a}"   # color 2
ST_PURPLE="%F{#7c21d8}"  # color 5
ST_FG="%F{#c0f5c6}"      # defaultfg
ST_RESET="%f"

setopt PROMPT_SUBST

# user@host ~/path ❯
PROMPT="${ST_CYAN}%n${ST_FG}@${ST_RED}%m ${ST_GREEN}%~ ${ST_PURPLE}❯${ST_RESET} "

# ==============================================================================
# 5. FastFetch... yaeh.
# ==============================================================================
fastfetch

# ==============================================================================
# 6. BYTECODE MANAGEMENT
# ==============================================================================
autoload -U zrecompile

# 1. Compile personal local configs (Robust version)
zsh-compile() {
  echo "Optimizing local Zsh environment..."

  # Define all files that should be compiled
  local files_to_compile=(
    ~/.zshrc
    ~/.zcompdump
    ~/.zsh/plugins/zsh-history-substring-search.zsh
  )

  # Loop through and safely compile only if the file exists
  for file in "${files_to_compile[@]}"; do
    if [[ -f "$file" ]]; then
      # -p makes it quiet unless it actually recompiles
      zrecompile -p "$file" || echo "Error: Failed to compile ${file##*/}"
    fi
  done

  # Cleanup prompt for .old files
  setopt localoptions nullglob
  local old_files=(~/.zshrc.zwc.old(N) ~/.zcompdump.zwc.old(N) ~/.zsh/plugins/*.zwc.old)

  if (( ${#old_files[@]} > 0 )); then
    echo "\nFound ${#old_files[@]} local backup file(s):"
    for file in "${old_files[@]}"; do
      echo "  - $file"
    done
    echo ""
    
    if read -q "reply?Do you want to delete them? [y/N] "; then
      echo "" 
      rm -f "${old_files[@]}"
      echo "Backup files removed."
    else
      echo "\nBackup files kept."
    fi
  else
    echo "\nNo local backup files found. Everything is clean."
  fi
}

# 2. Compile Portage-managed system completions & regenerate cache
zsh-system-compile() {
  echo "Optimizing Portage completions (requires doas)..."
  
  # Loop through system directory, ignoring existing .zwc files
  for file in /usr/share/zsh/site-functions/*(N^*.zwc); do
    # Only compile if the .zwc doesn't exist, or if the text file is newer
    if [[ ! -f "${file}.zwc" || "$file" -nt "${file}.zwc" ]]; then
      doas zcompile "$file"
    fi
  done
  
  echo "Regenerating local completion cache..."
  # Nuke the outdated cache and its bytecode safely as the normal user
  rm -f ~/.zcompdump ~/.zcompdump.zwc
  
  # Re-initialize the completion system to map the newly installed packages
  autoload -Uz compinit
  compinit -C
  
  echo ""
  # Automatically trigger the local compiler to byte-compile the new .zcompdump
  zsh-compile
}

# ==============================================================================
# 7. PLUGIN UPDATER
# ==============================================================================
zsh-plugin-update() {
  local url="https://raw.githubusercontent.com/zsh-users/zsh-history-substring-search/master/zsh-history-substring-search.zsh"
  local plugin_file="$HOME/.zsh/plugins/zsh-history-substring-search.zsh"
  local temp_file

  temp_file=$(mktemp)

  echo "Checking for updates..."

  if ! curl -fsSL "$url" -o "$temp_file"; then
    echo "Error: Failed to fetch update from GitHub."
    rm -f "$temp_file"
    return 1
  fi

  if [[ ! -f "$plugin_file" ]] || ! cmp -s "$temp_file" "$plugin_file"; then
    echo "An update is available for zsh-history-substring-search!"
    read "reply?Do you want to update? [Y/n] "

    if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
      mkdir -p "$(dirname "$plugin_file")"
      mv "$temp_file" "$plugin_file"
      echo "Plugin updated successfully."
      
      if declare -f zsh-compile >/dev/null; then
        zsh-compile
      fi
    else
      echo "Update canceled."
      rm -f "$temp_file"
    fi
  else
    echo "No update available."
    rm -f "$temp_file"
  fi
}

# ==============================================================================
# 8. ALIASES & AESTHETICS (The Ricer Toolkit)
# ==============================================================================
# All aliases cost ~0ms to initialize. Comment out what you don't need.

# --- Core Colors & Formatting ---
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias tree='tree -C'                  # Force colors in tree output
alias diff='diff --color=auto'

# --- File Listing (The 'll' family) ---
alias ll='ls -lh --color=auto'        # Long format, human-readable sizes (KB, MB)
alias la='ls -lAh --color=auto'       # Long format, includes hidden files
alias l='ls -CF --color=auto'         # Grid layout with file type indicators (/, @, *)

# --- Disk & Hardware (Clean & Readable) ---
alias df='df -h'                      # Human readable disk space
alias free='free -h'                  # Human readable RAM usage
alias lsblk='lsblk -e7'               # Standard lsblk but hides annoying loop devices
alias llblk='lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT' # Ultra-clean custom block view

# --- Safety Nets (Prevents late-night disasters) ---
alias cp='cp -i'                      # Prompt before overwriting existing files
alias mv='mv -i'                      # Prompt before overwriting existing files
alias rm='rm -I'                      # Prompt ONCE before deleting 3+ files (less annoying than -i)
alias chown='chown --preserve-root'
alias chmod='chmod --preserve-root'
alias chgrp='chgrp --preserve-root'

# --- Directory Navigation Shortcuts ---
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# --- Gentoo Specifics (Optional) ---
alias emerge='doas emerge -v'
alias sync='doas emerge --sync'
alias search='\emerge -s'
alias pretend='\emerge -pv'

alias shutdown='doas shutdown -hP now'
alias reboot='doas reboot'

# 1. Directory Navigation
setopt AUTO_CD           # Type a directory name to cd into it automatically (no 'cd' needed)
setopt AUTO_PUSHD        # Make cd keep a background stack of directories you visit
setopt PUSHD_IGNORE_DUPS # Keep the directory stack clean of duplicates
# 2. History Polish
setopt EXTENDED_HISTORY   # Save timestamps and execution duration to the history file
setopt HIST_REDUCE_BLANKS # Strip extra spaces from commands before saving them
setopt HIST_FIND_NO_DUPS  # Don't show the exact same command twice when pressing Up
# 3. Terminal Interaction
setopt INTERACTIVE_COMMENTS # Allow using '#' to write notes/comments directly in the prompt
