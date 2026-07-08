#!/usr/bin/env bash
#
# Run this on your CURRENT, already-configured Fedora system.
# Exports packages YOU explicitly installed from dnf, Flatpak, and Homebrew
#
# Usage:
#   ./export-packages.sh [output-dir]

set -euo pipefail

OUT_DIR="${1:-.}"
mkdir -p "$OUT_DIR"

echo "==> Exporting explicitly-installed dnf/rpm packages..."
dnf repoquery --qf '%{name}\n' --userinstalled | sort -u > "$OUT_DIR/packages-dnf.txt"
echo "    -> $(wc -l < "$OUT_DIR/packages-dnf.txt") packages written to $OUT_DIR/packages-dnf.txt"

if command -v flatpak &>/dev/null; then
    echo "==> Exporting installed Flatpak apps..."
    flatpak list --app --columns=application | sort -u > "$OUT_DIR/packages-flatpak.txt"
    echo "    -> $(wc -l < "$OUT_DIR/packages-flatpak.txt") apps written to $OUT_DIR/packages-flatpak.txt"
else
    echo "==> Flatpak not found, skipping."
fi

if command -v brew &>/dev/null; then
    echo "==> Exporting Homebrew packages (Brewfile)..."
    # --no-flatpak: brew bundle dump includes Flatpak apps by default on
    # Linux, which would just duplicate packages-flatpak.txt above. We
    # handle Flatpak separately, so keep the Brewfile to actual brew
    # formulae/taps only.
    brew bundle dump --force --no-flatpak --file="$OUT_DIR/Brewfile"
    echo "    -> $OUT_DIR/Brewfile"
else
    echo "==> Homebrew not found, skipping."
fi

cat <<EOF

Done. A couple of notes:

1. --userinstalled can include base packages Anaconda marked as
   "user installed" during the original Fedora install. Skim
   packages-dnf.txt and trim anything you don't want reinstalled -
   it's just a text file.

2. Commit the results to your BOOTSTRAP repo:
     cp "$OUT_DIR"/packages-*.txt "$OUT_DIR"/Brewfile ~/bootstrap/ 2>/dev/null
     cd ~/bootstrap
     git add packages-dnf.txt packages-flatpak.txt Brewfile
     git commit -m "Update package list"
     git push
EOF
SCRIPT_EOF
echo written
