#!/usr/bin/env bash
# ci/check-keys.sh - check that each vendor still publishes the signing key
# committed in keys/. A vendor that rotates its key makes installs from its
# repo fail with a signature error; this check says so first, and which key
# to update. Each key file must also hold exactly the one pinned key.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

errors=0
home=$(mktemp -d)
trap 'rm -rf -- "$home"' EXIT

# primary_fprs FILE - fingerprints of the primary keys in FILE, one per line
primary_fprs() {
    gpg --homedir "$home" --batch --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
}

while IFS=$'\t' read -r name fpr url; do
    [[ -z $name || $name == \#* ]] && continue
    if [[ $(primary_fprs "keys/$name.asc") != "$fpr" ]]; then
        echo "::error file=keys/$name.asc::keys/$name.asc is not exactly the key $fpr"
        errors=$((errors + 1))
        continue
    fi
    if ! curl -fsSL --retry 3 --max-time 30 -o "$home/$name" "$url"; then
        echo "::error file=keys/sources.tsv::could not download $url"
        errors=$((errors + 1))
        continue
    fi
    if [[ $(primary_fprs "$home/$name") == "$fpr" ]]; then
        echo "  ok  $name  $fpr"
    else
        echo "::error file=keys/sources.tsv::$url now serves $(primary_fprs "$home/$name" | paste -sd ' '), not $fpr - the vendor may have rotated its key: verify the new one from its documentation, then update keys/$name.asc and keys/sources.tsv"
        errors=$((errors + 1))
    fi
done < keys/sources.tsv

((errors == 0)) || exit 1
echo "All vendor keys unchanged."
