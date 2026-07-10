#!/usr/bin/env bash
# bootstrap.sh
# Run this on a FRESH Fedora (KDE) install. It:
#   1. installs stow
#   2. clones your DOTFILES repo and stows it into $HOME
#   3. adds third-party repos
#   4. reinstalls your usual packages via dnf, Flatpak, and Homebrew,
#      using the package lists that live alongside this script
#
# NOTE: intentionally NOT using `set -e`. One failed package/repo/download
# should not kill the whole run -- we log it and keep going. We still use
# -u and pipefail to catch unset vars / broken pipes.
set -uo pipefail

DOTFILES_REPO="https://github.com/HananSolves/dotfiles.git"
DOTFILES_DIR="$HOME/dotfiles"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi

# ------------------------------------------------------------------
# Report tracking
# ------------------------------------------------------------------
declare -a OK_ITEMS=()
declare -a FAIL_ITEMS=()   # "label :: error message"

mark_ok() {
    OK_ITEMS+=("$1")
}

mark_fail() {
    # $1 = label, $2 = error message (last line or two of output)
    FAIL_ITEMS+=("$1 :: $2")
}

# Run a command, capture stdout+stderr, never let it kill the script.
# Usage: run_step "label" command args...
run_step() {
    local label="$1"; shift
    local output
    if output="$("$@" 2>&1)"; then
        mark_ok "$label"
        return 0
    else
        local err_line
        err_line="$(echo "$output" | tail -n 3 | tr '\n' ' ')"
        mark_fail "$label" "${err_line:-unknown error}"
        return 1
    fi
}

# ------------------------------------------------------------------
# 1. stow
# ------------------------------------------------------------------
echo "==> Installing prerequisite (stow)..."
run_step "stow (dnf)" sudo dnf install -y stow

# ------------------------------------------------------------------
# 2. dotfiles
# ------------------------------------------------------------------
echo "==> Fetching dotfiles from $DOTFILES_REPO ..."
if [ -d "$DOTFILES_DIR/.git" ]; then
    echo "    Repo already present at $DOTFILES_DIR, pulling latest..."
    run_step "dotfiles pull" git -C "$DOTFILES_DIR" pull --ff-only
else
    run_step "dotfiles clone" git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

echo "==> Symlinking dotfiles with stow..."
if [ -d "$DOTFILES_DIR" ]; then
    run_step "stow --restow" bash -c "cd '$DOTFILES_DIR' && stow --restow --target='$HOME' ."
else
    mark_fail "stow --restow" "dotfiles dir missing, skipped"
fi

# ------------------------------------------------------------------
# 3. third-party repos
# ------------------------------------------------------------------
echo "==> Installing third-party repo apps"
if [ -f "$SCRIPT_DIR/thirdparty-repos.sh" ]; then
    chmod +x "$SCRIPT_DIR/thirdparty-repos.sh"
    if output="$("$SCRIPT_DIR/thirdparty-repos.sh" 2>&1)"; then
        mark_ok "thirdparty-repos.sh"
    else
        err_line="$(echo "$output" | tail -n 3 | tr '\n' ' ')"
        mark_fail "thirdparty-repos.sh" "${err_line:-unknown error}"
        echo "    thirdparty-repos.sh had failures, continuing anyway."
    fi
else
    echo "    thirdparty-repos.sh not found, skipping."
fi

# ------------------------------------------------------------------
# 4. dnf packages (installed one at a time so one bad/missing
#    package doesn't take the rest down with it)
# ------------------------------------------------------------------
echo "==> Installing dnf packages..."
if [ -s "$SCRIPT_DIR/packages-dnf.txt" ]; then
    while IFS= read -r pkg; do
        # skip blank lines / comments
        [ -z "$pkg" ] && continue
        [[ "$pkg" == \#* ]] && continue
        run_step "dnf: $pkg" sudo dnf install -y "$pkg"
    done < "$SCRIPT_DIR/packages-dnf.txt"
else
    echo "    No packages-dnf.txt found next to this script, skipping."
fi

# ------------------------------------------------------------------
# 5. Flatpak apps
# ------------------------------------------------------------------
echo "==> Installing Flatpak apps..."
if [ -s "$SCRIPT_DIR/packages-flatpak.txt" ]; then
    if ! command -v flatpak &>/dev/null; then
        run_step "flatpak (dnf)" sudo dnf install -y flatpak
    fi
    if command -v flatpak &>/dev/null; then
        if ! flatpak remote-list | grep -q flathub; then
            run_step "flathub remote" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        fi
        while IFS= read -r app; do
            [ -z "$app" ] && continue
            [[ "$app" == \#* ]] && continue
            run_step "flatpak: $app" flatpak install -y flathub "$app"
        done < "$SCRIPT_DIR/packages-flatpak.txt"
    else
        mark_fail "flatpak apps" "flatpak itself failed to install, all flatpak apps skipped"
    fi
else
    echo "    No packages-flatpak.txt found next to this script, skipping."
fi

# ------------------------------------------------------------------
# 6. Homebrew
# ------------------------------------------------------------------
echo "==> Setting up Homebrew packages..."
if [ -f "$SCRIPT_DIR/Brewfile" ]; then
    if ! command -v brew &>/dev/null; then
        echo "    Homebrew not found, installing build tools + Homebrew..."
        run_step "dnf: development-tools group" sudo dnf group install -y development-tools
        run_step "dnf: procps-ng curl file" sudo dnf install -y procps-ng curl file
        if output="$(NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1)"; then
            mark_ok "Homebrew install"
        else
            err_line="$(echo "$output" | tail -n 3 | tr '\n' ' ')"
            mark_fail "Homebrew install" "${err_line:-unknown error}"
        fi
    fi

    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        run_step "brew bundle" brew bundle install --file="$SCRIPT_DIR/Brewfile"
        if ! grep -qs 'linuxbrew' "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null; then
            echo "    NOTE: add this line to your shell rc file (in your dotfiles repo)"
            echo "    so brew is on PATH in new terminals:"
            echo '      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
        fi
    else
        mark_fail "brew bundle" "brew binary not found, Homebrew install must have failed"
    fi
else
    echo "    No Brewfile found next to this script, skipping."
fi

# ------------------------------------------------------------------
# Final report
# ------------------------------------------------------------------
echo ""
echo "=================================================="
echo "                BOOTSTRAP REPORT"
echo "=================================================="
echo ""
echo "OK (${#OK_ITEMS[@]}):"
if [ "${#OK_ITEMS[@]}" -eq 0 ]; then
    echo "  (none)"
else
    for item in "${OK_ITEMS[@]}"; do
        echo "  [x] $item"
    done
fi

echo ""
echo "FAILED (${#FAIL_ITEMS[@]}):"
if [ "${#FAIL_ITEMS[@]}" -eq 0 ]; then
    echo "  (none)"
else
    for item in "${FAIL_ITEMS[@]}"; do
        label="${item%% :: *}"
        reason="${item#* :: }"
        echo "  [ ] $label"
        echo "        reason: $reason"
    done
fi

echo ""
echo "=================================================="
echo "Bootstrap complete. Log out/in (or reboot) so shell/env changes fully apply."
