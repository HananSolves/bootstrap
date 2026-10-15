# shellcheck shell=bash
# lib/installers.sh - one function per kind of item. Each is called by
# process_item with the item name, does a single attempt, and returns
# 0 = installed (or already present; set ITEM_NOTE to say so),
# 2 = permanent failure, anything else = retryable failure.
# Every install is verified afterwards rather than trusting exit codes.
#
# Before a source's per-item loop, batch_run installs everything that's
# missing in ONE dnf/flatpak/brew command: dependencies are resolved once and
# downloads run in parallel. The per-item loop then only verifies (and
# retries one by one whatever the batch didn't manage).

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/HananSolves/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
BREW_PREFIX="${BREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
BREW_INSTALLER_URL=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo
REMOVE_LIST=packages-remove.txt

declare -A BATCHED=()   # "src/name" -> 1 when the batch installed it
BATCH_SRC=""
BATCH_NAMES=()

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

# already_there SRC NAME - the success note for an item found installed:
# none if this run's batch put it there, "already installed" otherwise
already_there() {
    [[ -n ${BATCHED[$1/$2]:-} ]] || ITEM_NOTE="already installed"
    return 0
}

install_dnf() {
    local pkg=$1 rc=0
    if dnf_is_installed "$pkg"; then
        already_there dnf "$pkg"
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
    run_cmd --root dnf makecache "${DNF_OPTS[@]}" && return 0
    # A mirror can serve a broken metadata file, and dnf keeps it cached
    # ("Error loading local metadata") - drop it so the retry starts clean.
    run_cmd --root dnf clean metadata
    return 1
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

# installed for this user or system-wide - either way it's there to use
flatpak_is_installed() { flatpak info "$1" &>/dev/null; }

install_flatpak() {
    local app=$1 rc=0
    if flatpak_is_installed "$app"; then
        already_there flatpak "$app"
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
        already_there brew "$formula"
        return 0
    fi
    # Homebrew keeps partially downloaded bottles (*.incomplete) in its cache
    # and resumes them, so a retry after a dropped connection continues.
    run_cmd brew install "$formula" || rc=$?
    brew_is_installed "$formula" && return 0
    ((rc == 0)) && { FAIL_REASON="brew finished but $formula is not installed"; rc=1; }
    return "$rc"
}

# ----------------------------------------------------------------- batch ----
# batch_run SRC NAME... - install every not-yet-done, not-yet-installed item
# of SRC (dnf/flatpak/brew) in a single command, if there are at least two
batch_run() {
    local src=$1 name; shift
    BATCH_SRC=$src BATCH_NAMES=()
    for name; do
        is_done "$src" "$name" && continue
        [[ $src == dnf && $name == @* ]] && continue   # groups go one by one
        "${src}_is_installed" "$name" && continue
        BATCH_NAMES+=("$name")
    done
    ((${#BATCH_NAMES[@]} >= 2)) || return 0
    process_item "$src" "Installing ${#BATCH_NAMES[@]} packages in one go" batch_install setup
}

# batch_install - the batch step itself. Never fails (other than Ctrl-C):
# whatever didn't make it is simply retried one by one afterwards.
batch_install() {
    local src=$BATCH_SRC name rc=0 ok=0 n=${#BATCH_NAMES[@]}
    case $src in
        # skip-unavailable/broken: one bad name mustn't block the other 20
        dnf) run_cmd --root dnf install -y --skip-unavailable --skip-broken "${DNF_OPTS[@]}" "${BATCH_NAMES[@]}" || rc=$? ;;
        flatpak)
            run_cmd flatpak install -y --user flathub "${BATCH_NAMES[@]}" || rc=$?
            # flatpak refuses the whole batch over one unknown app ID - try
            # once more without the IDs it named
            if ((rc != 0 && rc != 130)); then
                local -a bad=() rest=()
                mapfile -t bad < <(clean_output < "$STEP_LOG" | sed -nE 's/.*Nothing matches ([^ ]+) in remote.*/\1/p')
                for name in "${BATCH_NAMES[@]}"; do
                    [[ " ${bad[*]} " == *" $name "* ]] || rest+=("$name")
                done
                if ((${#bad[@]} && ${#rest[@]} > 1)); then
                    rc=0
                    run_cmd flatpak install -y --user flathub "${rest[@]}" || rc=$?
                fi
            fi ;;
        brew) run_cmd brew install "${BATCH_NAMES[@]}" || rc=$? ;;
    esac
    ((rc == 130)) && return 130
    for name in "${BATCH_NAMES[@]}"; do
        if "${src}_is_installed" "$name"; then
            BATCHED[$src/$name]=1
            ok=$((ok + 1))
        fi
    done
    ITEM_NOTE="$ok of $n installed"
    ((ok < n)) && ITEM_NOTE+=" - trying the other $((n - ok)) one at a time"
    return 0
}

# ---------------------------------------------------------------- remove ----
# Items in packages-remove.txt: a dnf package name, a dnf @group, or
# flatpak:APP.ID for a Flatpak app.

remove_is_installed() {
    local item=$1
    if [[ $item == flatpak:* ]]; then
        command -v flatpak &>/dev/null && flatpak_is_installed "${item#flatpak:}"
    else
        dnf_is_installed "$item"
    fi
}

# on_remove_list NAME - true if NAME is also planned for removal this run
on_remove_list() { plan_items remove | grep -qxF -- "$1"; }

install_remove() {
    local item=$1
    if ! remove_is_installed "$item"; then
        ITEM_NOTE="already removed"
        return 0
    fi
    if [[ $item == flatpak:* ]]; then
        remove_flatpak "${item#flatpak:}"
    else
        remove_dnf "$item"
    fi
}

remove_dnf() {
    local pkg=$1 preview problem dep rc=0
    local -a cmd extra=()
    # Repos aren't needed to remove anything: --disablerepo keeps this fast
    # and offline-proof.
    if [[ $pkg == @* ]]; then
        cmd=(dnf group remove --disablerepo='*' "${pkg#@}")
    else
        cmd=(dnf remove --disablerepo='*' "$pkg")
    fi
    # Preview first. dnf also removes every package that depends on this one,
    # which for a library can be half the desktop - only go ahead if each of
    # those is on the removal list as well. (dnf itself refuses to break
    # "protected" packages like the kernel or plasma-desktop.)
    preview=$("${cmd[@]}" --assumeno 2>&1)
    printf '
$ %s --assumeno
%s
' "${cmd[*]}" "$preview" >> "$STEP_LOG"
    if grep -q 'Failed to resolve' <<< "$preview"; then
        problem=$(grep -m 1 -E 'Problem|protected' <<< "$preview")
        FAIL_REASON="dnf won't remove it: ${problem:-see the log}"
        return 2
    fi
    while IFS= read -r dep; do
        [[ -n $dep ]] && ! on_remove_list "$dep" && extra+=("$dep")
    done < <(awk '/^Removing dependent packages:/ { on = 1; next } /^[^ ]/ { on = 0 } on && NF { print $1 }' <<< "$preview")
    if ((${#extra[@]})); then
        FAIL_REASON="not removed: ${#extra[@]} other package(s) need it (${extra[*]:0:5}$( ((${#extra[@]} > 5)) && echo " ...")) - list them in $REMOVE_LIST too to remove them together"
        return 2
    fi
    run_cmd --root "${cmd[@]}" -y || rc=$?
    dnf_is_installed "$pkg" || return 0
    ((rc == 0)) && { FAIL_REASON="dnf finished but $pkg is still installed"; rc=1; }
    return "$rc"
}

remove_flatpak() {
    local app=$1 rc=0
    # remove it from wherever it's installed: per-user, or system-wide (root)
    if flatpak info --user "$app" &>/dev/null; then
        run_cmd flatpak uninstall -y --user "$app" || rc=$?
    fi
    if flatpak info --system "$app" &>/dev/null; then
        run_cmd --root flatpak uninstall -y --system "$app" || rc=$?
    fi
    flatpak_is_installed "$app" || return 0
    ((rc == 0)) && { FAIL_REASON="flatpak finished but $app is still installed"; rc=1; }
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
