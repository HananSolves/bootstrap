# shellcheck shell=bash
# lib/thirdparty.sh - apps that don't ship in Fedora's repos. Each app has a
# description and an install function; its repo is only added if the app is
# selected. Repos are written with skip_if_unavailable=1 so one dead or
# blocked repo (e.g. Mullvad's, blocked on some networks) can't break dnf for
# everything else.
#
# To add an app: append its id to THIRDPARTY_APPS, give it a TP_DESC entry,
# and write tp_<id with - replaced by _>.

YUM_REPOS_DIR="${YUM_REPOS_DIR:-/etc/yum.repos.d}"
THIRDPARTY_APPS=(code cursor antigravity mullvad-browser wezterm proton-authenticator)
declare -A TP_DESC=(
    [code]="Visual Studio Code (Microsoft repo)"
    [cursor]="Cursor editor (Cursor repo)"
    [antigravity]="Antigravity IDE (Google repo)"
    [mullvad-browser]="Mullvad Browser (Mullvad repo)"
    [wezterm]="WezTerm nightly (Copr)"
    [proton-authenticator]="Proton Authenticator (direct RPM)"
)
# rpm names to check for "already installed" (defaults to the app id)
declare -A TP_RPM_NAMES=(
    [proton-authenticator]="proton-authenticator ProtonAuthenticator"
)

tp_is_installed() {
    local n
    for n in ${TP_RPM_NAMES[$1]:-$1}; do
        rpm -q --quiet "$n" 2>/dev/null && return 0
    done
    return 1
}

install_thirdparty() {
    local app=$1
    if tp_is_installed "$app"; then
        ITEM_NOTE="already installed"
        return 0
    fi
    "tp_${app//-/_}"
}

# tp_add_repo FILE - install a .repo file read from stdin into $YUM_REPOS_DIR
tp_add_repo() {
    local dest=$YUM_REPOS_DIR/$1 tmp
    if [[ -f $dest ]]; then
        cat > /dev/null
        return 0
    fi
    tmp=$(mktemp) || return 1
    cat > "$tmp"
    tp_install_repo_file "$tmp" "$dest"
}

# tp_add_repo_url FILE URL - download a .repo file and install it
tp_add_repo_url() {
    local dest=$YUM_REPOS_DIR/$1 url=$2 tmp rc=0
    [[ -f $dest ]] && return 0
    tmp="$DOWNLOAD_DIR/$1"
    download "$url" "$tmp" || return
    grep -q '^\[' "$tmp" || { FAIL_REASON="$url did not return a .repo file"; rm -f -- "$tmp"; return 1; }
    tp_install_repo_file "$tmp" "$dest" || rc=$?
    return "$rc"
}

tp_install_repo_file() {
    local src=$1 dest=$2 rc=0
    # make every section non-blocking if its metadata can't be fetched
    grep -q '^skip_if_unavailable' "$src" || sed -i '/^\[/a skip_if_unavailable=1' "$src"
    run_cmd --root install -m 0644 "$src" "$dest" || rc=$?
    rm -f -- "$src"
    return "$rc"
}

tp_code() {
    run_cmd --root rpm --import https://packages.microsoft.com/keys/microsoft.asc || return
    tp_add_repo vscode.repo <<'EOF' || return
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
skip_if_unavailable=1
EOF
    install_dnf code
}

tp_cursor() {
    tp_add_repo cursor.repo <<'EOF' || return
[cursor]
name=Cursor
baseurl=https://downloads.cursor.com/yumrepo
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
    install_dnf cursor
}

tp_antigravity() {
    tp_add_repo antigravity.repo <<'EOF' || return
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
    install_dnf antigravity
}

tp_mullvad_browser() {
    tp_add_repo_url mullvad.repo https://repository.mullvad.net/rpm/stable/mullvad.repo || return
    install_dnf mullvad-browser
}

tp_wezterm() {
    # Same file name `dnf copr enable` would create, without needing the
    # dnf5 copr plugin to be installed.
    local fedora
    fedora=$(rpm -E %fedora)
    tp_add_repo_url "_copr:copr.fedorainfracloud.org:wezfurlong:wezterm-nightly.repo" \
        "https://copr.fedorainfracloud.org/coprs/wezfurlong/wezterm-nightly/repo/fedora-$fedora/wezfurlong-wezterm-nightly-fedora-$fedora.repo" ||
        return
    install_dnf wezterm
}

tp_proton_authenticator() {
    local rpmfile="$DOWNLOAD_DIR/ProtonAuthenticator.rpm" name rc=0
    # A finished download from an earlier interrupted run is reused if it's
    # intact; a partial one (.part) is resumed by download().
    if [[ -f $rpmfile ]] && ! rpm -K --nosignature "$rpmfile" &>/dev/null; then
        rm -f -- "$rpmfile"
    fi
    if [[ ! -f $rpmfile ]]; then
        download https://proton.me/download/authenticator/linux/ProtonAuthenticator.rpm "$rpmfile" || return
        if ! rpm -K --nosignature "$rpmfile" &>/dev/null; then
            rm -f -- "$rpmfile"
            FAIL_REASON="downloaded RPM is corrupt - will re-download"
            return 1
        fi
    fi
    name=$(rpm -qp --qf '%{NAME}' "$rpmfile" 2>/dev/null)
    run_cmd --root dnf install -y "${DNF_OPTS[@]}" "$rpmfile" || rc=$?
    if [[ -n $name ]] && rpm -q --quiet "$name"; then
        rm -f -- "$rpmfile"
        return 0
    fi
    ((rc == 0)) && rc=1
    return "$rc"
}
