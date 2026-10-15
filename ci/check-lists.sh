#!/usr/bin/env bash
# ci/check-lists.sh - check that every package in the lists still exists:
# dnf names and @groups in Fedora's repos, Flatpak IDs on Flathub, Homebrew
# formulae in Homebrew's index. Catches renamed or dropped packages before a
# real install trips over them. Runs as root in a Fedora container.
# Entries in packages-remove.txt only warn: removing something that no longer
# exists is harmless.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

errors=0

# entries FILE - "LINE<TAB>NAME" for each entry, comments and blanks skipped
entries() {
    [[ -f $1 ]] || return 0
    awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") } $0 != "" { print NR "\t" $0 }' "$1"
}

# report error|warning FILE LINE MESSAGE - a GitHub annotation on that line
report() {
    printf '::%s file=%s,line=%s::%s\n' "$1" "$2" "$3" "$4"
    [[ $1 == error ]] && errors=$((errors + 1))
}

dnf_exists() {
    if [[ $1 == @* ]]; then
        dnf -q group info "${1#@}" &>/dev/null
    else
        [[ -n $(dnf -q repoquery --qf '%{name}\n' "$1" 2>/dev/null) ]] ||
            [[ -n $(dnf -q repoquery --qf '%{name}\n' --whatprovides "$1" 2>/dev/null) ]]
    fi
}

url_ok() { [[ $(curl -sS -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 "$1") == 200 ]]; }

echo "Refreshing dnf metadata..."
for try in 1 2 3; do
    dnf -q makecache >/dev/null && break
    ((try == 3)) && { echo "::error::dnf makecache failed"; exit 1; }
    # mirrors occasionally serve a broken metadata file, and dnf keeps it
    # cached - drop it so the next try downloads afresh
    dnf -q clean metadata; sleep 10
done

echo "== packages-dnf.txt"
while IFS=$'\t' read -r line name; do
    if dnf_exists "$name"; then echo "  ok  $name"
    else report error packages-dnf.txt "$line" "$name is not in Fedora's repos (renamed or dropped?)"; fi
done < <(entries packages-dnf.txt)

echo "== packages-flatpak.txt"
while IFS=$'\t' read -r line name; do
    if url_ok "https://flathub.org/api/v2/appstream/$name"; then echo "  ok  $name"
    else report error packages-flatpak.txt "$line" "$name is not on Flathub"; fi
done < <(entries packages-flatpak.txt)

echo "== Brewfile"
while IFS=$'\t' read -r line name; do
    # formulae from taps ("user/repo/name") aren't in the core index
    [[ $name == */* ]] && { echo "  --  $name (tap formula, not checked)"; continue; }
    if url_ok "https://formulae.brew.sh/api/formula/$name.json"; then echo "  ok  $name"
    else report error Brewfile "$line" "$name is not a Homebrew formula"; fi
done < <(entries Brewfile | sed -nE 's/^([0-9]+)\t[[:space:]]*brew[[:space:]]+["'\'']([^"'\'']+)["'\''].*/\1\t\2/p')

echo "== packages-remove.txt"
while IFS=$'\t' read -r line name; do
    if [[ $name == flatpak:* ]]; then
        url_ok "https://flathub.org/api/v2/appstream/${name#flatpak:}" && { echo "  ok  $name"; continue; }
    elif dnf_exists "$name"; then
        echo "  ok  $name"; continue
    fi
    report warning packages-remove.txt "$line" "$name doesn't exist any more - the entry does nothing"
done < <(entries packages-remove.txt)

if ((errors)); then
    echo "$errors problem(s) found"
    exit 1
fi
echo "All listed packages exist."
