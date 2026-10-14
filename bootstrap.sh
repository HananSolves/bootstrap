#!/usr/bin/env bash
# bootstrap.sh
# Run this on a FRESH Fedora (KDE) install. It:
#   1. optionally upgrades the system
#   2. clones your DOTFILES repo and stows it into $HOME
#   3. adds third-party repos and installs apps that aren't in Fedora's repos
#   4. installs your usual packages via dnf, Flatpak and Homebrew, using the
#      package lists that live alongside this script
#
# You pick what to install (everything, or package by package) in a TUI,
# then watch a live dashboard while it runs. Every item is installed and
# verified on its own and retried on failure; if the network drops, the run
# waits for it to come back. Progress is saved as it goes, so an interrupted
# run (Ctrl-C, reboot, lost connection) resumes where it stopped.
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

ALL_PHASES=(upgrade dotfiles thirdparty dnf flatpak brew)
declare -A PHASE_LABELS=(
    [upgrade]="System upgrade (dnf upgrade --refresh)"
    [dotfiles]="Dotfiles - clone and stow into \$HOME"
    [thirdparty]="Third-party apps (VS Code, Cursor, ...)"
    [dnf]="DNF packages (packages-dnf.txt)"
    [flatpak]="Flatpak apps (packages-flatpak.txt)"
    [brew]="Homebrew formulae (Brewfile)"
)
# command -> package providing it, installed before anything else
PREREQS=(whiptail:newt script:util-linux-script stow:stow git:git curl:curl flock:util-linux)

ASSUME_YES=0
FORCE_RESUME=0
FORCE_FRESH=0
NO_TUI=0
ONLY=""
RUN_ACTIVE=0
RESUMING=0
BG_PIDS=()

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Sets up a fresh Fedora install: dotfiles, third-party apps, dnf, Flatpak and
Homebrew packages. Interactive by default - you choose what to install.

Options:
  -y, --yes            Don't ask what to install: install everything listed
                       (or resume an unfinished run). Retry/skip prompts still
                       appear if you press Ctrl-C.
      --only LIST      Only run these phases, comma-separated:
                       ${ALL_PHASES[*]}
      --resume         Resume the previous unfinished run without asking
      --fresh          Ignore any previous run and choose packages again
      --no-tui         Plain scrolling output and y/n prompts, no dialogs
      --retries N      Attempts per item before giving up (default $MAX_ATTEMPTS)
      --net-timeout S  Seconds to wait for a lost connection before asking
                       what to do (default $NET_TIMEOUT)
  -h, --help           Show this help

Logs:  ${LOG_ROOT/#"$HOME"/\~}/latest/
EOF
}

die() {
    printf '%s%s %s%s\n' "$C_RED$C_BOLD" "$SYM_FAIL" "$*" "$C_RESET" >&2
    exit 1
}
say() { printf '%s==>%s %s\n' "$C_BOLD$C_BLUE" "$C_RESET$C_BOLD" "$*$C_RESET"; log INFO "$*"; }

parse_args() {
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            --resume) FORCE_RESUME=1 ;;
            --fresh) FORCE_FRESH=1 ;;
            --no-tui) NO_TUI=1 ;;
            --only) ONLY=${2:-}; shift ;;
            --only=*) ONLY=${1#*=} ;;
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

    say "Fedora Bootstrap - log: $(tilde "$LOG_FILE")"
    if ! sudo -n true 2>/dev/null; then
        ((INTERACTIVE)) || die "sudo needs a password but there is no terminal to ask on."
        printf '   sudo is needed for dnf and repo setup:\n'
    fi
    sudo -v || die "sudo access is required."
    start_background_helpers

    local avail_kb
    avail_kb=$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ -n $avail_kb ]] && ((avail_kb < 5 * 1024 * 1024)); then
        ui_note warn "Only $((avail_kb / 1024)) MB free on / - installs may run out of space."
    fi

    process_item system "Checking prerequisites (whiptail, script, stow, git)" setup_prereqs setup
    command -v whiptail &>/dev/null && HAVE_WHIPTAIL=1
    ((NO_TUI || !INTERACTIVE)) && HAVE_WHIPTAIL=0
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
            text="The previous run ($when) finished, but $((total - done_n)) of $total items did not install.\n\nRetry just those?\n\n  Yes - retry the unfinished items only\n  No  - start over and choose packages again"
        else
            text="A previous run ($when) was interrupted with $done_n of $total items done.\n\nResume it?\n\n  Yes - same selection, finished items are skipped\n  No  - start over and choose packages again"
        fi
        ui_yesno "Resume previous run?" "$(printf '%b' "$text")" yes && RESUMING=1
    fi
    if ((RESUMING)); then
        log INFO "resuming previous plan: $done_n/$total already done"
    fi
}

# select_source PHASE TITLE NAMES_ARRAY STATUS_ASSOC
select_source() {
    local phase=$1 title=$2
    local -a chosen=()
    if ((ASSUME_YES || !INTERACTIVE)); then
        local -n _all=$3
        chosen=("${_all[@]}")
    else
        ui_select_packages chosen "$title" "$3" "$4"
    fi
    local name
    for name in "${chosen[@]}"; do plan_add "$phase" "$name"; done
    log INFO "selected for $phase: ${#chosen[@]} - ${chosen[*]}"
}

build_plan() {
    plan_reset
    local -a phases=()
    if [[ -n $ONLY ]]; then
        read -r -a phases <<< "${ONLY//,/ }"
    elif ((ASSUME_YES || !INTERACTIVE)); then
        phases=(dotfiles thirdparty dnf flatpak brew)
    else
        ui_choose_phases phases \
            "upgrade|${PHASE_LABELS[upgrade]}|OFF" \
            "dotfiles|${PHASE_LABELS[dotfiles]}|ON" \
            "thirdparty|${PHASE_LABELS[thirdparty]}|ON" \
            "dnf|${PHASE_LABELS[dnf]}|ON" \
            "flatpak|${PHASE_LABELS[flatpak]}|ON" \
            "brew|${PHASE_LABELS[brew]}|ON"
    fi
    local p name
    local -a names
    local -A status
    for p in "${ALL_PHASES[@]}"; do
        [[ " ${phases[*]} " == *" $p "* ]] || continue
        names=() status=()
        case $p in
            upgrade) plan_add system upgrade ;;
            dotfiles) plan_add dotfiles repo; plan_add dotfiles stow ;;
            thirdparty)
                names=("${THIRDPARTY_APPS[@]}")
                for name in "${names[@]}"; do
                    status[$name]=${TP_DESC[$name]}
                    tp_is_installed "$name" && status[$name]+="  [installed]"
                done
                select_source thirdparty "Third-party apps" names status ;;
            dnf)
                mapfile -t names < <(read_list "$SCRIPT_DIR/packages-dnf.txt")
                for name in "${names[@]}"; do
                    if [[ $name == @* ]]; then status[$name]="package group"
                    elif rpm -q --quiet "$name" 2>/dev/null; then status[$name]="installed"
                    fi
                done
                select_source dnf "DNF packages" names status ;;
            flatpak)
                mapfile -t names < <(read_list "$SCRIPT_DIR/packages-flatpak.txt")
                if command -v flatpak &>/dev/null; then
                    local installed
                    installed=$(flatpak list --app --user --columns=application 2>/dev/null)
                    for name in "${names[@]}"; do
                        grep -qxF -- "$name" <<< "$installed" && status[$name]="installed"
                    done
                fi
                select_source flatpak "Flatpak apps" names status ;;
            brew)
                mapfile -t names < <(brewfile_entries "$SCRIPT_DIR/Brewfile" brew)
                if brew_load_env; then
                    local installed
                    installed=$(brew list --formula -1 2>/dev/null)
                    for name in "${names[@]}"; do
                        grep -qxF -- "${name##*/}" <<< "$installed" && status[$name]="installed"
                    done
                fi
                select_source brew "Homebrew formulae" names status ;;
        esac
    done
}

confirm_plan() {
    local total src label n text=""
    total=$(plan_count)
    ((total > 0)) || die "Nothing selected - nothing to do."
    for src in system dotfiles thirdparty dnf flatpak brew; do
        n=$(plan_items "$src" | grep -c .)
        ((n > 0)) || continue
        case $src in
            system) label="System upgrade" ;;
            dotfiles) label="Dotfiles (clone + stow)" ;;
            thirdparty) label="Third-party apps" ;;
            dnf) label="DNF packages" ;;
            flatpak) label="Flatpak apps" ;;
            brew) label="Homebrew formulae" ;;
        esac
        printf -v text '%s  %-26s %3d\n' "$text" "$label" "$n"
    done
    ((ASSUME_YES || !INTERACTIVE)) && return 0
    ui_yesno "Ready to start" "$(printf '%s\nTotal: %d items.\n\nEach item is retried up to %d times; if the connection drops the run\nwaits for it. Ctrl-C lets you retry, skip or quit - quitting saves\nprogress so the next run resumes.\n\nLog: %s' \
        "$text" "$total" "$MAX_ATTEMPTS" "$(tilde "$LOG_FILE")")" yes || exit 0
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
    for src in system dotfiles thirdparty dnf flatpak brew; do
        [[ -n $(plan_items "$src") ]] && sources+=("$src")
    done
    TOTAL_ITEMS=$(plan_count)
    RUN_ACTIVE=1
    session_set_status running
    ui_dash_start

    for src in "${sources[@]}"; do
        mapfile -t names < <(plan_items "$src")
        idx=$((idx + 1))
        case $src in
            system)
                ui_phase "$idx" "${#sources[@]}" "System upgrade"
                process_item system upgrade install_system_upgrade
                metadata_done=1 ;;
            dotfiles)
                ui_phase "$idx" "${#sources[@]}" "Dotfiles"
                for name in "${names[@]}"; do
                    case $name in
                        repo) process_item dotfiles repo install_dotfiles_repo ;;
                        stow) process_item dotfiles stow install_dotfiles_stow ;;
                    esac
                done ;;
            thirdparty | dnf)
                if [[ $src == dnf ]]; then
                    ui_phase "$idx" "${#sources[@]}" "DNF packages"
                else
                    ui_phase "$idx" "${#sources[@]}" "Third-party apps"
                fi
                if ((!metadata_done)) && pending "$src" "${names[@]}"; then
                    process_item system "Refreshing dnf metadata" setup_dnf_metadata setup
                    metadata_done=1
                fi
                for name in "${names[@]}"; do
                    if [[ $src == dnf ]]; then
                        process_item dnf "$name" install_dnf
                    else
                        process_item thirdparty "$name" install_thirdparty
                    fi
                done ;;
            flatpak)
                ui_phase "$idx" "${#sources[@]}" "Flatpak apps"
                if pending flatpak "${names[@]}" &&
                    ! process_item flatpak "Setting up Flatpak + Flathub" setup_flatpak setup; then
                    fail_items flatpak "Flatpak/Flathub setup failed" "${names[@]}"
                    continue
                fi
                for name in "${names[@]}"; do
                    process_item flatpak "$name" install_flatpak
                done ;;
            brew)
                ui_phase "$idx" "${#sources[@]}" "Homebrew formulae"
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
    local already failed_lines skipped_lines
    already=$(awk -F'\t' 'NR > 1 && $3 == "OK" && $5 ~ /already installed|previous run/' "$REPORT_FILE" | grep -c .)
    failed_lines=$(awk -F'\t' 'NR > 1 && $3 == "FAIL" { printf "    [%s] %s - %s\n", $1, $2, $5 }' "$REPORT_FILE")
    skipped_lines=$(awk -F'\t' 'NR > 1 && $3 == "SKIP" { printf "    [%s] %s - %s\n", $1, $2, $5 }' "$REPORT_FILE")
    {
        printf '\n%s Bootstrap summary %s\n' "$(repeat "$HR_CHAR" 3)" "$(repeat "$HR_CHAR" 40)"
        printf '  Items: %d   %s %d ok (%d already present)   %s %d failed   %s %d skipped   in %s\n' \
            "$TOTAL_ITEMS" "$SYM_OK" "$COUNT_OK" "$already" "$SYM_FAIL" "$COUNT_FAIL" "$SYM_SKIP" "$COUNT_SKIP" \
            "$(fmt_duration $((SECONDS - RUN_START)))"
        [[ -n $failed_lines ]] && printf '\n  Failed:\n%s\n' "$failed_lines"
        [[ -n $skipped_lines ]] && printf '\n  Skipped:\n%s\n' "$skipped_lines"
        printf '\n  Full log:      %s\n' "$(tilde "$LOG_FILE")"
        printf '  Step logs:     %s/\n' "$(tilde "$STEP_LOG_DIR")"
        printf '  Report (TSV):  %s\n' "$(tilde "$REPORT_FILE")"
        if [[ -n $failed_lines$skipped_lines ]]; then
            printf '\n  Run %s again to retry only what did not finish.\n' "${0##*/}"
        fi
    } | tee "$SUMMARY_FILE" | sed -E \
        -e "s/^(  Items:.*)/$C_BOLD\1$C_RESET/" \
        -e "s/^(  Failed:)/$C_RED$C_BOLD\1$C_RESET/" \
        -e "s/^(  Skipped:)/$C_YELLOW$C_BOLD\1$C_RESET/"
    log INFO "summary: ok=$COUNT_OK fail=$COUNT_FAIL skip=$COUNT_SKIP total=$TOTAL_ITEMS"

    if [[ -x $BREW_PREFIX/bin/brew ]] && ! grep -qs linuxbrew "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; then
        printf '\n  NOTE: add this to your shell rc (in your dotfiles) so brew is on PATH:\n'
        # shellcheck disable=SC2016  # printing the literal line to paste
        printf '    eval "$(%s/bin/brew shellenv)"\n' "$BREW_PREFIX"
    fi
    printf '\nLog out and back in (or reboot) so shell and environment changes fully apply.\n'
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
        build_plan
        confirm_plan
    fi
    run_plan
    print_summary
    ((COUNT_FAIL == 0))
}

main "$@"
