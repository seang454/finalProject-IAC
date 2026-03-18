#!/bin/bash
# Usage: ./zsh.bash [install|remove]
# Enhanced Zsh setup with Powerlevel10k, fzf, zoxide, bat, eza, and more
set -e

ACTION=${1:-install}
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
CUSTOM_CONFIG="$HOME/.zshrc_custom"

print_step() { echo ""; echo "▶ $1"; }

backup_zshrc() {
    if [ -f "$HOME/.zshrc" ]; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
        echo "✔ Backup of .zshrc created."
    fi
}

install_packages() {
    print_step "Installing system dependencies..."
    sudo apt-get update -y -qq
    sudo apt-get install -y zsh git curl wget fzf unzip build-essential nodejs npm || true

    if ! command -v bat &>/dev/null && ! command -v batcat &>/dev/null; then
        sudo apt-get install -y bat 2>/dev/null || true
    fi

    if ! command -v eza &>/dev/null; then
        sudo apt-get install -y eza 2>/dev/null || \
        (wget -q "https://github.com/eza-community/eza/releases/latest/download/eza_x86_64-unknown-linux-gnu.tar.gz" \
            -O /tmp/eza.tar.gz && tar -xzf /tmp/eza.tar.gz -C /tmp && sudo mv /tmp/eza /usr/local/bin/eza) || true
    fi

    if ! command -v zoxide &>/dev/null; then
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh || true
    fi

    if ! command -v thefuck &>/dev/null; then
        sudo apt-get install -y python3-pip 2>/dev/null || true
        pip3 install thefuck --quiet 2>/dev/null || true
    fi

    if ! command -v tldr &>/dev/null; then
        sudo apt-get install -y tldr 2>/dev/null || sudo npm install -g tldr 2>/dev/null || true
    fi

    if ! command -v delta &>/dev/null; then
        DELTA_VER=$(curl -s "https://api.github.com/repos/dandavison/delta/releases/latest" \
            | grep -Po '"tag_name": "\K[^"]+' 2>/dev/null || echo "0.16.5")
        wget -q "https://github.com/dandavison/delta/releases/download/${DELTA_VER}/git-delta_${DELTA_VER}_amd64.deb" \
            -O /tmp/delta.deb 2>/dev/null && sudo dpkg -i /tmp/delta.deb 2>/dev/null || true
    fi

    if ! command -v gh &>/dev/null; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null && \
        sudo apt-get update -qq && sudo apt-get install -y gh 2>/dev/null || true
    fi

    echo "✔ Packages installed."
}

setup_cli_completions() {
    print_step "Generating CLI completions for installed tools..."

    local comp_dir="$HOME/.zsh/completions"
    mkdir -p "$comp_dir"

    _try_comp() {
        local out="$1"; shift
        local tool="$1"
        local tmp; tmp=$(mktemp)
        # Run under zsh to match user environment and PATH
        zsh -c "$* > '$tmp' 2>/dev/null" 2>/dev/null
        if [[ -s "$tmp" ]] && grep -qE '(#compdef|compdef )' "$tmp"; then
            mv -f "$tmp" "$out"
            echo "  ✔ $tool"
            return 0
        fi
        rm -f "$tmp"
        echo "  ✘ $tool — no valid completion output (skipped)"
        return 1
    }

    # ── GROUP 1: <tool> completion zsh ───────────────────
    for tool in docker kubectl helm kind k3d minikube stern argocd flux \
                golangci-lint goreleaser hugo operator-sdk; do
        command -v "$tool" &>/dev/null && \
            _try_comp "$comp_dir/_${tool}" "$tool" "$tool" completion zsh
    done

    # ── GROUP 2: gh — completion -s zsh ──────────────────
    command -v gh &>/dev/null && \
        _try_comp "$comp_dir/_gh" gh gh completion -s zsh

    # ── GROUP 2.5: <tool> --completions zsh ──────────────
    # just uses --completions (double-dash flag), not a subcommand
    for tool in just; do
        command -v "$tool" &>/dev/null && \
            _try_comp "$comp_dir/_${tool}" "$tool" "$tool" --completions zsh
    done

    # ── GROUP 3: <tool> completions zsh ──────────────────
    for tool in rustup cargo volta fnm poetry rye \
                mise vault consul nomad packer waypoint; do
        command -v "$tool" &>/dev/null && \
            _try_comp "$comp_dir/_${tool}" "$tool" "$tool" completions zsh
    done

    # ── GROUP 3.5: pipx — register-python-argcomplete ────
    # pipx does not generate a compdef via 'pipx completions zsh'
    # it requires register-python-argcomplete instead
    if command -v pipx &>/dev/null && command -v register-python-argcomplete &>/dev/null; then
        register-python-argcomplete pipx > "$comp_dir/_pipx" 2>/dev/null
        if grep -qE '(#compdef|compdef )' "$comp_dir/_pipx" 2>/dev/null; then
            echo "  ✔ pipx"
        else
            rm -f "$comp_dir/_pipx"
            echo "  ✘ pipx — argcomplete failed (skipped)"
        fi
    fi

    # ── GROUP 4: uv — generate-shell-completion zsh ──────
    command -v uv &>/dev/null && \
        _try_comp "$comp_dir/_uv" uv uv generate-shell-completion zsh

    # ── GROUP 5: rg — --generate=complete-zsh ────────────
    command -v rg &>/dev/null && \
        _try_comp "$comp_dir/_rg" rg rg --generate=complete-zsh

    # ── GROUP 6: fd — --gen-completions zsh ──────────────
    command -v fd &>/dev/null && \
        _try_comp "$comp_dir/_fd" fd fd --gen-completions zsh

    # ── GROUP 7: terraform — -install-autocomplete ───────
    if command -v terraform &>/dev/null; then
        terraform -install-autocomplete 2>/dev/null || true
        echo "  ✔ terraform (via -install-autocomplete)"
    fi

    # ── GROUP 8: aws — aws_completer binary ──────────────
    if command -v aws &>/dev/null; then
        cat > "$comp_dir/_aws" << 'AWSEOF'
#compdef aws
complete -C aws_completer aws
AWSEOF
        echo "  ✔ aws"
    fi

    # ── GROUP 9: az — argcomplete ─────────────────────────
    if command -v az &>/dev/null; then
        local az_comp
        az_comp=$(python3 -c "import argcomplete; print(argcomplete.__file__)" 2>/dev/null)
        if [[ -n "$az_comp" ]]; then
            register-python-argcomplete az > "$comp_dir/_az" 2>/dev/null && \
                echo "  ✔ az" || true
        fi
    fi

    # ── GROUP 10: gcloud — source completion from SDK ────
    # gcloud does NOT generate a compdef script — it ships a completion.zsh.inc
    # that must be sourced at shell startup. We write a source line into
    # ~/.zshrc_custom so it loads automatically on every new shell.
    if command -v gcloud &>/dev/null; then
        local gcloud_sdk gcloud_inc
        gcloud_sdk=$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)
        gcloud_inc="${gcloud_sdk}/completion.zsh.inc"
        # Fallback: sdk_root metadata may be wrong on Debian/Ubuntu apt installs
        if [[ ! -f "$gcloud_inc" ]]; then
            gcloud_inc=$(find /usr/share/google-cloud-sdk /usr/lib/google-cloud-sdk \
                -name "completion.zsh.inc" 2>/dev/null | head -1)
        fi
        if [[ -f "$gcloud_inc" ]]; then
            local gcloud_line="[[ -f '$gcloud_inc' ]] && source '$gcloud_inc'"
            if ! grep -qF 'completion.zsh.inc' "$CUSTOM_CONFIG" 2>/dev/null; then
                echo "" >> "$CUSTOM_CONFIG"
                echo "# ── gcloud completion ───────────────────────────────" >> "$CUSTOM_CONFIG"
                echo "$gcloud_line" >> "$CUSTOM_CONFIG"
            fi
            echo "  ✔ gcloud (sourced from $gcloud_inc)"
        else
            echo "  ✘ gcloud — SDK completion file not found (skipped)"
            echo "    Run: find / -name 'completion.zsh.inc' 2>/dev/null"
        fi
    fi

    unset -f _try_comp

    echo "✔ CLI completions generated in $comp_dir"
    echo "  Run 'compinit_refresh' after installing new tools to register their completions."
}

install_oh_my_zsh() {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        print_step "Installing Oh My Zsh..."
        RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        echo "✔ Oh My Zsh installed."
    else
        echo "✔ Oh My Zsh already present."
    fi
}

install_plugins() {
    print_step "Installing Zsh plugins..."
    mkdir -p "$ZSH_CUSTOM/plugins"
    export GIT_TERMINAL_PROMPT=0

    declare -A plugins
    plugins=(
        [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions.git"
        [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
        [zsh-history-substring-search]="https://github.com/zsh-users/zsh-history-substring-search.git"
        [zsh-autopair]="https://github.com/hlissner/zsh-autopair.git"
        [zsh-nvm]="https://github.com/lukechilds/zsh-nvm.git"
        [fzf-tab]="https://github.com/Aloxaf/fzf-tab.git"
        [zsh-completions]="https://github.com/zsh-users/zsh-completions.git"
        [forgit]="https://github.com/wfxr/forgit.git"
        [zsh-you-should-use]="https://github.com/MichaelAquilina/zsh-you-should-use.git"
        [zsh-better-npm-completion]="https://github.com/lukechilds/zsh-better-npm-completion.git"
    )

    for plugin in "${!plugins[@]}"; do
        if [ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]; then
            echo "  Installing $plugin..."
            git clone --depth=1 --quiet "${plugins[$plugin]}" "$ZSH_CUSTOM/plugins/$plugin" || \
                echo "  ⚠ Could not install $plugin (skipping)"
        fi
    done

    sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search zsh-autopair zsh-nvm fzf-tab zsh-completions forgit zsh-you-should-use zsh-better-npm-completion)/' "$HOME/.zshrc"
    echo "✔ Plugins installed."
}

install_powerlevel10k() {
    print_step "Installing Powerlevel10k theme..."

    if [ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]; then
        git clone --depth=1 --quiet https://github.com/romkatv/powerlevel10k.git \
            "$ZSH_CUSTOM/themes/powerlevel10k" || {
                echo "  ⚠ Could not install Powerlevel10k, falling back to agnoster"
                sed -i 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' "$HOME/.zshrc"
                return
            }
    fi

    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc"

    cat > "$HOME/.p10k.zsh" << 'P10K_EOF'
# Powerlevel10k config — run `p10k configure` for interactive customization
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os_icon dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status command_execution_time background_jobs node_version python_version time
  )

  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=moderate
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_CHAR='·'

  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=76
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=2
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=101
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M}'
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=same-dir
} "$@"

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_EOF

    echo "✔ Powerlevel10k installed. Run 'p10k configure' for interactive setup."
}

write_custom_config() {
    print_step "Writing custom Zsh configuration to ~/.zshrc_custom..."

    cat > "$CUSTOM_CONFIG" << 'ZSHRC_EOF'
# ╔══════════════════════════════════════════════════╗
# ║      CUSTOM ZSH CONFIGURATION                   ║
# ║  Edit ~/.zshrc_custom to personalize            ║
# ╚══════════════════════════════════════════════════╝

# ── Powerlevel10k instant prompt (keep near top) ─────
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# ── History ──────────────────────────────────────────
HISTSIZE=50000
SAVEHIST=50000
HISTFILE=~/.zsh_history
setopt HIST_EXPIRE_DUPS_FIRST HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE HIST_FIND_NO_DUPS HIST_SAVE_NO_DUPS SHARE_HISTORY

# ── Shell options ────────────────────────────────────
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS GLOB_DOTS

# ── Completion ───────────────────────────────────────
[[ -d "$HOME/.zsh/completions" ]] && fpath=("$HOME/.zsh/completions" $fpath)
[[ -d /usr/share/zsh/vendor-completions ]] && fpath=(/usr/share/zsh/vendor-completions $fpath)
[[ -d /usr/local/share/zsh/site-functions ]] && fpath=(/usr/local/share/zsh/site-functions $fpath)

autoload -Uz compinit
if [[ -n ~/.zcompdump(#qN.mh+24) ]]; then compinit; else compinit -C; fi

# ── gcloud completion (sourced from SDK — not compdef based) ─
if command -v gcloud &>/dev/null; then
  _gcloud_sdk=$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)
  _gcloud_inc="${_gcloud_sdk}/completion.zsh.inc"
  # Fallback: sdk_root metadata may be wrong on Debian/Ubuntu apt installs
  if [[ ! -f "$_gcloud_inc" ]]; then
    _gcloud_inc=$(find /usr/share/google-cloud-sdk /usr/lib/google-cloud-sdk \
      -name "completion.zsh.inc" 2>/dev/null | head -1)
  fi
  [[ -f "$_gcloud_inc" ]] && source "$_gcloud_inc"
  unset _gcloud_sdk _gcloud_inc
fi

# ── No-matches handler ───────────────────────────────
_no_matches_handler() {
    zle -M "  ✗ No matches found.  [ Esc ] cancel  [ Ctrl+C ] abort  [ type more ] narrow down"
}
zle -N _no_matches_handler
zstyle ':completion:*:warnings' format \
    $'\n%F{yellow}  ✗ No matches for: %F{red}%d%f\n%F{blue}  → Try fewer characters, check spelling, or press Esc to cancel.%f\n'
zstyle ':completion:*' accept-exact '*(N)'
zstyle ':completion:*' completer _expand _complete _ignored

# ── Completion behaviour ──────────────────────────────
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*:descriptions' format $'%F{green}  ─── %d ───%f'
zstyle ':completion:*:messages'    format $'%F{cyan}  %d%f'
zstyle ':completion:*:corrections' format $'%F{yellow}  ✎ %d (errors: %e)%f'
zstyle ':completion:*:git-checkout:*' sort false
zstyle ':completion:*' squeeze-slashes true
zstyle ':completion:*' special-dirs true
zstyle ':completion:*' group-name ''

# ── fzf-tab ──────────────────────────────────────────
local _fzf_nav_hint=$'  \e[2m[ Tab \e[0m\e[2m] select  [ Enter ] confirm  [ Esc / Ctrl+C ] cancel  [ ← → ] scroll preview\e[0m'

zstyle ':fzf-tab:*' fzf-flags \
    --header="$_fzf_nav_hint" \
    --header-first \
    --bind 'esc:abort' \
    --bind 'ctrl-c:abort' \
    --bind 'ctrl-q:abort' \
    --bind 'ctrl-/:toggle-preview' \
    --bind 'shift-left:preview-page-up' \
    --bind 'shift-right:preview-page-down' \
    --exit-0

zstyle ':fzf-tab:complete:cd:*' fzf-preview \
    'eza --icons --color=always --group-directories-first $realpath 2>/dev/null || ls -la $realpath'
zstyle ':fzf-tab:complete:z:*' fzf-preview \
    'eza --icons --color=always --group-directories-first $realpath 2>/dev/null || ls -la $realpath'
zstyle ':fzf-tab:complete:ls:*' fzf-preview \
    'eza --icons --color=always $realpath 2>/dev/null || ls -la $realpath'
zstyle ':fzf-tab:complete:cat:*' fzf-preview \
    'bat --color=always --style=numbers --line-range :80 $realpath 2>/dev/null || cat $realpath'
zstyle ':fzf-tab:complete:vim:*' fzf-preview \
    'bat --color=always --style=numbers --line-range :80 $realpath 2>/dev/null || cat $realpath'
zstyle ':fzf-tab:complete:nano:*' fzf-preview \
    'bat --color=always --style=numbers --line-range :80 $realpath 2>/dev/null || cat $realpath'
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-preview \
    'ps --pid=$word -o cmd --no-header -w -w'
zstyle ':fzf-tab:complete:kill:argument-rest' fzf-flags \
    '--preview-window=down:3:wrap' "--header=$_fzf_nav_hint" --header-first
zstyle ':fzf-tab:complete:git-(add|diff|restore):*' fzf-preview \
    'git diff --color=always $realpath 2>/dev/null || bat --color=always $realpath'
zstyle ':fzf-tab:complete:git-checkout:*' fzf-preview \
    'git log --oneline --color=always $realpath 2>/dev/null || cat $realpath'
zstyle ':fzf-tab:complete:(-command-|-parameter-|-brace-parameter-|export|unset|expand):*' fzf-preview \
    'echo ${(P)word}'
zstyle ':fzf-tab:complete:*:*' fzf-preview \
    'bat --color=always --style=numbers --line-range :50 $realpath 2>/dev/null \
     || eza --icons --color=always $realpath 2>/dev/null \
     || echo $realpath'

# ── Completion options ────────────────────────────────
zstyle ':completion:*:approximate:*' max-errors 2 numeric
setopt COMPLETE_IN_WORD ALWAYS_TO_END LIST_PACKED
zstyle ':completion:*:options' description 'yes'
zstyle ':completion:*:options' auto-description 'specify: %d'
zstyle ':completion:*' verbose yes
zstyle ':completion:*:*:*:*:options' format $'%F{magenta}  ── flags ──%f'

# ── fzf-tab flag previews ─────────────────────────────
zstyle ':fzf-tab:complete:*:options' fzf-preview \
    'echo -e "\e[1;33m$word\e[0m\n\n$(tldr ${words[1]} 2>/dev/null | head -20 || echo "No tldr page. Try: man ${words[1]}")"'
zstyle ':fzf-tab:complete:*:options' fzf-flags \
    '--preview-window=right:45%:wrap' \
    "--header=$'  \e[2m[ Tab ] select  [ Enter ] confirm  [ Esc ] cancel  [ type - ] filter flags\e[0m'" \
    --header-first

# ── Per-command flag completions ──────────────────────
compdef _git git

_eza_flags() {
    (( $+functions[_arguments] )) || return 1
    local -a opts
    opts=(
        '(-l --long)'{-l,--long}'[display extended file metadata as a table]'
        '(-a --all)'{-a,--all}'[show hidden and "dot" files]'
        '(-T --tree)'{-T,--tree}'[recurse into directories as a tree]'
        '--level=[limit the depth of recursion]:depth:(1 2 3 4 5)'
        '--icons[display icons]'
        '--no-icons[suppress icons]'
        '--git[show git status for each file]'
        '--git-ignore[ignore files listed in .gitignore]'
        '(-g --group)'{-g,--group}'[show group for each file]'
        '(-h --header)'{-h,--header}'[add a header row to each column]'
        '(-H --links)'{-H,--links}'[show hard link count per file]'
        '(-i --inode)'{-i,--inode}'[show inode number per file]'
        '(-S --blocksize)'{-S,--blocksize}'[show size of allocated file system blocks]'
        '(-s --sort)'{-s,--sort}'[which field to sort by]:field:(name size date modified accessed created type extension none)'
        '--group-directories-first[list directories before other files]'
        '(-r --reverse)'{-r,--reverse}'[reverse the sort order]'
        '(-R --recurse)'{-R,--recurse}'[recurse into directories]'
        '(-F --classify)'{-F,--classify}'[display type indicator by file names]'
        '--color=[when to use terminal colours]:when:(always auto never)'
        '--color-scale[highlight levels of field values distinctly]'
        '(-1 --oneline)'{-1,--oneline}'[display one entry per line]'
        '(-x --across)'{-x,--across}'[sort the grid across, rather than downwards]'
        '(-G --grid)'{-G,--grid}'[display entries as a grid (default)]'
        '--time=[which timestamp field to use]:field:(modified accessed created)'
        '--time-style=[how to format timestamps]:style:(default iso long-iso full-iso relative)'
        '--no-permissions[suppress permissions field]'
        '--no-filesize[suppress file size field]'
        '--no-time[suppress time field]'
        '--no-user[suppress user field]'
        '--octal-permissions[show permissions in octal format]'
        '(-Z --context)'{-Z,--context}'[show security context per file]'
        '(-D --only-dirs)'{-D,--only-dirs}'[list only directories]'
        '(-f --only-files)'{-f,--only-files}'[list only files]'
        '--help[show help]'
        '--version[show version]'
    )
    _arguments -s -S $opts '*:file:_files'
}
compdef _eza_flags eza

_bat_flags() {
    (( $+functions[_arguments] )) || return 1
    local -a opts
    opts=(
        {-l,--language}'=[set the language for syntax highlighting]:language:(rust python javascript typescript go bash zsh json yaml toml markdown css html)'
        {-H,--highlight-line}'=[highlight specific line(s)]:line range:'
        '--tabs=[set the tab width]:width:(1 2 4 8)'
        '--wrap=[specify the text-wrapping mode]:mode:(auto never character)'
        {-n,--number}'[show line numbers only (no other decoration)]'
        '--color=[when to use colors]:when:(auto always never)'
        '--italic-text=[use italics in output]:when:(always never)'
        '--decorations=[when to show decorations]:when:(auto always never)'
        {-p,--plain}'[show plain style, no decorations or line numbers]'
        {-A,--show-all}'[show non-printable characters]'
        '--paging=[specify when to use the pager]:when:(auto always never)'
        '--pager=[specify which pager to use]:pager:'
        '--style=[comma-separated list of style components]:style:(auto full plain changes header-filename header-filesize grid rule numbers snip)'
        '--theme=[set the color theme]:theme:()'
        '--list-themes[list available themes]'
        '--list-languages[list supported languages]'
        {-r,--line-range}'=[specify line range to print]:range:'
        {-d,--diff}'[show lines that have been added or removed]'
        '--diff-context=[include N lines of context around changes]:lines:'
        '--map-syntax=[map a glob pattern to an existing syntax]:mapping:'
        '--ignored-suffix=[ignore extension]:suffix:'
        '--terminal-width=[set terminal width for wrapping]:width:'
        {-u,--unbuffered}'[unbuffered output]'
        '--no-config[do not use config file]'
        '--config-file[show config file path]'
        '--config-dir[show config directory path]'
        '--cache-dir[show cache directory path]'
        '--diagnostic[show diagnostic information]'
        '--acknowledgements[show acknowledgements]'
        '--help[print help]'
        '--version[print version]'
        '*:file:_files'
    )
    _arguments -s -S $opts
}
compdef _bat_flags bat batcat

_zoxide_flags() {
    (( $+functions[_arguments] )) || return 1
    local -a cmds
    cmds=(
        'add:add a new directory or increment its rank'
        'import:import entries from another autojump/z database'
        'init:generate shell configuration'
        'query:search for a directory'
        'remove:remove a directory'
    )
    local -a query_opts
    query_opts=(
        {-i,--interactive}'[use interactive selection]'
        {-l,--list}'[list all matching directories]'
        {-s,--score}'[show score with results]'
        '--exclude=[exclude a path from results]:path:_files -/'
        '--help[print help]'
    )
    case "$words[2]" in
        query) _arguments -s $query_opts ;;
        *)     _describe 'zoxide command' cmds ;;
    esac
}
compdef _zoxide_flags zoxide z zi

_fzf_flags() {
    (( $+functions[_arguments] )) || return 1
    local -a opts
    opts=(
        {-x,--extended}'[extended-search mode]'
        {-e,--exact}'[enable exact-match]'
        {-i,--ignore-case}'[case-insensitive match (default: smart-case)]'
        '--literal[do not normalize latin script letters]'
        '--algo=[fuzzy matching algorithm]:algo:(v1 v2)'
        {-n,--nth}'=[comma-separated list of field index expressions]:nth:'
        '--with-nth=[transform the presentation of each line]:nth:'
        {-d,--delimiter}'=[field delimiter regex]:regex:'
        '--disabled[do not perform search]'
        '--no-sort[do not sort the result]'
        '--tac[reverse the order of the input]'
        '--tiebreak=[comma-separated list of sort criteria]:criteria:(length chunk begin end index)'
        {-m,--multi}'[enable multi-select with tab/shift-tab]'
        '--no-multi[disable multi-select]'
        '--bind=[custom key bindings]:bindings:'
        '--color=[color configuration]:color:'
        '--no-bold[do not use bold text]'
        '--height=[display fzf window below the cursor with given height]:height:'
        '--min-height=[minimum height when --height is given as percentage]:height:'
        '--layout=[choose layout]:layout:(default reverse reverse-list)'
        '--border=[draw border around the finder]:style:(rounded sharp bold block)'
        '--border-label=[label to print on the border]:label:'
        '--margin=[screen margin]:margin:'
        '--padding=[padding inside border]:padding:'
        '--info=[finder info style]:style:(default right hidden inline)'
        '--separator=[string to form horizontal separator on info line]:str:'
        '--no-separator[hide info line separator]'
        '--scrollbar=[string to use as scrollbar indicator]:str:'
        '--no-scrollbar[hide scrollbar]'
        '--prompt=[input prompt]:str:'
        '--pointer=[pointer to the current line]:str:'
        '--marker=[multi-select marker]:str:'
        '--header=[string to print as header]:str:'
        '--header-lines=[treat the first N lines as header]:n:'
        '--header-first[print header before the prompt line]'
        '--ansi[enable processing of ANSI color codes]'
        '--tabstop=[number of spaces for a tab character]:n:'
        '--preview=[command to preview highlighted line]:cmd:'
        '--preview-window=[preview window layout]:layout:'
        '--preview-label=[label to print on the preview window border]:label:'
        '--query=[start the finder with the given query]:query:'
        '--select-1[automatically select the only match]'
        '--exit-0[exit immediately when there is no match]'
        '--filter=[filter mode (do not start interactive finder)]:query:'
        '--print-query[print query as the first line]'
        '--expect=[comma-separated list of keys to complete fzf]:keys:'
        '--read0[read input delimited by ASCII NUL characters]'
        '--print0[print output delimited by ASCII NUL characters]'
        '--no-clear[do not clear finder on exit]'
        '--sync[synchronous search for multi-staged filtering]'
        '--help[print help]'
        '--version[print version]'
    )
    _arguments -s -S $opts '*:file:_files'
}
compdef _fzf_flags fzf

_curl_common_flags() {
    local -a opts
    opts=(
        {-o,--output}'=[write output to file]:file:_files'
        {-O,--remote-name}'[write output to file named as remote]'
        {-L,--location}'[follow redirects]'
        {-s,--silent}'[silent mode]'
        {-S,--show-error}'[show error even when -s is used]'
        {-f,--fail}'[fail silently on HTTP errors]'
        {-i,--include}'[include response headers in output]'
        {-I,--head}'[fetch headers only]'
        {-v,--verbose}'[verbose output]'
        {-X,--request}'=[specify request method]:method:(GET POST PUT PATCH DELETE HEAD OPTIONS)'
        {-H,--header}'=[pass custom header]:header:'
        {-d,--data}'=[send data in POST request]:data:'
        {-u,--user}'=[server user and password]:user:password:'
        {-k,--insecure}'[allow insecure SSL connections]'
        '--compressed[request compressed response]'
        {-A,--user-agent}'=[send user-agent string]:agent:'
        {-b,--cookie}'=[send cookies]:cookies:'
        {-c,--cookie-jar}'=[save cookies to file]:file:_files'
        '--connect-timeout=[max time for connection]:seconds:'
        {-m,--max-time}'=[max time allowed for transfer]:seconds:'
        '--retry=[retry request N times]:n:'
        {-e,--referer}'=[send referer URL]:url:'
        '--http1.1[use HTTP 1.1]'
        '--http2[use HTTP 2]'
        '--http3[use HTTP 3]'
        '--proxy=[use proxy]:proxy:'
        {-4,--ipv4}'[resolve names to IPv4 addresses only]'
        {-6,--ipv6}'[resolve names to IPv6 addresses only]'
        {-T,--upload-file}'=[transfer local file to destination]:file:_files'
        '--limit-rate=[limit transfer speed]:rate:'
        {-#,--progress-bar}'[display progress as a bar]'
        '--help[show help]'
        '--version[show version]'
    )
    _arguments -s -S $opts ':url:'
}
compdef _curl_common_flags curl

_wget_flags() {
    local -a opts
    opts=(
        {-q,--quiet}'[turn off output]'
        {-v,--verbose}'[be verbose]'
        {-O,--output-document}'=[write output to file]:file:_files'
        {-c,--continue}'[resume getting a partially-downloaded file]'
        {-N,--timestamping}'[do not re-retrieve files unless newer than local]'
        '--no-clobber[do not overwrite existing files]'
        {-r,--recursive}'[recursive download]'
        {-l,--level}'=[maximum recursion depth]:depth:'
        '--no-parent[do not ascend to the parent directory]'
        {-p,--page-requisites}'[download all assets needed to display HTML page]'
        {-k,--convert-links}'[convert links suitable for local viewing]'
        {-P,--directory-prefix}'=[save files to prefix]:directory:_files -/'
        '--reject=[reject files matching pattern]:pattern:'
        '--accept=[accept files matching pattern]:pattern:'
        '--no-check-certificate[do not validate server certificate]'
        '--user=[set http user]:user:'
        '--password=[set http password]:password:'
        '--limit-rate=[limit download rate]:rate:'
        {-t,--tries}'=[set number of retries]:n:'
        '--timeout=[set timeout in seconds]:seconds:'
        '--proxy=[use proxy]:proxy:'
        '--no-proxy[do not use proxy]'
        '--spider[do not download, check if exists]'
        {-b,--background}'[go to background after startup]'
        '--mirror[turn on options suitable for mirroring]'
        '--help[print help]'
        '--version[print version]'
    )
    _arguments -s -S $opts ':url:'
}
compdef _wget_flags wget

_ssh_custom_flags() {
    local -a opts
    opts=(
        {-p,--port}'=[port to connect to]:port:'
        '-i[identity file (private key)]:file:_files'
        '-l[login name]:user:'
        '-L[local port forwarding]:spec:'
        '-R[remote port forwarding]:spec:'
        '-D[dynamic port forwarding (SOCKS)]:port:'
        '-N[do not execute remote command]'
        '-f[go to background before command execution]'
        '-T[disable pseudo-tty allocation]'
        '-t[force pseudo-tty allocation]'
        '-A[enable agent forwarding]'
        '-X[enable X11 forwarding]'
        '-C[enable compression]'
        '-v[verbose mode (use -vvv for more)]'
        '-q[quiet mode]'
        '-o[set ssh option]:option:'
        '-J[jump host proxy]:jumphost:'
        '-4[use IPv4 only]'
        '-6[use IPv6 only]'
        '-F[use alternative config file]:file:_files'
        '-E[append debug logs to file]:file:_files'
        '-W[forward stdio to host]:host\:port:'
        '-S[control socket path]:path:_files'
        '-M[master mode for connection sharing]'
        '-w[tunnel device forwarding]:local\:remote:'
        '-b[bind address]:address:'
        '-c[cipher spec]:cipher:(aes128-ctr aes256-ctr chacha20-poly1305)'
        '-k[disable GSSAPI authentication]'
        '-K[enable GSSAPI authentication]'
    )
    _arguments -s $opts ':host:_ssh_hosts' ':command:'
}
compdef _ssh_custom_flags ssh

_tar_flags() {
    local -a opts
    opts=(
        {-c,--create}'[create a new archive]'
        {-x,--extract}'[extract files from an archive]'
        {-t,--list}'[list the contents of an archive]'
        {-r,--append}'[append files to the end of an archive]'
        {-u,--update}'[only append files newer than copy in archive]'
        {-f,--file}'=[use archive file]:archive:_files'
        {-v,--verbose}'[verbosely list files processed]'
        {-z,--gzip}'[filter archive through gzip]'
        {-j,--bzip2}'[filter archive through bzip2]'
        {-J,--xz}'[filter archive through xz]'
        '--zstd[filter archive through zstd]'
        {-C,--directory}'=[change to directory before doing anything]:dir:_files -/'
        {-p,--preserve-permissions}'[extract without altering permissions]'
        '--strip-components=[strip leading path components]:n:'
        {-k,--keep-old-files}'[do not overwrite existing files]'
        '--overwrite[overwrite existing files when extracting]'
        {-m,--touch}'[do not extract file modified time]'
        '--exclude=[exclude files matching pattern]:pattern:'
        {-T,--files-from}'=[get names to extract or create from file]:file:_files'
        '--checkpoint[display progress messages]'
        '--totals[print total bytes written]'
        '--help[print help]'
        '--version[print version]'
    )
    _arguments -s $opts '*:file:_files'
}
compdef _tar_flags tar

_docker_custom() {
    local -a subcmds
    subcmds=(
        'run:run a command in a new container'
        'exec:run a command in a running container'
        'ps:list containers'
        'images:list images'
        'build:build an image from a Dockerfile'
        'pull:download an image from a registry'
        'push:upload an image to a registry'
        'stop:stop one or more running containers'
        'start:start one or more stopped containers'
        'restart:restart one or more containers'
        'rm:remove one or more containers'
        'rmi:remove one or more images'
        'logs:fetch the logs of a container'
        'inspect:return low-level information on objects'
        'stats:display live resource usage statistics'
        'top:display running processes of a container'
        'cp:copy files between container and local filesystem'
        'volume:manage volumes'
        'network:manage networks'
        'compose:docker compose commands'
        'system:manage docker system'
        'info:display system-wide information'
        'version:show docker version'
    )
    local -a run_opts
    run_opts=(
        {-d,--detach}'[run container in background]'
        {-i,--interactive}'[keep stdin open]'
        {-t,--tty}'[allocate a pseudo-TTY]'
        '--rm[automatically remove the container when it exits]'
        {-p,--publish}'=[publish port(s) to the host]:ports:'
        {-v,--volume}'=[bind mount a volume]:volume:'
        '--mount=[attach a filesystem mount]:mount:'
        {-e,--env}'=[set environment variables]:env:'
        '--env-file=[read environment variables from a file]:file:_files'
        '--name=[assign a name to the container]:name:'
        '--network=[connect to a network]:network:'
        '--hostname=[set container hostname]:hostname:'
        {-u,--user}'=[username or UID]:user:'
        {-w,--workdir}'=[working directory inside the container]:dir:'
        '--entrypoint=[override default entrypoint]:entrypoint:'
        '--restart=[restart policy]:policy:(no always unless-stopped on-failure)'
        '--memory=[memory limit]:limit:'
        '--cpus=[number of CPUs]:cpus:'
        '--platform=[set platform]:platform:(linux/amd64 linux/arm64)'
        '--privileged[give extended privileges to this container]'
        '--read-only[mount container root filesystem as read only]'
        '--help[show help]'
    )
    case "$words[2]" in
        run)  _arguments -s $run_opts ':image:' ':command:' ;;
        *)    _describe 'docker command' subcmds ;;
    esac
}
compdef _docker_custom docker

_npm_custom() {
    local -a subcmds
    subcmds=(
        'install:install packages'
        'uninstall:remove packages'
        'update:update packages'
        'run:run a package script'
        'start:run the start script'
        'test:run the test script'
        'build:run the build script'
        'init:create a package.json'
        'publish:publish a package to the registry'
        'pack:create a tarball from a package'
        'audit:run a security audit'
        'outdated:check for outdated packages'
        'list:list installed packages'
        'info:show npm package info'
        'search:search npm registry'
        'link:create symlink to package'
        'exec:run a command from npm package'
        'ci:clean install from package-lock.json'
        'version:bump package version'
        'login:log in to registry'
        'logout:log out of registry'
        'whoami:show current npm user'
        'config:manage npm config'
        'cache:manage npm cache'
    )
    local -a install_opts
    install_opts=(
        {-g,--global}'[install globally]'
        {-D,--save-dev}'[save to devDependencies]'
        {-P,--save-prod}'[save to dependencies (default)]'
        {-O,--save-optional}'[save to optionalDependencies]'
        '--no-save[do not save to package.json]'
        '--legacy-peer-deps[ignore peer dependency conflicts]'
        '--force[force installation]'
        '--dry-run[report what would be done without doing it]'
        {-E,--save-exact}'[save exact version]'
        '--prefer-offline[use cached data where possible]'
        '--prefer-online[force fetching from registry]'
        '--package-lock-only[only update package-lock.json]'
        '--ignore-scripts[do not run scripts defined in package.json]'
        {-q,--quiet}'[only show warnings and errors]'
        '--help[show help]'
    )
    case "$words[2]" in
        install|i|add) _arguments -s $install_opts ':package:' ;;
        run)           _npm_run ;;
        *)             _describe 'npm command' subcmds ;;
    esac
}
compdef _npm_custom npm

_python_flags() {
    local -a opts
    opts=(
        '-c[execute python code]:code:'
        '-m[run library module as a script]:module:'
        '-i[inspect interactively after running script]'
        '-u[force stdout and stderr to be unbuffered]'
        '-v[verbose (trace import statements)]'
        '-q[do not print version message on startup]'
        '-O[optimize generated bytecode slightly]'
        '-OO[remove docstrings in addition to -O]'
        '-B[do not write .py[co] files on impact]'
        '-S[do not imply import site on initialization]'
        '-E[ignore PYTHON* environment variables]'
        '-W[warning control]:warning:(default ignore always error)'
        '-x[skip first line of source]'
        '--check-hash-based-pycs=[control validation of hash-based .pyc files]:mode:(always never default)'
        '--help[show help]'
        '--version[print version]'
        '*:file:_files -g "*.py"'
    )
    _arguments -s $opts
}
compdef _python_flags python python3

_pip_flags() {
    local -a subcmds
    subcmds=(
        'install:install packages'
        'uninstall:uninstall packages'
        'freeze:output installed packages in requirements format'
        'list:list installed packages'
        'show:show information about installed packages'
        'download:download packages'
        'wheel:build wheels from requirements'
        'hash:compute hashes of package archives'
        'check:verify installed packages have compatible dependencies'
        'config:manage local and global configuration'
        'cache:inspect and manage pip cache'
        'debug:show debug information'
        'inspect:inspect the python environment'
    )
    local -a install_opts
    install_opts=(
        {-r,--requirement}'=[install from requirements file]:file:_files'
        {-U,--upgrade}'[upgrade all packages to newest version]'
        {-q,--quiet}'[give less output]'
        {-v,--verbose}'[give more output]'
        '--dry-run[do not install anything, just print what would be]'
        '--user[install to the user site-packages directory]'
        '--target=[install into target directory]:dir:_files -/'
        '--prefix=[installation prefix]:dir:_files -/'
        '--no-deps[do not install package dependencies]'
        '--ignore-installed[ignore the installed packages]'
        '--force-reinstall[reinstall all packages even if up to date]'
        '--pre[include pre-release and development versions]'
        '--index-url=[base URL of Python Package Index]:url:'
        '--extra-index-url=[extra URLs of package indexes]:url:'
        '--no-index[ignore package index (only --find-links URLs)]'
        '--find-links=[look for archives in directory or URL]:path:'
        '--trusted-host=[mark host as trusted]:host:'
        '--break-system-packages[allow pip to modify system packages]'
        '--no-cache-dir[disable the cache]'
        '--isolated[run in an isolated mode]'
        '--help[show help]'
    )
    case "$words[2]" in
        install)   _arguments -s $install_opts ':package:' ;;
        *)         _describe 'pip command' subcmds ;;
    esac
}
compdef _pip_flags pip pip3

_systemctl_custom() {
    local -a subcmds
    subcmds=(
        'start:start unit(s)'
        'stop:stop unit(s)'
        'restart:restart unit(s)'
        'reload:reload unit(s)'
        'enable:enable unit(s)'
        'disable:disable unit(s)'
        'status:show runtime status of unit(s)'
        'is-active:check whether units are active'
        'is-enabled:check whether units are enabled'
        'is-failed:check whether units are failed'
        'list-units:list loaded units'
        'list-unit-files:list installed unit files'
        'daemon-reload:reload systemd manager configuration'
        'mask:mask unit(s) to prevent starting'
        'unmask:unmask unit(s)'
        'show:show properties of unit(s)'
        'cat:show unit file(s)'
        'edit:edit unit file(s)'
        'reboot:reboot the system'
        'poweroff:power off the system'
        'suspend:suspend the system'
        'hibernate:hibernate the system'
        'log:show journal logs for a unit'
    )
    local -a common_opts
    common_opts=(
        {-a,--all}'[show all units/properties, including dead/empty ones]'
        '--failed[list failed units]'
        {-H,--host}'=[connect to remote host]:host:'
        {-M,--machine}'=[connect to container]:machine:'
        '--no-pager[do not pipe output into a pager]'
        '--no-legend[do not print headers and footers]'
        '--no-ask-password[do not ask for system passwords]'
        '--now[when enabling/disabling, also start/stop unit]'
        {-q,--quiet}'[suppress output]'
        {-t,--type}'=[list units of a particular type]:type:(service socket target mount automount timer path slice scope)'
        '--state=[list units with particular state]:state:(active inactive failed running dead)'
        '--help[show help]'
    )
    _arguments -s $common_opts ':command:->cmd' && return
    _describe 'systemctl command' subcmds
}
compdef _systemctl_custom systemctl

_apt_custom() {
    local -a subcmds
    subcmds=(
        'install:install packages'
        'remove:remove packages'
        'purge:remove packages and config files'
        'update:update package index'
        'upgrade:upgrade all upgradable packages'
        'full-upgrade:upgrade + remove obsolete packages'
        'autoremove:remove automatically installed unused packages'
        'autoclean:erase old downloaded archive files'
        'clean:erase all downloaded archive files'
        'search:search package descriptions'
        'show:show package details'
        'list:list packages based on criteria'
        'depends:show package dependencies'
        'rdepends:show reverse dependencies'
        'download:download package binary to current dir'
        'source:fetch source package'
        'changelog:show package changelog'
        'satisfy:satisfy dependency strings'
        'edit-sources:edit sources.list'
    )
    local -a global_opts
    global_opts=(
        {-y,--yes}'[automatic yes to all prompts]'
        {-q,--quiet}'[produce less output (repeat for quieter)]'
        {-s,--simulate}'[no-act simulation mode]'
        '--dry-run[alias for --simulate]'
        {-d,--download-only}'[download only, do not install or unpack]'
        '--no-download[disables downloading of packages]'
        '--fix-missing[ignore missing packages]'
        '--fix-broken[attempt to fix broken dependencies]'
        '--ignore-missing[ignore missing packages]'
        {-f,--fix-broken}'[fix broken dependencies]'
        {-V,--verbose-versions}'[show full versions for upgraded packages]'
        '--no-upgrade[do not upgrade, only install new packages]'
        '--only-upgrade[only upgrade, do not install new packages]'
        '--reinstall[reinstall packages that are already installed]'
        '--no-install-recommends[do not consider recommended packages]'
        '--install-suggests[consider suggested packages as dependencies]'
        '--no-install-suggests[do not consider suggested packages]'
        '--allow-unauthenticated[allow installing unauthenticated packages]'
        '--allow-downgrades[allow downgrading of packages]'
        '--allow-remove-essential[allow removal of essential packages]'
        '--allow-change-held-packages[allow changes to held packages]'
        '--purge[use purge instead of remove for anything removed]'
        '--auto-remove[alias for autoremove]'
        '--mark-auto[mark installed packages as automatically installed]'
        {-t,--target-release}'=[target release to get packages from]:release:'
        '--default-release=[alias for --target-release]:release:'
        {-a,--host-architecture}'=[set the host architecture]:arch:(amd64 arm64 armhf i386)'
        '--trivial-only[only perform trivial operations]'
        '--print-uris[print URIs of packages to be installed]'
        {-b,--compile}'[compile source packages after downloading]'
        '--no-auto-remove[do not remove unused packages]'
        '--show-progress[show text progress indicator]'
        '--with-source=[add a source file]:file:_files'
        {-o,--option}'=[set a configuration option]:option:'
        {-c,--config-file}'=[read this config file]:file:_files'
        '--color[always use color in output]'
        '--no-color[never use color in output]'
        {-h,--help}'[show help]'
        {-v,--version}'[show version]'
    )
    local -a install_opts
    install_opts=(
        ${global_opts[@]}
        '--no-install-recommends[do not install recommended packages]'
        '--install-suggests[also install suggested packages]'
        '--reinstall[reinstall even if already up-to-date]'
        '--only-upgrade[only upgrade packages, do not install new]'
        '--no-upgrade[skip packages that are already installed]'
        '*:package:->pkg'
    )
    local -a list_opts
    list_opts=(
        '--installed[list installed packages]'
        '--upgradable[list upgradable packages]'
        '--all-versions[list all available versions]'
        {-a,--all-versions}'[show all versions]'
    )
    case "$words[2]" in
        install) _arguments -s $install_opts ;;
        remove|purge) _arguments -s ${global_opts[@]} '*:package:->pkg' ;;
        show|download|depends|rdepends|changelog) _arguments -s ${global_opts[@]} '*:package:->pkg' ;;
        list) _arguments -s $list_opts ;;
        upgrade|full-upgrade|autoremove|autoclean|clean|update) _arguments -s ${global_opts[@]} ;;
        search) _arguments -s ${global_opts[@]} ':search term:' ;;
        '') _describe 'apt subcommand' subcmds ;;
        *) _arguments -s ${global_opts[@]} ;;
    esac
    if [[ "$state" == pkg ]]; then
        local -a pkgs
        pkgs=(${(f)"$(apt-cache pkgnames 2>/dev/null | sort)"})
        _describe 'package' pkgs
    fi
}
compdef _apt_custom apt

_apt_get_custom() {
    local -a subcmds
    subcmds=(
        'install:install packages'
        'remove:remove packages'
        'purge:remove packages and config files'
        'update:update package index'
        'upgrade:upgrade packages'
        'dist-upgrade:upgrade + handle changing dependencies'
        'autoremove:remove unused automatically-installed packages'
        'autoclean:erase old downloaded archive files'
        'clean:erase all downloaded archive files'
        'check:update cache and check for broken dependencies'
        'download:download binary package into current dir'
        'source:download source packages'
        'build-dep:install build dependencies for source package'
        'satisfy:satisfy dependency strings'
        'changelog:show changelog for package'
    )
    local -a opts
    opts=(
        {-y,--yes,--assume-yes}'[automatic yes to prompts]'
        {-q,--quiet}'[produce loggable output (no progress indicators)]'
        {-s,--simulate,--just-print,--dry-run,--recon,--no-act}'[no-act simulation]'
        {-d,--download-only}'[download only]'
        {-f,--fix-broken}'[attempt to fix broken dependencies]'
        {-m,--ignore-missing,--fix-missing}'[ignore missing packages]'
        '--no-download[disables downloading]'
        {-b,--compile}'[compile source packages after downloading]'
        '--ignore-hold[ignore hold on packages]'
        '--no-upgrade[do not upgrade packages]'
        '--only-upgrade[only upgrade already installed packages]'
        '--reinstall[reinstall packages]'
        '--no-install-recommends[do not install recommended packages]'
        '--install-suggests[consider suggested packages]'
        '--allow-unauthenticated[allow unauthenticated packages]'
        '--allow-downgrades[allow downgrading packages]'
        '--allow-remove-essential[allow removing essential packages]'
        '--force-yes[force yes (dangerous, prefer --allow-*)]'
        '--print-uris[print the URIs of packages to install]'
        '--purge[use purge instead of remove]'
        '--auto-remove[remove unused packages (like autoremove)]'
        {-t,--target-release}'=[target a specific release]:release:'
        {-a,--host-architecture}'=[set host architecture]:arch:(amd64 arm64 armhf i386)'
        '--trivial-only[only perform trivial operations]'
        {-o,--option}'=[set a configuration option]:option:'
        {-c,--config-file}'=[read config file]:file:_files'
        {-h,--help}'[show help text]'
        {-v,--version}'[show version]'
        '*:package:->pkg'
    )
    case "$words[2]" in
        '') _describe 'apt-get subcommand' subcmds ;;
        *)  _arguments -s $opts ;;
    esac
    [[ "$state" == pkg ]] && {
        local -a pkgs
        pkgs=(${(f)"$(apt-cache pkgnames 2>/dev/null | sort)"})
        _describe 'package' pkgs
    }
}
compdef _apt_get_custom apt-get

apti() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: apti [apt-flags] <package...>"
        echo "Examples:"
        echo "  apti gh eza                            # install normally"
        echo "  apti --no-install-recommends gh eza   # without recommends"
        echo "  apti --dry-run gh                     # simulate install"
        return 1
    fi
    sudo apt install "$@"
}
_apti() { _apt_get_custom }
compdef _apti apti

# ── Key bindings ─────────────────────────────────────
bindkey '^[[A'    history-substring-search-up
bindkey '^[[B'    history-substring-search-down
bindkey '^R'      fzf-history-widget
bindkey '^F'      fzf-file-widget
bindkey '^[c'     fzf-cd-widget
bindkey '^[[H'    beginning-of-line
bindkey '^[[F'    end-of-line
bindkey '^[[3~'   delete-char
bindkey '^H'      backward-kill-word
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word

# ── Zoxide (smart cd) ────────────────────────────────
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init zsh)"
    alias cd='z'
fi

# ── thefuck ──────────────────────────────────────────
if command -v thefuck &>/dev/null; then
    eval $(thefuck --alias)
    alias f='fuck'
fi

# ── FZF config ───────────────────────────────────────
export FZF_DEFAULT_OPTS="
  --height=40% --layout=reverse --border=rounded --info=inline
  --prompt='❯ ' --pointer='▶' --marker='✓'
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc
  --color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8"
export FZF_CTRL_R_OPTS="--preview 'echo {}' --preview-window=down:3:wrap"
export FZF_CTRL_T_OPTS="--preview 'bat --color=always {} 2>/dev/null || cat {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} 2>/dev/null || ls -la {}'"
[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -f /usr/share/doc/fzf/examples/completion.zsh  ]] && source /usr/share/doc/fzf/examples/completion.zsh

# ── bat (better cat) ─────────────────────────────────
if command -v batcat &>/dev/null; then alias bat='batcat'; fi
if command -v bat &>/dev/null; then
    export BAT_THEME="Monokai Extended"
    alias cat='bat --paging=never'
    alias less='bat --paging=always'
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
fi

# ── eza (better ls) ──────────────────────────────────
if command -v eza &>/dev/null; then
    alias ls='eza --icons --group-directories-first'
    alias ll='eza --icons --long --group-directories-first --git'
    alias la='eza --icons --long --all --group-directories-first --git'
    alias lt='eza --icons --tree --level=2 --group-directories-first'
    alias lta='eza --icons --tree --level=3 --all --group-directories-first'
    alias l='eza --icons -1 --group-directories-first'
else
    alias ls='ls --color=auto'; alias ll='ls -lhF'; alias la='ls -lahF'
fi

# ── git delta (better diffs) ─────────────────────────
if command -v delta &>/dev/null; then
    git config --global core.pager 'delta'
    git config --global delta.navigate true
    git config --global delta.light false
    git config --global delta.line-numbers true
    git config --global delta.syntax-theme 'Monokai Extended'
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global merge.conflictstyle diff3
fi

# ── Aliases ──────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias mkdir='mkdir -pv'
alias zshrc='${EDITOR:-nano} ~/.zshrc && source ~/.zshrc'
alias zshcustom='${EDITOR:-nano} ~/.zshrc_custom && source ~/.zshrc_custom'
alias p10kconfig='${EDITOR:-nano} ~/.p10k.zsh'
alias glog="git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
alias gst='git status -sb'
alias gdiff='git diff --stat'
alias gwip='git add -A && git commit -m "WIP: work in progress"'
alias gundo='git reset HEAD~1 --soft'
alias gclean='git branch --merged | grep -v "\*\|main\|master\|develop" | xargs -n 1 git branch -d'
alias myip='curl -s ifconfig.me && echo'
alias localip="ip addr show | grep 'inet ' | awk '{print \$2}'"
alias ports='ss -tulpn'
alias ping='ping -c 5'
alias df='df -hT'
alias du='du -sh'
alias dud='du -d 1 -h'
alias psg='ps aux | grep -v grep | grep'
alias path='echo $PATH | tr ":" "\n"'
alias reload='source ~/.zshrc'
alias week='date +%V'
alias timestamp='date +%Y%m%d_%H%M%S'
alias pubkey='cat ~/.ssh/id_rsa.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null'
alias grep='grep --color=auto'

# ── Functions ────────────────────────────────────────
mkcd() { mkdir -p "$1" && cd "$1"; }

extract() {
    [ -z "$1" ] && echo "Usage: extract <archive>" && return 1
    case "$1" in
        *.tar.bz2) tar xjf "$1"  ;; *.tar.gz)  tar xzf "$1"  ;;
        *.tar.xz)  tar xJf "$1"  ;; *.tar)     tar xf  "$1"  ;;
        *.bz2)     bunzip2 "$1"  ;; *.gz)      gunzip  "$1"  ;;
        *.zip)     unzip   "$1"  ;; *.7z)      7z x    "$1"  ;;
        *.rar)     unrar x "$1"  ;; *.xz)      xz -d   "$1"  ;;
        *) echo "Don't know how to extract '$1'" ;;
    esac
}

fcd() {
    local dir
    dir=$(find "${1:-.}" -type d 2>/dev/null \
        | fzf +m --preview 'eza --color=always {} 2>/dev/null || ls {}') \
    && cd "$dir"
}

fkill() {
    local pid
    pid=$(ps aux | fzf --header='Select process to kill' | awk '{print $2}')
    [ -n "$pid" ] && kill -${1:-9} "$pid" && echo "Killed PID $pid"
}

fgit() {
    local branch
    branch=$(git branch --all \
        | fzf --preview "git log --oneline --color=always \$(echo {} | sed 's/remotes\/origin\///' | xargs)" \
        | sed 's/remotes\/origin\///' | xargs)
    [ -n "$branch" ] && git checkout "$branch"
}

up() {
    local d="" limit="${1:-1}"
    for ((i=1; i<=limit; i++)); do d="../$d"; done
    cd "$d"
}

backup() {
    [ -z "$1" ] && echo "Usage: backup <file>" && return 1
    local dest="${1}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$1" "$dest" && echo "✔ Backup: $dest"
}

serve() { python3 -m http.server "${1:-8000}"; }
calc() { echo "$*" | bc -l; }
weather() { curl -s "wttr.in/${1:-}?format=3"; }

sshkey() {
    local name="${1:-id_ed25519}"
    ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f ~/.ssh/"$name"
    echo "Public key:"; cat ~/.ssh/"${name}.pub"
}

gitignore() { curl -sL "https://www.toptal.com/developers/gitignore/api/$*"; }

compinit_refresh() {
    echo "Refreshing CLI completions..."
    local comp_dir="$HOME/.zsh/completions"
    mkdir -p "$comp_dir"
    local added=0 removed=0

    for f in "$comp_dir"/_*(N); do
        if [[ ! -s "$f" ]]; then
            rm -f "$f"
            echo "  ✘ removed empty: ${f:t}"
            (( removed++ ))
        elif ! grep -qE '(#compdef|compdef )' "$f" 2>/dev/null; then
            rm -f "$f"
            echo "  ✘ removed invalid: ${f:t} (no #compdef header)"
            (( removed++ ))
        fi
    done

    _rc_try() {
        local out="$1" tool="$2"; shift 2
        local tmp; tmp=$(mktemp)
        # Run under zsh to match user environment and PATH
        zsh -c "$* > '$tmp' 2>/dev/null" 2>/dev/null
        if [[ -s "$tmp" ]] && grep -qE '(#compdef|compdef )' "$tmp"; then
            mv -f "$tmp" "$out"
            echo "  ✔ $tool"
            (( added++ ))
            return 0
        fi
        rm -f "$tmp"
        return 1
    }

    # GROUP 1: <tool> completion zsh
    for tool in docker kubectl helm kind k3d minikube stern argocd flux \
                golangci-lint goreleaser hugo operator-sdk; do
        command -v "$tool" &>/dev/null || continue
        _rc_try "$comp_dir/_${tool}" "$tool" "$tool" completion zsh || \
            echo "  ✘ $tool — completion output invalid (skipped)"
    done

    # GROUP 2: gh — completion -s zsh
    if command -v gh &>/dev/null; then
        _rc_try "$comp_dir/_gh" gh gh completion -s zsh || \
            echo "  ✘ gh — completion output invalid (skipped)"
    fi

    # GROUP 2.5: <tool> --completions zsh
    # just uses --completions (double-dash flag), not a subcommand
    for tool in just; do
        command -v "$tool" &>/dev/null || continue
        _rc_try "$comp_dir/_${tool}" "$tool" "$tool" --completions zsh || \
            echo "  ✘ $tool — completion output invalid (skipped)"
    done

    # GROUP 3: <tool> completions zsh
    for tool in rustup cargo volta fnm poetry rye \
                mise vault consul nomad packer waypoint; do
        command -v "$tool" &>/dev/null || continue
        _rc_try "$comp_dir/_${tool}" "$tool" "$tool" completions zsh
    done

    # GROUP 3.5: pipx — register-python-argcomplete
    if command -v pipx &>/dev/null && command -v register-python-argcomplete &>/dev/null; then
        local _pipx_tmp; _pipx_tmp=$(mktemp)
        register-python-argcomplete pipx > "$_pipx_tmp" 2>/dev/null
        if grep -qE '(#compdef|compdef )' "$_pipx_tmp" 2>/dev/null; then
            mv -f "$_pipx_tmp" "$comp_dir/_pipx"
            echo "  ✔ pipx"
            (( added++ ))
        else
            rm -f "$_pipx_tmp"
            echo "  ✘ pipx — argcomplete failed (skipped)"
        fi
    fi

    # GROUP 4: uv — generate-shell-completion zsh
    if command -v uv &>/dev/null; then
        _rc_try "$comp_dir/_uv" uv uv generate-shell-completion zsh || \
            echo "  ✘ uv — completion output invalid (skipped)"
    fi

    # GROUP 5: rg — --generate=complete-zsh
    if command -v rg &>/dev/null; then
        _rc_try "$comp_dir/_rg" rg rg --generate=complete-zsh
    fi

    # GROUP 6: fd — --gen-completions zsh
    if command -v fd &>/dev/null; then
        _rc_try "$comp_dir/_fd" fd fd --gen-completions zsh
    fi

    # gcloud — re-source from SDK (not compdef based)
    if command -v gcloud &>/dev/null; then
        local _sdk _inc
        _sdk=$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)
        _inc="${_sdk}/completion.zsh.inc"
        # Fallback: sdk_root metadata may be wrong on Debian/Ubuntu apt installs
        if [[ ! -f "$_inc" ]]; then
            _inc=$(find /usr/share/google-cloud-sdk /usr/lib/google-cloud-sdk \
                -name "completion.zsh.inc" 2>/dev/null | head -1)
        fi
        if [[ -f "$_inc" ]]; then
            source "$_inc"
            echo "  ✔ gcloud (re-sourced from $_inc)"
        else
            echo "  ✘ gcloud — completion file not found"
            echo "    Run: find / -name 'completion.zsh.inc' 2>/dev/null"
        fi
    fi

    unset -f _rc_try

    rm -f ~/.zcompdump
    autoload -Uz compinit && compinit
    echo ""
    echo "✔ Done — $added registered, $removed broken files removed."
    echo "  Completions are live in this session."
}

register_completion() {
    local tool="$1"
    local method="${2:-auto}"
    local comp_dir="$HOME/.zsh/completions"
    mkdir -p "$comp_dir"

    if [[ -z "$tool" ]]; then
        echo "Usage: register_completion <tool> [zsh|completions|flag]"
        return 1
    fi

    if ! command -v "$tool" &>/dev/null; then
        echo "✗ '$tool' is not installed or not in PATH"
        return 1
    fi

    # ── Special case: gcloud uses source, not compdef ──
    if [[ "$tool" == "gcloud" ]]; then
        local _sdk _inc
        _sdk=$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)
        _inc="${_sdk}/completion.zsh.inc"
        # Fallback: sdk_root metadata may be wrong on Debian/Ubuntu apt installs
        if [[ ! -f "$_inc" ]]; then
            _inc=$(find /usr/share/google-cloud-sdk /usr/lib/google-cloud-sdk \
                -name "completion.zsh.inc" 2>/dev/null | head -1)
        fi
        if [[ -f "$_inc" ]]; then
            source "$_inc"
            echo "✔ 'gcloud' completion loaded from: $_inc"
            echo "  It is already configured in ~/.zshrc_custom to load automatically."
        else
            echo "✗ gcloud SDK completion file not found."
            echo "  Run: find / -name 'completion.zsh.inc' 2>/dev/null"
        fi
        return
    fi

    local tmp ok=0
    tmp=$(mktemp)

    _try_write() {
        local out="$1"; shift
        "$@" > "$out" 2>/dev/null
        [[ -s "$out" ]] && grep -qE '(#compdef|compdef )' "$out"
    }

    if [[ "$method" == "auto" ]]; then
        local -a attempts=(
            "$tool completion zsh"
            "$tool --completions zsh"
            "$tool completions zsh"
            "$tool completion --shell zsh"
            "$tool completions --shell zsh"
            "$tool completion -s zsh"
            "$tool completions -s zsh"
            "$tool --completion=zsh"
            "$tool --completion zsh"
            "$tool --generate=complete-zsh"
            "$tool --gen-completions=zsh"
            "$tool --gen-completions zsh"
            "$tool generate-shell-completion zsh"
            "$tool generate completion zsh"
            "$tool shell-completion zsh"
            "$tool shell completion zsh"
            "$tool init completions zsh"
            "$tool complete --shell=zsh"
            "$tool complete -s zsh"
            "$tool zsh-completion"
            "$tool zsh_completion"
        )

        for attempt in "${attempts[@]}"; do
            if [[ $ok -eq 0 ]]; then
                _try_write "$tmp" ${=attempt} && ok=1
            fi
        done
    else
        case "$method" in
            zsh)         _try_write "$tmp" "$tool" completion zsh && ok=1 ;;
            completions) _try_write "$tmp" "$tool" completions zsh && ok=1 ;;
            flag)        _try_write "$tmp" "$tool" --completion=zsh && ok=1 ;;
            generate)    _try_write "$tmp" "$tool" generate-shell-completion zsh && ok=1 ;;
            shell)       _try_write "$tmp" "$tool" completion --shell zsh && ok=1 ;;
        esac
    fi

    if [[ $ok -eq 1 ]]; then
        mv -f "$tmp" "$comp_dir/_${tool}"
        rm -f ~/.zcompdump
        autoload -Uz compinit && compinit -C
        echo "✔ '$tool' completion registered."
        echo "  Test it: $tool <Tab>   or   $tool --<Tab>"
    else
        rm -f "$tmp"
        echo "✗ Could not generate a valid completion for '$tool'."
        echo ""
        echo "  Tried all known methods automatically."
        echo "  Find the correct command with:"
        echo "    $tool --help | grep -i complet"
        echo "  Then register manually:"
        echo "    <correct command> > ~/.zsh/completions/_${tool}"
        echo "    compinit_refresh"
    fi

    unfunction _try_write 2>/dev/null
}

# ── Environment ──────────────────────────────────────
export EDITOR="${EDITOR:-nano}"
export VISUAL="$EDITOR"
export PAGER='less'
export LESS='-R --quit-if-one-screen --no-init'
export COLORTERM=truecolor
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
export YSU_MESSAGE_POSITION="after"
export YSU_MODE=ALL

cleanup_completions() {
    local comp_dir="$HOME/.zsh/completions"
    local removed=0
    echo "Scanning $comp_dir for broken completion files..."
    for f in "$comp_dir"/_*(N); do
        if [[ ! -s "$f" ]]; then
            echo "  ✘ removed (empty):   ${f:t}"
            rm -f "$f"; (( removed++ ))
        elif ! grep -qE '(#compdef|compdef )' "$f" 2>/dev/null; then
            echo "  ✘ removed (invalid): ${f:t}"
            rm -f "$f"; (( removed++ ))
        else
            echo "  ✔ ok:                ${f:t}"
        fi
    done
    if (( removed > 0 )); then
        rm -f ~/.zcompdump
        autoload -Uz compinit && compinit
        echo ""
        echo "✔ Removed $removed broken file(s) and rebuilt completion cache."
    else
        echo ""
        echo "✔ All completion files are valid. No action needed."
    fi
}
ZSHRC_EOF

    echo "✔ Custom config written to $CUSTOM_CONFIG"
}

wire_custom_config() {
    local marker="# >>> zsh-setup custom config <<<"
    if ! grep -q "$marker" "$HOME/.zshrc" 2>/dev/null; then
        cat >> "$HOME/.zshrc" << EOF

$marker
[[ -f ~/.zshrc_custom ]] && source ~/.zshrc_custom
# <<< zsh-setup custom config <<<
EOF
        echo "✔ ~/.zshrc_custom wired into .zshrc"
    fi
}

set_default_shell() {
    local shell_path; shell_path=$(which zsh)
    print_step "Setting Zsh as default shell..."
    sudo usermod --shell "$shell_path" "$USER"
    echo "✔ Default shell → $shell_path"

    local bashrc="$HOME/.bashrc"
    local marker="# >>> auto-switch to zsh <<<"
    if ! grep -q "$marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" << 'BASHRC_EOF'

# >>> auto-switch to zsh <
# Auto-switch to zsh (for VS Code and other terminals that default to bash)
[ -x /usr/bin/zsh ] && [ "$SHLVL" = "1" ] && exec /usr/bin/zsh -l
# <<< auto-switch to zsh <
BASHRC_EOF
        echo "✔ VS Code bash→zsh auto-switch added to ~/.bashrc"
    else
        echo "✔ VS Code bash→zsh auto-switch already present"
    fi
}

install_zsh() {
    echo ""
    echo "╔═════════════════════════════════════════════════╗"
    echo "║   Enhanced Zsh Setup — Powerlevel10k Edition   ║"
    echo "╚═════════════════════════════════════════════════╝"
    install_packages
    backup_zshrc
    install_oh_my_zsh
    install_plugins
    install_powerlevel10k
    write_custom_config
    wire_custom_config
    set +e
    setup_cli_completions
    set -e
    set_default_shell
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✔ Done! What's new:                                    ║"
    echo "║                                                         ║"
    echo "║  THEME    Powerlevel10k (run: p10k configure)           ║"
    echo "║  TOOLS    zoxide, bat, eza, delta, thefuck, tldr        ║"
    echo "║  PLUGINS  forgit, you-should-use, fzf-tab + more        ║"
    echo "║  FZF      Ctrl+R history · Ctrl+F files · Alt+C dirs    ║"
    echo "║  TAB      No-match msg · flag completion · CLI autocomp  ║"
    echo "║  ALIASES  ll/la/lt, glog, myip, ports, dud …           ║"
    echo "║  FUNCS    fcd fkill fgit up mkcd extract serve calc     ║"
    echo "║           weather backup sshkey gitignore               ║"
    echo "║           compinit_refresh · register_completion        ║"
    echo "║                                                         ║"
    echo "║  ❶ Install a Nerd Font → https://www.nerdfonts.com      ║"
    echo "║     Recommended: MesloLGS NF or JetBrainsMono NF       ║"
    echo "║  ❷ Set the font in your terminal emulator settings      ║"
    echo "║  ❸ Run: p10k configure                                  ║"
    echo "║  ❹ Personalize: ~/.zshrc_custom                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    exec zsh
}

remove_zsh() {
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  WARNING: Removes Zsh, Oh My Zsh, all tools  ║"
    echo "╚═══════════════════════════════════════════════╝"
    read -p "Continue? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$HOME/.oh-my-zsh"
        rm -f  "$HOME/.zshrc_custom" "$HOME/.p10k.zsh"
        local latest_backup
        latest_backup=$(ls -t "$HOME"/.zshrc.backup.* 2>/dev/null | head -1)
        [ -n "$latest_backup" ] && mv "$latest_backup" "$HOME/.zshrc" && echo "✔ Restored .zshrc"
        sudo chsh -s /bin/bash "$USER"
        echo "✔ Removal complete. Shell restored to Bash."
    else
        echo "Removal canceled."
    fi
}

case "$ACTION" in
    install) install_zsh ;;
    remove)  remove_zsh  ;;
    *)       echo "Usage: $0 [install|remove]"; exit 1 ;;
esac