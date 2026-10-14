# shellcheck shell=bash
# lib/installers.sh - one function per kind of item. Each is called by
# process_item with the item name, does a single attempt, and returns
# 0 = installed (or already present; set ITEM_NOTE to say so),
# 2 = permanent failure, anything else = retryable failure.
# Every install is verified afterwards rather than trusting exit codes.

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/HananSolves/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
BREW_PREFIX="${BREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
BREW_INSTALLER_URL=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo

# ----------------------------------------------------------------- lists ----
# read_list FILE - package names, one per line; blank lines and # comments ignored
read_list() {
    [[ -f $1 ]] || return 0
    sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' "$1"
}
# brewfile_entries FILE KIND - names from lines like: brew "name", tap "user/repo"
brewfile_entries() {
    [[ -f $1 ]] || return 0
    sed -nE "s/^[[:space:]]*$2[[:space:]]+[\"']([^\"']+)[\"'].*/\1/p" "$1"
}

# ------------------------------------------------------------------- dnf ----
dnf_is_installed() {
    if [[ $1 == @* ]]; then
        # "dnf group list --installed" is unreliable in dnf5 (can report
        # nothing for a fully installed group); "group info" is trustworthy.
        dnf -q group info "${1#@}" 2>/dev/null | grep -qE '^Installed[[:space:]]*:[[:space:]]*yes'
    else
        rpm -q --quiet "$1" 2>/dev/null || rpm -q --quiet --whatprovides "$1" 2>/dev/null
    fi
}

install_dnf() {
    local pkg=$1 rc=0
    if dnf_is_installed "$pkg"; then
        ITEM_NOTE="already installed"
        return 0
    fi
    if [[ $pkg == @* ]]; then
        # groups: optional members may be missing from the repos - skip those
        run_cmd --root dnf group install -y --skip-unavailable "${DNF_OPTS[@]}" "${pkg#@}" || rc=$?
    else
        run_cmd --root dnf install -y "${DNF_OPTS[@]}" "$pkg" || rc=$?
    fi
    dnf_is_installed "$pkg" && return 0
    ((rc == 0)) && { FAIL_REASON="dnf finished but $pkg is not installed"; rc=1; }
    return "$rc"
}

setup_dnf_metadata() {
    run_cmd --root dnf makecache "${DNF_OPTS[@]}"
}

install_system_upgrade() {
    run_cmd --root dnf upgrade --refresh -y "${DNF_OPTS[@]}"
}

# --------------------------------------------------------------- flatpak ----
setup_flatpak() {
    if ! command -v flatpak &>/dev/null; then
        run_cmd --root dnf install -y "${DNF_OPTS[@]}" flatpak || return
    fi
    # Always use an explicit --user remote: a bare "flathub" is ambiguous (and
    # installs fail) once a system-wide flathub remote also exists, which
    # Fedora creates when third-party repos are enabled at install time.
    if flatpak remotes --user --columns=name 2>/dev/null | grep -qx flathub; then
        ITEM_NOTE="flathub remote present"
        return 0
    fi
    run_cmd flatpak remote-add --if-not-exists --user flathub "$FLATHUB_URL"
}

flatpak_is_installed() { flatpak info --user "$1" &>/dev/null; }

install_flatpak() {
    local app=$1 rc=0
    if flatpak_is_installed "$app"; then
        ITEM_NOTE="already installed"
        return 0
    fi
    # no --noninteractive: it also hides flatpak's progress bars
    run_cmd flatpak install -y --user flathub "$app" || rc=$?
    flatpak_is_installed "$app" && return 0
    ((rc == 0)) && { FAIL_REASON="flatpak finished but $app is not installed"; rc=1; }
    return "$rc"
}

# ------------------------------------------------------------------ brew ----
brew_load_env() {
    [[ -x $BREW_PREFIX/bin/brew ]] || return 1
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
    export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1
}

setup_homebrew() {
    if brew_load_env; then
        ITEM_NOTE="already installed"
        return 0
    fi
    local rc=0 installer="$DOWNLOAD_DIR/homebrew-install.sh"
    # build deps Homebrew documents for Fedora
    if ! dnf_is_installed @development-tools; then
        run_cmd --root dnf group install -y --skip-unavailable "${DNF_OPTS[@]}" development-tools || return
    fi
    run_cmd --root dnf install -y "${DNF_OPTS[@]}" procps-ng curl file git || return
    # Pre-create the prefix owned by us so the installer never has to call
    # sudo itself (it would prompt again inside its own terminal).
    if [[ ! -w $BREW_PREFIX ]]; then
        run_cmd --root mkdir -p "$BREW_PREFIX" || return
        run_cmd --root chown -R "$(id -un):$(id -gn)" "$(dirname "$BREW_PREFIX")" || return
    fi
    download "$BREW_INSTALLER_URL" "$installer" || return
    run_cmd env NONINTERACTIVE=1 /bin/bash "$installer" || rc=$?
    brew_load_env && { rm -f -- "$installer"; return 0; }
    ((rc == 0)) && rc=1
    return "$rc"
}

setup_brew_update() {
    run_cmd brew update
}

setup_brew_tap() {
    if brew tap 2>/dev/null | grep -qxi "$1"; then
        ITEM_NOTE="already tapped"
        return 0
    fi
    run_cmd brew tap "$1"
}

brew_is_installed() { brew list --formula "${1##*/}" &>/dev/null; }

install_brew() {
    local formula=$1 rc=0
    if brew_is_installed "$formula"; then
        ITEM_NOTE="already installed"
        return 0
    fi
    # Homebrew keeps partially downloaded bottles (*.incomplete) in its cache
    # and resumes them, so a retry after a dropped connection continues.
    run_cmd brew install "$formula" || rc=$?
    brew_is_installed "$formula" && return 0
    ((rc == 0)) && { FAIL_REASON="brew finished but $formula is not installed"; rc=1; }
    return "$rc"
}

# -------------------------------------------------------------- dotfiles ----
install_dotfiles_repo() {
    if [[ -d $DOTFILES_DIR/.git ]]; then
        if run_cmd git -C "$DOTFILES_DIR" pull --ff-only; then
            ITEM_NOTE="updated existing clone"
            return 0
        fi
        return 1
    fi
    if [[ -e $DOTFILES_DIR ]]; then
        # an interrupted clone can leave an empty dir behind - safe to remove
        if rmdir -- "$DOTFILES_DIR" 2>/dev/null; then
            :
        else
            FAIL_REASON="$DOTFILES_DIR exists and is not a git repository - move it aside and re-run"
            return 2
        fi
    fi
    run_cmd git clone --progress "$DOTFILES_REPO" "$DOTFILES_DIR"
}

install_dotfiles_stow() {
    [[ -d $DOTFILES_DIR ]] || { FAIL_REASON="dotfiles repo is not cloned"; return 2; }
    command -v stow &>/dev/null || { FAIL_REASON="stow is not installed"; return 2; }
    # A fresh Fedora install already has files like ~/.bashrc, which make
    # stow refuse to run at all. Dry-run first, move every conflicting file
    # into a timestamped backup folder, then stow for real.
    local sim backup="$HOME/.dotfiles-backup/$RUN_ID" target moved=0
    sim=$(stow --no --dir="$DOTFILES_DIR" --target="$HOME" --restow . 2>&1)
    while IFS= read -r target; do
        [[ -n $target && ( -e $HOME/$target || -L $HOME/$target ) ]] || continue
        mkdir -p -- "$backup/$(dirname -- "$target")"
        mv -- "$HOME/$target" "$backup/$target"
        log INFO "backed up conflicting ~/$target to $backup/$target"
        printf '  backed up ~/%s\n' "$target" >> "$STEP_LOG"
        moved=$((moved + 1))
    done < <(sed -nE \
        -e 's/.*over existing target (.+) since .*/\1/p' \
        -e 's/.*existing target is [^:]+: (.+)$/\1/p' <<< "$sim")
    if ((moved > 0)); then
        ui_note warn "Moved $moved conflicting file(s) to $(tilde "$backup")"
    fi
    run_cmd stow --dir="$DOTFILES_DIR" --target="$HOME" --restow . || return 2
    ((moved > 0)) && ITEM_NOTE="backed up $moved existing file(s) to $(tilde "$backup")"
    return 0
}
