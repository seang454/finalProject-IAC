#!/bin/bash
# Usage: ./zsh-setup.sh [install|remove]

set -e

ACTION=${1:-install}  # Default action is 'install'
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"

backup_zshrc() {
    if [ -f "$HOME/.zshrc" ]; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
        echo "Backup of .zshrc created."
    fi
}

install_packages() {
    echo "Installing dependencies..."
    sudo apt-get update -y
    sudo apt-get install -y zsh git curl fzf nodejs npm || true
}

install_oh_my_zsh() {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        echo "Installing Oh My Zsh..."
        RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    fi
}

install_plugins() {
    echo "Installing Zsh plugins..."
    mkdir -p "$ZSH_CUSTOM/plugins"

    # Disable Git prompts for this script
    export GIT_TERMINAL_PROMPT=0

    declare -A plugins
    plugins=(
        [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions.git"
        [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
        [zsh-history-substring-search]="https://github.com/zsh-users/zsh-history-substring-search.git"
        [zsh-autopair]="https://github.com/hlissner/zsh-autopair.git"
        [alias-finder]="https://github.com/Tarrasch/alias-finder.git"
        [zsh-nvm]="https://github.com/lukechilds/zsh-nvm.git"
        [fzf-tab]="https://github.com/Aloxaf/fzf-tab.git"
        [zsh-completions]="https://github.com/zsh-users/zsh-completions.git"
    )

    for plugin in "${!plugins[@]}"; do
        if [ ! -d "$ZSH_CUSTOM/plugins/$plugin" ]; then
            git clone --depth=1 --quiet "${plugins[$plugin]}" "$ZSH_CUSTOM/plugins/$plugin" || true
        fi
    done

    # Update .zshrc plugins line
    sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search zsh-autopair alias-finder zsh-nvm fzf-tab zsh-completions)/' "$HOME/.zshrc"
}

set_theme_agnoster() {
    echo "Setting Zsh theme to Agnoster..."
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' "$HOME/.zshrc"
}

set_default_shell() {
    local shell_path
    shell_path=$(which zsh)
    echo "Setting Zsh as the default shell..."
    sudo usermod --shell "$shell_path" "$USER"
}

install_zsh() {
    echo "=== Installing Zsh + Oh My Zsh + Plugins + Agnoster Theme ==="
    install_packages
    backup_zshrc
    install_oh_my_zsh
    install_plugins
    set_theme_agnoster
    set_default_shell
    echo "=== Installation complete! Launching Zsh now... ==="
    exec zsh
}

remove_zsh() {
    echo "=== WARNING: This will remove Zsh, Oh My Zsh, and all plugins! ==="
    read -p "Are you sure you want to continue? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$HOME/.oh-my-zsh"
        rm -rf "$ZSH_CUSTOM/plugins"
        mv "$HOME/.zshrc.backup"* "$HOME/.zshrc" 2>/dev/null || true
        sudo chsh -s /bin/bash "$USER"
        echo "=== Removal complete! Default shell is now Bash ==="
    else
        echo "=== Removal canceled ==="
    fi
}

case "$ACTION" in
    install) install_zsh ;;
    remove) remove_zsh ;;
    *) echo "Usage: $0 [install|remove]"; exit 1 ;;
esac
