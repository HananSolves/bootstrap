# shellcheck shell=bash
# lib/thirdparty.sh - apps that don't ship in Fedora's repos. Each app has a
# description and an install function; its repo is only added if the app is
# selected. Repos are written with skip_if_unavailable=1 so one dead or
# blocked repo (e.g. Mullvad's, blocked on some networks) can't break dnf for
# everything else.
#
# Signatures: every repo here checks package signatures (gpgcheck) and, where
# the vendor signs it, the repo metadata too (repo_gpgcheck). Vendor keys are
# pinned by fingerprint below: a key is downloaded, refused unless its
# fingerprint matches, and saved to /etc/pki/rpm-gpg/ - the repo files point
# at that local copy, so nothing fetched later can swap the key. If a vendor
# rotates its key, installs fail with a signature error until the new
# fingerprint (from the vendor's docs) is put here.
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

# key_fingerprints FILE - the fingerprint of every primary key in an
# OpenPGP key file, one per line (subkeys aside). Read in a throwaway
# keyring, so nothing touches ~/.gnupg.
key_fingerprints() {
    local home
    home=$(mktemp -d) || return 1
    gpg --homedir "$home" --batch --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
    rm -rf -- "$home"
}

# key_is FILE FINGERPRINT - true if FILE holds exactly one key, and it's
# that one. A file with the right key plus an extra one must fail: rpm
# --import would trust every key in it.
key_is() { [[ $(key_fingerprints "$1") == "$2" ]]; }

# tp_install_key NAME URL FINGERPRINT - download a vendor's signing key,
# refuse it unless its fingerprint is the pinned one, then save it as
# $RPM_KEY_DIR/RPM-GPG-KEY-NAME and add it to rpm's keyring
tp_install_key() {
    local url=$2 want=$3 file="$DOWNLOAD_DIR/RPM-GPG-KEY-$1" dest="$RPM_KEY_DIR/RPM-GPG-KEY-$1" got
    if [[ -f $dest ]] && key_is "$dest" "$want"; then
        return 0
    fi
    download "$url" "$file" || return
    if ! key_is "$file" "$want"; then
        got=$(key_fingerprints "$file" | paste -sd ' ')
        rm -f -- "$file"
        FAIL_REASON="signing key at $url is ${got:-unreadable}, expected only $want - refusing it"
        return 2
    fi
    run_cmd --root install -D -m 0644 "$file" "$dest" || return
    rm -f -- "$file"
    # check the root-owned copy too: the download sits in a user-writable
    # folder and could have been swapped between the check and the copy
    if ! key_is "$dest" "$want"; then
        run_cmd --root rm -f -- "$dest"
        FAIL_REASON="$dest changed while being installed - refusing it"
        return 2
    fi
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

# tp_add_repo_url FILE URL - download a .repo file and install it
tp_add_repo_url() {
    local dest=$YUM_REPOS_DIR/$1 url=$2 tmp rc=0
    [[ -f $dest ]] && return 0
    tmp="$DOWNLOAD_DIR/$1"
    download "$url" "$tmp" || return
    grep -q '^\[' "$tmp" || { FAIL_REASON="$url did not return a .repo file"; rm -f -- "$tmp"; return 1; }
    # every section must check package signatures - refuse a file that
    # turns that off (or never turns it on)
    if ! awk '/^\[/ { if (sec && !ok) bad = 1; sec = 1; ok = 0 }
              /^[[:space:]]*gpgcheck[[:space:]]*=[[:space:]]*1[[:space:]]*$/ { ok = 1 }
              /^[[:space:]]*gpgcheck[[:space:]]*=[[:space:]]*0/ { bad = 1 }
              END { exit !(sec && ok && !bad) }' "$tmp"; then
        rm -f -- "$tmp"
        FAIL_REASON="$url doesn't enable gpgcheck=1 in every section - refusing it"
        return 2
    fi
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
    tp_install_key microsoft https://packages.microsoft.com/keys/microsoft.asc \
        BC528686B50D79E339D3721CEB3E94ADBE1229CF || return
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
    tp_install_key cursor https://downloads.cursor.com/keys/anysphere.asc \
        380FF4BCDC34A4BD92A3565342A1772E62E492D6 || return
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
    # packages are signed with Google's Linux packages key, the repo
    # metadata with Artifact Registry's repository key
    tp_install_key google https://dl.google.com/linux/linux_signing_key.pub \
        EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796 || return
    tp_install_key artifact-registry https://us-central1-yum.pkg.dev/doc/repo-signing-key.gpg \
        35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3 || return
    tp_add_repo antigravity.repo <<EOF || return
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$RPM_KEY_DIR/RPM-GPG-KEY-google file://$RPM_KEY_DIR/RPM-GPG-KEY-artifact-registry
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
