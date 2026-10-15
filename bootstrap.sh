#!/usr/bin/env bash
# bootstrap.sh
# Run this on a FRESH Fedora (KDE) install. It:
#   1. removes preinstalled packages you don't want (packages-remove.txt)
#   2. optionally upgrades the system
#   3. clones your DOTFILES repo and stows it into $HOME
#   4. adds third-party repos and installs apps that aren't in Fedora's repos
#   5. installs your usual packages via dnf, Flatpak and Homebrew, using the
#      package lists that live alongside this script
#
# You pick what to do in a TUI - everything, package by package, or extra
# packages found by searching the repos - then watch a live dashboard while
# it runs. Each source's missing packages are installed in one go (parallel
# downloads, one dependency resolution), then every item is verified on its
# own and retried on failure; if the network drops, the run waits for it to
# come back. Progress is saved as it goes, so an interrupted run (Ctrl-C,
# reboot, lost connection) resumes where it stopped. A desktop notification
# says when it's done.
#
# Logs: ~/.local/state/bootstrap/logs/latest/  (bootstrap.log + per-step logs)

# No `set -e`: failures are handled per item - one bad package must never
# abort the rest of the run.
set -uo pipefail

if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    echo "bootstrap.sh must be run from a clone of the repo (it needs lib/ and the package lists)." >&2
    exit 1
fi
[[ -d $SCRIPT_DIR/lib ]] || { echo "missing $SCRIPT_DIR/lib/ - re-clone the repo" >&2; exit 1; }
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/installers.sh
source "$SCRIPT_DIR/lib/installers.sh"
# shellcheck source=lib/thirdparty.sh
source "$SCRIPT_DIR/lib/thirdparty.sh"
# shellcheck source=lib/select.sh
source "$SCRIPT_DIR/lib/select.sh"

ALL_PHASES=(remove upgrade dotfiles thirdparty dnf flatpak brew)
# command -> package providing it, installed before anything else
PREREQS=(gum:gum script:util-linux-script stow:stow git:git curl:curl flock:util-linux
    gpg:gnupg2 python3:python3)

ASSUME_YES=0
FORCE_RESUME=0
FORCE_FRESH=0
NO_TUI=0
ONLY=""
DOWNLOADS=auto
RUN_ACTIVE=0
RESUMING=0
BG_PIDS=()

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Sets up a fresh Fedora install: removes unwanted packages, then installs
dotfiles, third-party apps, dnf, Flatpak and Homebrew packages. Interactive by
default - you choose what to do.

Options:
  -y, --yes            Don't ask: do everything listed (or resume an
                       unfinished run). Retry/skip prompts still appear if
                       you press Ctrl-C.
      --only LIST      Only run these phases, comma-separated:
                       ${ALL_PHASES[*]}
      --resume         Resume the previous unfinished run without asking
      --fresh          Ignore any previous run and choose packages again
      --no-tui         Plain scrolling output and numbered/y-n prompts
      --downloads N    Files downloaded at once by dnf and Homebrew, 1-20
                       (default: dnf 10, Homebrew decides by CPU count).
                       Use 1-3 on a slow or metered connection.
      --no-notify      No desktop notification when the run ends
      --retries N      Attempts per item before giving up (default $MAX_ATTEMPTS)
      --net-timeout S  Seconds to wait for a lost connection before asking
                       what to do (default $NET_TIMEOUT)
  -h, --help           Show this help

Logs:  ${LOG_ROOT/#"$HOME"/\~}/latest/
EOF
}

die() {
    printf '  %s%s %s%s\n' "$C_RED" "$SYM_FAIL" "$*" "$C_RESET" >&2
    exit 1
}

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            --resume) FORCE_RESUME=1 ;;
            --fresh) FORCE_FRESH=1 ;;
            --no-tui) NO_TUI=1 ;;
            --only) ONLY=${2:-}; shift ;;
            --only=*) ONLY=${1#*=} ;;
            --downloads) DOWNLOADS=${2:-}; shift ;;
            --downloads=*) DOWNLOADS=${1#*=} ;;
            --no-notify) NOTIFY=0 ;;
            --retries) MAX_ATTEMPTS=${2:-}; shift ;;
            --retries=*) MAX_ATTEMPTS=${1#*=} ;;
            --net-timeout) NET_TIMEOUT=${2:-}; shift ;;
            --net-timeout=*) NET_TIMEOUT=${1#*=} ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done
    [[ $MAX_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || die "--retries needs a positive number"
    [[ $NET_TIMEOUT =~ ^[0-9]+$ ]] || die "--net-timeout needs a number of seconds"
    if [[ $DOWNLOADS == auto ]]; then
        # dnf's default of 3 leaves most connections idle; Homebrew sizes
        # its own pool from the CPU count
        DNF_OPTS+=(--setopt=max_parallel_downloads=10)
        export HOMEBREW_DOWNLOAD_CONCURRENCY=auto
    elif [[ $DOWNLOADS =~ ^[0-9]+$ ]] && ((DOWNLOADS >= 1 && DOWNLOADS <= 20)); then
        DNF_OPTS+=(--setopt=max_parallel_downloads="$DOWNLOADS")
        export HOMEBREW_DOWNLOAD_CONCURRENCY=$DOWNLOADS
    else
        die "--downloads needs a number from 1 to 20"
    fi
    if [[ -n $ONLY ]]; then
        local p
        for p in ${ONLY//,/ }; do
            [[ " ${ALL_PHASES[*]} " == *" $p "* ]] || die "unknown phase '$p' (valid: ${ALL_PHASES[*]})"
        done
    fi
}

# ---------------------------------------------------------- lifecycle ----
on_exit() {
    local rc=$?
    ui_dash_stop
    ui_busy_stop
    ((UI_COLOR)) && printf '\e[?25h'   # never leave the cursor hidden
    local pid
    for pid in "${BG_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    if ((RUN_ACTIVE)); then
        session_set_status interrupted
        log WARN "run stopped early (exit $rc) - state saved for resume"
        printf '\n%s%s Stopped before finishing.%s Progress is saved: run %s again and it\n' \
            "$C_YELLOW$C_BOLD" "$SYM_WARN" "$C_RESET" "${0##*/}"
        printf '  will offer to resume, skipping everything that already succeeded.\n'
        printf '  Log: %s\n' "$(tilde "$LOG_FILE")"
    fi
    exit "$rc"
}

start_background_helpers() {
    # Keep sudo's cached credentials fresh for the whole run, so a long
    # download never ends in a password prompt nobody is watching.
    # (9>&- : don't let helpers inherit the run lock and outlive us holding it)
    (while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done) 9>&- &
    BG_PIDS+=($!)
    # Stop the machine sleeping mid-install (exits on its own with us).
    if command -v systemd-inhibit &>/dev/null; then
        systemd-inhibit --what=sleep:idle --who=bootstrap --why="Installing packages" \
            --mode=block tail --pid=$$ -f /dev/null &>/dev/null 9>&- &
        BG_PIDS+=($!)
    fi
}

# ------------------------------------------------------------ preflight ----
setup_prereqs() {
    local pair missing=()
    for pair in "${PREREQS[@]}"; do
        command -v "${pair%%:*}" &>/dev/null || missing+=("${pair#*:}")
    done
    if ((${#missing[@]} == 0)); then
        ITEM_NOTE="all present"
        return 0
    fi
    run_cmd --root dnf install -y "${DNF_OPTS[@]}" "${missing[@]}"
}

preflight() {
    ((EUID == 0)) && die "Run this as your normal user, not root - it uses sudo where needed."

    local id="" version_id=""
    # shellcheck source=/dev/null
    [[ -r /etc/os-release ]] && { id=$(. /etc/os-release && echo "${ID:-}"); version_id=$(. /etc/os-release && echo "${VERSION_ID:-}"); }
    log INFO "bootstrap starting: os=$id $version_id user=$(id -un) script_dir=$SCRIPT_DIR args: $*"
    [[ $id == fedora ]] || ui_note warn "This doesn't look like Fedora ($id) - continuing, but expect failures."

    exec 9> "$LOCK_FILE"
    flock -n 9 || die "Another bootstrap run is already in progress."

    printf '\n  %s%s%s %sFedora Bootstrap%s  %slog %s%s\n\n' "$C_ACCENT" "$SYM_BRAND" "$C_RESET" \
        "$C_BOLD" "$C_RESET" "$C_DIM" "$(tilde "$LOG_FILE")" "$C_RESET"
    if ! sudo -n true 2>/dev/null; then
        ((INTERACTIVE)) || die "sudo needs a password but there is no terminal to ask on."
        printf '  sudo is needed for dnf and repo setup.\n'
    fi
    sudo -v || die "sudo access is required."
    start_background_helpers

    local avail_kb
    avail_kb=$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ -n $avail_kb ]] && ((avail_kb < 5 * 1024 * 1024)); then
        ui_note warn "Only $((avail_kb / 1024)) MB free on / - installs may run out of space."
    fi

    process_item system "Checking prerequisites" setup_prereqs setup
    command -v gum &>/dev/null && HAVE_GUM=1
    ((NO_TUI || !INTERACTIVE)) && HAVE_GUM=0
    if ((INTERACTIVE)) && command -v script &>/dev/null; then
        USE_PTY=1
    fi
    ((INTERACTIVE && !NO_TUI && UI_COLOR)) && DASHBOARD=1
}

# -------------------------------------------------------- resume/select ----
decide_resume() {
    RESUMING=0
    [[ -s $PLAN_FILE && -f $SESSION_FILE ]] || return 0
    local status total done_n when
    status=$(session_get status)
    [[ $status == complete ]] && return 0
    if ((FORCE_FRESH)) || { [[ -n $ONLY ]] && ((!FORCE_RESUME)); }; then
        return 0
    fi
    total=$(plan_count)
    done_n=$(done_count)
    when=$(session_get updated)
    if ((FORCE_RESUME || ASSUME_YES || !INTERACTIVE)); then
        RESUMING=1
    else
        local text
        if [[ $status == incomplete ]]; then
            text="The previous run ($when) finished, but $((total - done_n)) of $total items did not install.\n\n  Resume     - retry just the unfinished items\n  Start over - choose packages again"
        else
            text="A previous run ($when) was interrupted with $done_n of $total items done.\n\n  Resume     - same selection, finished items are skipped\n  Start over - choose packages again"
        fi
        ui_yesno "Resume previous run" "$(printf '%b' "$text")" yes "Resume" "Start over" && RESUMING=1
    fi
    if ((RESUMING)); then
        log INFO "resuming previous plan: $done_n/$total already done"
    fi
}

# ---------------------------------------------------------------- run ----
# pending SOURCE NAME... - true if any of the items still needs doing
pending() {
    local src=$1 name; shift
    for name in "$@"; do is_done "$src" "$name" || return 0; done
    return 1
}

run_plan() {
    local -a sources=() names=() taps=()
    local src name idx=0 metadata_done=0 tap
    for src in remove system dotfiles thirdparty dnf flatpak brew; do
        [[ -n $(plan_items "$src") ]] && sources+=("$src")
    done
    TOTAL_ITEMS=$(plan_count)
    RUN_ACTIVE=1
    RUN_START=$SECONDS
    session_set_status running
    ui_dash_start

    for src in "${sources[@]}"; do
        mapfile -t names < <(plan_items "$src")
        idx=$((idx + 1))
        case $src in
            remove)
                ui_phase "$idx" "${#sources[@]}" "Removing packages" "${#names[@]}"
                for name in "${names[@]}"; do
                    process_item remove "$name" install_remove
                done ;;
            system)
                ui_phase "$idx" "${#sources[@]}" "System upgrade" "${#names[@]}"
                process_item system upgrade install_system_upgrade
                metadata_done=1 ;;
            dotfiles)
                ui_phase "$idx" "${#sources[@]}" "Dotfiles" "${#names[@]}"
                for name in "${names[@]}"; do
                    case $name in
                        repo) process_item dotfiles repo install_dotfiles_repo ;;
                        stow) process_item dotfiles stow install_dotfiles_stow ;;
                    esac
                done ;;
            thirdparty | dnf)
                if [[ $src == dnf ]]; then
                    ui_phase "$idx" "${#sources[@]}" "DNF packages" "${#names[@]}"
                else
                    ui_phase "$idx" "${#sources[@]}" "Third-party apps" "${#names[@]}"
                fi
                if ((!metadata_done)) && pending "$src" "${names[@]}"; then
                    process_item system "Refreshing dnf metadata" setup_dnf_metadata setup
                    metadata_done=1
                fi
                [[ $src == dnf ]] && batch_run dnf "${names[@]}"
                for name in "${names[@]}"; do
                    if [[ $src == dnf ]]; then
                        process_item dnf "$name" install_dnf
                    else
                        process_item thirdparty "$name" install_thirdparty
                    fi
                done ;;
            flatpak)
                ui_phase "$idx" "${#sources[@]}" "Flatpak apps" "${#names[@]}"
                if pending flatpak "${names[@]}" &&
                    ! process_item flatpak "Setting up Flatpak + Flathub" setup_flatpak setup; then
                    fail_items flatpak "Flatpak/Flathub setup failed" "${names[@]}"
                    continue
                fi
                batch_run flatpak "${names[@]}"
                for name in "${names[@]}"; do
                    process_item flatpak "$name" install_flatpak
                done ;;
            brew)
                ui_phase "$idx" "${#sources[@]}" "Homebrew formulae" "${#names[@]}"
                if pending brew "${names[@]}"; then
                    if ! process_item brew "Installing Homebrew" setup_homebrew setup; then
                        fail_items brew "Homebrew could not be installed" "${names[@]}"
                        continue
                    fi
                    process_item brew "brew update" setup_brew_update setup
                    mapfile -t taps < <(brewfile_entries "$SCRIPT_DIR/Brewfile" tap)
                    for tap in "${taps[@]}"; do
                        process_item brew "$tap" setup_brew_tap setup
                    done
                    batch_run brew "${names[@]}"
                else
                    brew_load_env
                fi
                for name in "${names[@]}"; do
                    process_item brew "$name" install_brew
                done ;;
        esac
    done

    ui_dash_stop
    RUN_ACTIVE=0
    if ((COUNT_FAIL + COUNT_SKIP == 0)); then
        session_set_status complete
    else
        session_set_status incomplete
    fi
}

print_summary() {
    local failed_lines skipped_lines counts head took fresh=$((COUNT_OK - COUNT_PRESENT - COUNT_REMOVED)) problems w
    problems=$((COUNT_FAIL + COUNT_SKIP))
    took=$(fmt_duration $((SECONDS - RUN_START)))
    failed_lines=$(awk -F'\t' 'NR > 1 && $3 == "FAIL" { printf "  %s (%s): %s\n", $2, $1, $5 }' "$REPORT_FILE")
    skipped_lines=$(awk -F'\t' 'NR > 1 && $3 == "SKIP" { printf "  %s (%s): %s\n", $2, $1, $5 }' "$REPORT_FILE")
    counts="$fresh installed"
    ((COUNT_REMOVED)) && counts+=" · $COUNT_REMOVED removed"
    counts+=" · $COUNT_PRESENT already done"
    ((COUNT_FAIL)) && counts+=" · $COUNT_FAIL failed"
    ((COUNT_SKIP)) && counts+=" · $COUNT_SKIP skipped"
    if ((problems == 0)); then
        head="${C_GREEN}${SYM_OK}${C_RESET} ${C_BOLD}Done in $took${C_RESET}"
    else
        head="${C_YELLOW}${SYM_WARN}${C_RESET} ${C_BOLD}Finished in $took - $problems item$( ((problems == 1)) || echo s) need$( ((problems == 1)) && echo s) attention${C_RESET}"
    fi

    {
        printf 'Bootstrap summary - %s\n\n%s\n' "$took" "$counts"
        [[ -n $failed_lines ]] && printf '\nFailed\n%s\n' "$failed_lines"
        [[ -n $skipped_lines ]] && printf '\nSkipped\n%s\n' "$skipped_lines"
    } > "$SUMMARY_FILE"

    ui_measure
    w=$((COLS - 4)); ((w > 110)) && w=110
    printf '\n  %s\n  %s%s%s\n' "$head" "$C_DIM" "$counts" "$C_RESET"
    if [[ -n $failed_lines ]]; then
        printf '\n  %sFailed%s\n' "$C_RED" "$C_RESET"
        wrap_lines "$w" <<< "$failed_lines" | sed 's/^/  /'
    fi
    if [[ -n $skipped_lines ]]; then
        printf '\n  %sSkipped%s\n' "$C_YELLOW" "$C_RESET"
        wrap_lines "$w" <<< "$skipped_lines" | sed 's/^/  /'
    fi
    printf '\n  %sLogs%s  %s/  %s(bootstrap.log, steps/, report.tsv)%s\n' "$C_DIM" "$C_RESET" "$(tilde "$LOG_DIR")" "$C_DIM" "$C_RESET"
    ((problems)) && printf '  %sRun %s again to retry only what did not finish.%s\n' "$C_DIM" "${0##*/}" "$C_RESET"
    log INFO "summary: ok=$COUNT_OK present=$COUNT_PRESENT removed=$COUNT_REMOVED fail=$COUNT_FAIL skip=$COUNT_SKIP total=$TOTAL_ITEMS"

    if [[ -x $BREW_PREFIX/bin/brew ]] && ! grep -qs linuxbrew "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; then
        printf '\n  %sAdd this to your shell rc (in your dotfiles) so brew is on PATH:%s\n' "$C_YELLOW" "$C_RESET"
        # shellcheck disable=SC2016  # printing the literal line to paste
        printf '    eval "$(%s/bin/brew shellenv)"\n' "$BREW_PREFIX"
    fi
    printf '\n  %sLog out and back in (or reboot) so shell and environment changes apply.%s\n\n' "$C_DIM" "$C_RESET"

    if ((problems == 0)); then
        notify_desktop normal dialog-information "Bootstrap finished" "Done in $took: $counts."
    else
        notify_desktop normal dialog-warning "Bootstrap finished with problems" \
            "$problems item(s) need attention - see the terminal. $counts."
    fi
}

main() {
    ui_init
    parse_args "$@"
    [[ -t 0 && -t 1 ]] && INTERACTIVE=1
    mkdir -p "$STATE_DIR"
    init_dirs
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    preflight "$@"
    decide_resume
    if ((!RESUMING)); then
        choose_plan
        (($(plan_count) > 0)) || die "Nothing selected - nothing to do."
    fi
    run_plan
    print_summary
    ((COUNT_FAIL == 0))
}

main "$@"
