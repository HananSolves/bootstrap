#!/usr/bin/env bash
# bootstrap.sh
# Run this on a FRESH Fedora (KDE) install. It:
#   1. installs stow
#   2. clones your DOTFILES repo and stows it into $HOME
#   3. adds third-party repos (so packages like wezterm are resolvable)
#   4. reinstalls your usual packages via dnf, Flatpak, and Homebrew,
#      using the package lists that live alongside this script
set -euo pipefail
DOTFILES_REPO="https://github.com/HananSolves/dotfiles.git"
DOTFILES_DIR="$HOME/dotfiles"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi
echo "==> Installing prerequisite (stow)..."
sudo dnf install -y stow
echo "==> Fetching dotfiles from $DOTFILES_REPO ..."
if [ -d "$DOTFILES_DIR/.git" ]; then
    echo "    Repo already present at $DOTFILES_DIR, pulling latest..."
    git -C "$DOTFILES_DIR" pull --ff-only
else
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi
echo "==> Symlinking dotfiles with stow..."
(cd "$DOTFILES_DIR" && stow --restow --target="$HOME" .)
echo "==> Installing third-party repo apps"
if [ -f "$SCRIPT_DIR/thirdparty-repos.sh" ]; then
    chmod +x "$SCRIPT_DIR/thirdparty-repos.sh"
    "$SCRIPT_DIR/thirdparty-repos.sh"
else
    echo "    thirdparty-repos.sh not found, skipping."
fi
echo "==> Installing dnf packages..."
if [ -s "$SCRIPT_DIR/packages-dnf.txt" ]; then
    xargs -a "$SCRIPT_DIR/packages-dnf.txt" sudo dnf install -y --skip-unavailable
else
    echo "    No packages-dnf.txt found next to this script, skipping."
fi
echo "==> Installing Flatpak apps..."
if [ -s "$SCRIPT_DIR/packages-flatpak.txt" ]; then
    if ! command -v flatpak &>/dev/null; then
        sudo dnf install -y flatpak
    fi
    if ! flatpak remote-list | grep -q flathub; then
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    xargs -a "$SCRIPT_DIR/packages-flatpak.txt" flatpak install -y flathub
else
    echo "    No packages-flatpak.txt found next to this script, skipping."
fi
echo "==> Setting up Homebrew packages..."
if [ -f "$SCRIPT_DIR/Brewfile" ]; then
    if ! command -v brew &>/dev/null; then
        echo "    Homebrew not found, installing build tools + Homebrew..."
        sudo dnf group install -y development-tools
        sudo dnf install -y procps-ng curl file
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    brew bundle install --file="$SCRIPT_DIR/Brewfile"
    if ! grep -qs 'linuxbrew' "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null; then
        echo "    NOTE: add this line to your shell rc file (in your dotfiles repo)"
        echo "    so brew is on PATH in new terminals:"
        echo '      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
    fi
else
    echo "    No Brewfile found next to this script, skipping."
fi
echo ""
echo "Bootstrap complete. Log out/in (or reboot) so shell/env changes fully apply."
