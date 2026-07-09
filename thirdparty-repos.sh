#!/usr/bin/env bash
# thirdparty-repos.sh
# Adds third-party DNF repos and installs apps that don't ship in Fedora's repos.
set -euo pipefail
echo "==> Adding VS Code repo..."
if [ ! -f /etc/yum.repos.d/vscode.repo ]; then
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
fi
echo "==> Adding Cursor repo..."
if [ ! -f /etc/yum.repos.d/cursor.repo ]; then
    sudo tee /etc/yum.repos.d/cursor.repo > /dev/null <<'EOF'
[cursor]
name=Cursor
baseurl=https://downloads.cursor.com/yumrepo
enabled=1
gpgcheck=0
EOF
fi
echo "==> Adding Mullvad repo..."
if [ ! -f /etc/yum.repos.d/mullvad.repo ]; then
    sudo dnf config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
fi
echo "==> Adding WezTerm Copr repo..."
if ! dnf copr list 2>/dev/null | grep -q wezfurlong/wezterm-nightly; then
    sudo dnf copr enable -y wezfurlong/wezterm-nightly
fi
echo "==> Installing repo-backed packages..."
sudo dnf install -y code cursor mullvad-browser wezterm
echo "==> Installing Proton Authenticator (no repo available, direct RPM)..."
TMP_RPM="$(mktemp --suffix=.rpm)"
curl -fsSL -o "$TMP_RPM" https://proton.me/download/authenticator/linux/ProtonAuthenticator.rpm
sudo dnf install -y "$TMP_RPM"
rm -f "$TMP_RPM"
echo "==> Third-party app install complete."
