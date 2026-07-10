#!/usr/bin/env bash
# thirdparty-repos.sh
# Adds third-party DNF repos and installs apps that don't ship in Fedora's repos.
#
# NOTE: no `set -e`. One blocked/failed repo or package should not stop the
# rest of this script. Failures are reported as REPORT_FAIL lines so a
# calling script (bootstrap.sh) can fold them into its own summary.
set -uo pipefail

report_ok() {
    echo "    [ok] $1"
    echo "REPORT_OK::$1"
}

report_fail() {
    # $1 = label, $2 = short reason
    echo "    [fail] $1 -- $2"
    echo "REPORT_FAIL::$1::$2"
}

# Run a command, report ok/fail, never exit the script.
run_step() {
    local label="$1"; shift
    local output
    if output="$("$@" 2>&1)"; then
        report_ok "$label"
        return 0
    else
        local err_line
        err_line="$(echo "$output" | tail -n 2 | tr '\n' ' ')"
        report_fail "$label" "${err_line:-unknown error}"
        return 1
    fi
}

echo "==> Adding VS Code repo..."
if [ ! -f /etc/yum.repos.d/vscode.repo ]; then
    if run_step "vscode repo: import key" sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc; then
        if sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
        then
            report_ok "vscode repo: write repo file"
        else
            report_fail "vscode repo: write repo file" "failed to write /etc/yum.repos.d/vscode.repo"
        fi
    fi
else
    report_ok "vscode repo (already present)"
fi

echo "==> Adding Cursor repo..."
if [ ! -f /etc/yum.repos.d/cursor.repo ]; then
    if sudo tee /etc/yum.repos.d/cursor.repo > /dev/null <<'EOF'
[cursor]
name=Cursor
baseurl=https://downloads.cursor.com/yumrepo
enabled=1
gpgcheck=0
EOF
    then
        report_ok "cursor repo: write repo file"
    else
        report_fail "cursor repo: write repo file" "failed to write /etc/yum.repos.d/cursor.repo"
    fi
else
    report_ok "cursor repo (already present)"
fi

echo "==> Adding Mullvad repo..."
if [ ! -f /etc/yum.repos.d/mullvad.repo ]; then
    run_step "mullvad repo" sudo dnf config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
else
    report_ok "mullvad repo (already present)"
fi

echo "==> Adding WezTerm Copr repo..."
if ! dnf copr list 2>/dev/null | grep -q wezfurlong/wezterm-nightly; then
    run_step "wezterm copr repo" sudo dnf copr enable -y wezfurlong/wezterm-nightly
else
    report_ok "wezterm copr repo (already present)"
fi

echo "==> Installing repo-backed packages..."
for pkg in code cursor mullvad-browser wezterm; do
    run_step "package: $pkg" sudo dnf install -y "$pkg"
done

echo "==> Installing Proton Authenticator (no repo available, direct RPM)..."
TMP_RPM="$(mktemp --suffix=.rpm)"
if run_step "proton-authenticator: download" curl -fsSL -o "$TMP_RPM" https://proton.me/download/authenticator/linux/ProtonAuthenticator.rpm; then
    run_step "proton-authenticator: install" sudo dnf install -y "$TMP_RPM"
fi
rm -f "$TMP_RPM"

echo "==> Third-party app install complete."
