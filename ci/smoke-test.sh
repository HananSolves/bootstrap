#!/usr/bin/env bash
# ci/smoke-test.sh - run bootstrap.sh for real in a throwaway Fedora
# container: install a few small packages and remove one, then run again and
# check that the second run changes nothing. Exercises the actual engine -
# prerequisites, plan, batch install, per-item verify, removal, report.
# Runs as root; bootstrap.sh itself runs as an ordinary user with sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

# mirrors occasionally serve a broken metadata file, which dnf then keeps
# in its cache - drop it and try again
retry() { local _; for _ in 1 2 3; do "$@" && return 0; dnf -q clean metadata; sleep 10; done; return 1; }

# sudo, and something for the run to remove
retry dnf -y -q install sudo cowsay
useradd -m tester
echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tester

work=/home/tester/bootstrap
mkdir -p "$work"
cp -r bootstrap.sh lib "$work/"
printf 'tree\njq\n' > "$work/packages-dnf.txt"
printf 'cowsay\nkmahjongg\n' > "$work/packages-remove.txt"   # the second isn't installed
: > "$work/packages-flatpak.txt"
: > "$work/Brewfile"
chown -R tester: "$work"

run() { sudo -u tester -H bash -c "cd $work && ./bootstrap.sh -y --only remove,dnf --no-notify"; }
report() { sudo -u tester -H bash -c 'cat ~/.local/state/bootstrap/logs/latest/report.tsv'; }
fail() { echo "::error::$*"; report; exit 1; }

echo "== first run"
run || fail "first run exited with $?"
rpm -q tree jq || fail "tree/jq not installed"
rpm -q cowsay && fail "cowsay was not removed"
report

echo "== second run: everything should already be done"
run || fail "second run exited with $?"
report | awk -F'\t' '($1 == "remove" || $1 == "dnf") && $5 !~ /^already / { bad = 1; print "not idempotent: " $0 } END { exit bad }' ||
    fail "second run changed something"
report
echo "Smoke test passed."
