# shellcheck shell=bash
# lib/thirdparty.sh - apps that don't ship in Fedora's repos. Each app has a
# description and an install function; its repo is only added if the app is
# selected. Repos are written with skip_if_unavailable=1 so one dead or
# blocked repo (e.g. Mullvad's, blocked on some networks) can't break dnf for
# everything else.
#
# Signatures: every repo here checks package signatures (gpgcheck) and, where
# the vendor signs it, the repo metadata too (repo_gpgcheck). The vendors'
# public keys are committed in keys/ (fingerprints in keys/sources.tsv) and
# installed from there to /etc/pki/rpm-gpg/; every .repo file is written here
# and points at that local copy. Nothing trust-related is downloaded or
# parsed at install time, so a tampered download can't slip in another key
# or switch checking off. ci/check-keys.sh notices when a vendor rotates its
# key; until keys/ is updated, installs from that repo fail with a
# signature error rather than trusting the new key blindly.
#
# To add an app: append its id to THIRDPARTY_APPS, give it a TP_DESC entry,
# and write tp_<id with - replaced by _>.

YUM_REPOS_DIR="${YUM_REPOS_DIR:-/etc/yum.repos.d}"
RPM_KEY_DIR="${RPM_KEY_DIR:-/etc/pki/rpm-gpg}"
PROTON_MANIFEST=https://proton.me/download/authenticator/linux/version.json
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

# tp_install_key NAME - install keys/NAME.asc as $RPM_KEY_DIR/RPM-GPG-KEY-NAME
# and add it to rpm's keyring
tp_install_key() {
    local src="$SCRIPT_DIR/keys/$1.asc" dest="$RPM_KEY_DIR/RPM-GPG-KEY-$1"
    [[ -f $src ]] || { FAIL_REASON="$src is missing - re-clone the repo"; return 2; }
    [[ -f $dest ]] && cmp -s "$src" "$dest" && return 0
    run_cmd --root install -D -m 0644 "$src" "$dest" || return
    run_cmd --root rpm --import "$dest"
}

# tp_add_repo FILE - install a .repo file read from stdin into
# $YUM_REPOS_DIR. A differing existing copy is replaced: these files are
# ours, and an older one may predate signature checking.
tp_add_repo() {
    local dest=$YUM_REPOS_DIR/$1 tmp
    tmp=$(mktemp) || return 1
    cat > "$tmp"
    if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 0
    fi
    [[ -f $dest ]] && log INFO "replacing outdated $dest"
    tp_install_repo_file "$tmp" "$dest"
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
    tp_install_key microsoft || return
    tp_add_repo vscode.repo <<EOF || return
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$RPM_KEY_DIR/RPM-GPG-KEY-microsoft
skip_if_unavailable=1
EOF
    install_dnf code
}

tp_cursor() {
    # packages and repo metadata are both signed with Anysphere's key
    tp_install_key cursor || return
    tp_add_repo cursor.repo <<EOF || return
[cursor]
name=Cursor
baseurl=https://downloads.cursor.com/yumrepo
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$RPM_KEY_DIR/RPM-GPG-KEY-cursor
skip_if_unavailable=1
EOF
    install_dnf cursor
}

tp_antigravity() {
    # Packages are signed with Google's Linux packages key. The repo metadata
    # is signed too (Artifact Registry key), but dnf5 rejects that signature
    # ("Bad PGP signature", though gpg accepts it), so repo_gpgcheck is off
    # here - every package is still signature-checked.
    tp_install_key google || return
    tp_add_repo antigravity.repo <<EOF || return
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://$RPM_KEY_DIR/RPM-GPG-KEY-google
skip_if_unavailable=1
EOF
    install_dnf antigravity
}

tp_mullvad_browser() {
    # packages and repo metadata are both signed with Mullvad's key
    tp_install_key mullvad || return
    tp_add_repo mullvad.repo <<EOF || return
[mullvad-stable]
name=Mullvad VPN
baseurl=https://repository.mullvad.net/rpm/stable/\$basearch
type=rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$RPM_KEY_DIR/RPM-GPG-KEY-mullvad
skip_if_unavailable=1
EOF
    install_dnf mullvad-browser
}

tp_wezterm() {
    # the same repo `dnf copr enable wezfurlong/wezterm-nightly` would add,
    # without needing the dnf copr plugin
    tp_install_key copr-wezterm || return
    tp_add_repo "_copr:copr.fedorainfracloud.org:wezfurlong:wezterm-nightly.repo" <<EOF || return
[copr:copr.fedorainfracloud.org:wezfurlong:wezterm-nightly]
name=Copr repo for wezterm-nightly owned by wezfurlong
baseurl=https://download.copr.fedorainfracloud.org/results/wezfurlong/wezterm-nightly/fedora-\$releasever-\$basearch/
type=rpm-md
enabled=1
enabled_metadata=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://$RPM_KEY_DIR/RPM-GPG-KEY-copr-wezterm
skip_if_unavailable=1
EOF
    install_dnf wezterm
}

# Proton doesn't sign this RPM. The best check available is the SHA-512 that
# Proton's own update manifest lists for each release: the RPM is fetched by
# its versioned URL and refused unless the checksum matches.
tp_proton_authenticator() {
    local manifest="$DOWNLOAD_DIR/proton-authenticator.json" url="" sha="" rpmfile name rc=0
    download "$PROTON_MANIFEST" "$manifest" || return
    { read -r url; read -r sha; } < <(proton_latest_rpm "$manifest")
    rm -f -- "$manifest"
    if [[ ! $url =~ ^https://proton\.me/.+\.rpm$ || ! $sha =~ ^[0-9a-f]{128}$ ]]; then
        FAIL_REASON="could not find the RPM and its checksum in $PROTON_MANIFEST"
        return 1
    fi
    rpmfile="$DOWNLOAD_DIR/${url##*/}"
    # A finished download from an earlier interrupted run is reused if it's
    # intact; a partial one (.part) is resumed by download().
    if [[ -f $rpmfile ]] && ! sha512_ok "$rpmfile" "$sha"; then
        rm -f -- "$rpmfile"
    fi
    if [[ ! -f $rpmfile ]]; then
        download "$url" "$rpmfile" || return
        if ! sha512_ok "$rpmfile" "$sha"; then
            rm -f -- "$rpmfile"
            FAIL_REASON="downloaded RPM doesn't match the SHA-512 in Proton's manifest - will re-download"
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

# proton_latest_rpm MANIFEST - print the newest release's .rpm URL and its
# SHA-512, one per line (releases are listed newest first)
proton_latest_rpm() {
    python3 -I -c '
import json, sys
for rel in json.load(open(sys.argv[1]))["Releases"]:
    for f in rel.get("File", []):
        if f.get("Url", "").endswith(".rpm"):
            print(f["Url"]); print(f.get("Sha512CheckSum", "").lower()); sys.exit()
' "$1" 2>/dev/null
}

sha512_ok() { [[ $(sha512sum < "$1" | cut -d' ' -f1) == "$2" ]]; }
