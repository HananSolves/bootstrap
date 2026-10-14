# shellcheck shell=bash
# lib/common.sh - shared plumbing for bootstrap.sh: paths, logging, the
# resumable plan/done state, the command runner, retries and network waiting.
# Sourced, never executed directly.

# ---------------------------------------------------------------- paths ----
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bootstrap"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bootstrap"
DOWNLOAD_DIR="$CACHE_DIR/downloads"
LOG_ROOT="$STATE_DIR/logs"
printf -v RUN_ID '%(%Y-%m-%d_%H-%M-%S)T' -1
LOG_DIR="$LOG_ROOT/$RUN_ID"
LOG_FILE="$LOG_DIR/bootstrap.log"
STEP_LOG_DIR="$LOG_DIR/steps"
REPORT_FILE="$LOG_DIR/report.tsv"
SUMMARY_FILE="$LOG_DIR/summary.txt"
# The plan is every item chosen for this run; "done" is every item that has
# succeeded. Both survive across runs - a re-run after an interruption skips
# whatever is already in done.tsv instead of starting over.
PLAN_FILE="$STATE_DIR/plan.tsv"
DONE_FILE="$STATE_DIR/done.tsv"
SESSION_FILE="$STATE_DIR/session"
LOCK_FILE="$STATE_DIR/lock"

# ------------------------------------------------------------- tunables ----
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}        # tries per item before it's marked failed
NET_TIMEOUT=${NET_TIMEOUT:-1800}       # seconds to wait for the network before asking
# dnf: tolerate slow/stalled links instead of aborting a download after 30s
# below 1 KB/s (the defaults). Already-downloaded RPMs stay in dnf's cache
# after a failed transaction, so a retry only fetches what's still missing.
read -r -a DNF_OPTS <<< "${BOOTSTRAP_DNF_OPTS:---setopt=timeout=120 --setopt=minrate=100 --setopt=retries=20}"

# ---------------------------------------------------------- run counters ----
TOTAL_ITEMS=0
ITEMS_PROCESSED=0
COUNT_OK=0
COUNT_FAIL=0
COUNT_SKIP=0
STEP_SEQ=0
STEP_LOG=/dev/null   # per-attempt log of the item currently being processed
ITEM_NOTE=""         # set by an install function to annotate a success
FAIL_REASON=""       # set by an install function to explain a failure
USE_PTY=0            # 1 = run commands under script(1) so progress bars render
INTERACTIVE=0        # 1 = a human is at the terminal and can answer prompts

init_dirs() {
    mkdir -p "$STEP_LOG_DIR" "$DOWNLOAD_DIR" || { echo "cannot create $LOG_DIR" >&2; exit 1; }
    : > "$LOG_FILE"
    printf 'source\tname\tstatus\tseconds\tdetail\n' > "$REPORT_FILE"
    ln -sfn "$RUN_ID" "$LOG_ROOT/latest"
    # keep the 20 most recent run logs
    find "$LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +21 |
        while IFS= read -r old; do rm -rf -- "${LOG_ROOT:?}/$old"; done
}

# -------------------------------------------------------------- logging ----
# log LEVEL MESSAGE... - timestamped line in the main log file only
log() {
    local level=$1; shift
    printf '%(%F %T)T [%-5s] %s\n' -1 "$level" "$*" >> "$LOG_FILE"
}

# clean_output - turn a raw terminal capture (colors, cursor moves, progress
# bars redrawn with \r) into plain text: keep only the final state of each
# redrawn line and drop escape sequences.
clean_output() {
    local esc=$'\e' cr=$'\r' bel=$'\a'
    sed -E \
        -e "s#${esc}\[[0-9;?<>=]*[ -/]*[@-~]##g" \
        -e "s#${esc}\][^${bel}${esc}]*(${bel}|${esc}\\\\)##g" \
        -e "s#${esc}[()][A-Za-z0-9]##g" \
        -e "s#${esc}[=>78DEHMc]##g" \
        -e "s#^.*${cr}([^${cr}])#\1#" \
        -e "s#${cr}+\$##" \
        -e '/^Script (started|done) on /d'
}

# last_error_line LOGFILE - best one-line explanation of a failed step
last_error_line() {
    local cleaned line
    cleaned=$(clean_output < "$1" | sed -E '/^[[:space:]]*$/d; /^\$ /d')
    line=$(grep -iE 'error|fail|no match|unable|cannot|could not|not found|problem|denied|nothing provides|conflict' \
        <<< "$cleaned" | tail -n 1)
    [[ -z $line ]] && line=$(tail -n 1 <<< "$cleaned")
    line="${line#"${line%%[![:space:]]*}"}"
    printf '%s' "${line:0:200}"
}

# ---------------------------------------------------------- session/plan ----
session_set_status() {
    {
        printf 'status=%s\n' "$1"
        printf 'updated=%(%F %T)T\n' -1
        printf 'log_dir=%s\n' "$LOG_DIR"
    } > "$SESSION_FILE"
}
session_get() { sed -n "s/^$1=//p" "$SESSION_FILE" 2>/dev/null; }

plan_reset() { : > "$PLAN_FILE"; : > "$DONE_FILE"; }
plan_add() { printf '%s\t%s\n' "$1" "$2" >> "$PLAN_FILE"; }
# plan_items SOURCE - names planned for SOURCE, in order
plan_items() { awk -F'\t' -v s="$1" '$1 == s { print $2 }' "$PLAN_FILE" 2>/dev/null; }
plan_count() { grep -c . "$PLAN_FILE" 2>/dev/null || true; }
is_done() { grep -qxF -- "$1"$'\t'"$2" "$DONE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" "$2" || printf '%s\t%s\n' "$1" "$2" >> "$DONE_FILE"; }
done_count() {
    # FILENAME test rather than NR == FNR: the latter misfires when done.tsv is empty
    awk -v done_file="$DONE_FILE" 'FILENAME == done_file { d[$0] = 1; next } d[$0]' \
        "$DONE_FILE" "$PLAN_FILE" 2>/dev/null | grep -c . || true
}

# record SOURCE NAME OK|FAIL|SKIP SECONDS DETAIL
record() {
    local detail=${5//$'\t'/ }
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${detail//$'\n'/ }" >> "$REPORT_FILE"
    log INFO "[$1] $2 -> $3${5:+ ($5)}"
}

# ------------------------------------------------------------ run_cmd ----
# run_cmd [--root] CMD [ARGS...]
# Runs one command with its output streamed live to the terminal and appended
# to $STEP_LOG, then copies a cleaned version into the main log.
# With a terminal, the command gets its own pseudo-terminal via script(1):
# piping through tee would make dnf/flatpak/brew/curl detect "not a terminal"
# and hide their progress bars. For root commands sudo wraps script (not the
# other way round) because sudo caches credentials per terminal - a sudo
# inside the new pty would ask for the password again on every package.
run_cmd() {
    local root=0 rc=0 start=$SECONDS cmdstr cmdstr_display
    if [[ $1 == --root ]]; then root=1; shift; fi
    printf -v cmdstr '%q ' "$@"
    cmdstr=${cmdstr% }
    cmdstr_display=$cmdstr
    ((root)) && cmdstr_display="sudo $cmdstr"
    log CMD "\$ $cmdstr_display"
    printf '\n$ %s\n' "$cmdstr_display" >> "$STEP_LOG"
    local -a elevate=()
    ((root)) && elevate=(sudo --)

    if ((USE_PTY)); then
        "${elevate[@]}" env SHELL=/bin/bash script --quiet --return --flush --append \
            --command "$cmdstr" --log-out "$STEP_LOG" || rc=$?
    elif ((INTERACTIVE)); then
        "${elevate[@]}" "$@" 2>&1 | tee -a "$STEP_LOG"
        rc=${PIPESTATUS[0]}
    else
        "${elevate[@]}" "$@" < /dev/null 2>&1 | tee -a "$STEP_LOG"
        rc=${PIPESTATUS[0]}
    fi

    # Copy just this command's output (everything after its "$ cmd" marker)
    # into the main log, indented, so bootstrap.log reads top to bottom.
    awk -v m="\$ $cmdstr_display" '$0 == m { buf = ""; on = 1; next } on { buf = buf $0 "\n" } END { printf "%s", buf }' \
        "$STEP_LOG" | clean_output | sed -E '/^[[:space:]]*$/d; s/^/        | /' >> "$LOG_FILE"
    log CMD "exit $rc after $((SECONDS - start))s"
    return "$rc"
}

# --------------------------------------------------------------- network ----
net_online() {
    # Fedora's own captive-portal check URL, then GitHub as a fallback
    curl -fsS --max-time 6 -o /dev/null http://fedoraproject.org/static/hotspot.txt 2>/dev/null ||
        curl -fsSI --max-time 6 -o /dev/null https://github.com 2>/dev/null
}

# wait_for_network - returns 0 once online, 1 if the user chose to skip.
# Polls with backoff, showing a live status; after NET_TIMEOUT asks what to do
# (non-interactive runs exit instead, keeping state so a re-run resumes).
wait_for_network() {
    net_online && return 0
    log WARN "network unreachable - waiting for it to come back"
    ui_note warn "No internet connection - waiting for it to come back..."
    local waited=0 delay=5 key
    while ! net_online; do
        if ((waited >= NET_TIMEOUT)); then
            log WARN "still offline after ${waited}s"
            if ((!INTERACTIVE)); then
                ui_note error "Still offline after $((waited / 60)) min - stopping. Re-run to resume."
                exit 75
            fi
            key=$(ui_prompt_key "Still offline after $((waited / 60)) min: [w]ait more  [s]kip this item  [q]uit (resume later)" wsq)
            case $key in
                s) return 1 ;;
                q) exit 75 ;;
                *) waited=0 ;;
            esac
        fi
        key=$(ui_countdown "$delay" "Offline for $(fmt_duration "$waited") - checking again in %ds   [s] skip item  [q] quit & resume later")
        case $key in
            s) log INFO "user skipped item while offline"; return 1 ;;
            q) exit 75 ;;
        esac
        waited=$((waited + delay))
        delay=$((delay * 2 > 30 ? 30 : delay * 2))
    done
    log INFO "network back after ${waited}s"
    ui_note ok "Connection restored after $(fmt_duration "$waited") - continuing."
    return 0
}

fmt_duration() {
    local s=$1
    if ((s >= 3600)); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
    elif ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60))
    else printf '%ds' "$s"; fi
}

# ------------------------------------------------------------- downloads ----
# download URL DEST - resumable download with a progress bar.
# Data lands in DEST.part and survives an interrupted run, so the next
# attempt (or the next run) continues from the last byte received.
download() {
    local url=$1 dest=$2 part="$2.part" rc=0
    run_cmd curl --fail --location --continue-at - \
        --connect-timeout 20 --speed-limit 256 --speed-time 90 \
        --progress-bar --output "$part" "$url" || rc=$?
    if ((rc == 0)); then
        mv -f -- "$part" "$dest"
        return 0
    fi
    # 33/36 = server refused to resume, 22 = HTTP error (e.g. 416 on a stale
    # partial) - start the next attempt from scratch
    case $rc in 22 | 33 | 36) rm -f -- "$part" ;; esac
    FAIL_REASON="download failed (curl exit $rc): $url"
    return "$rc"
}

# --------------------------------------------------------- item runner ----
# classify_failure RC SOURCE - after a failed attempt, decide whether it is
# worth retrying. Returns 130 (interrupted), 2 (permanent) or 1 (retryable),
# and fills FAIL_REASON from the step log if it's still empty.
classify_failure() {
    local rc=$1 src=$2
    ((rc == 130)) && return 130
    [[ -z $FAIL_REASON ]] && FAIL_REASON=$(last_error_line "$STEP_LOG")
    [[ -z $FAIL_REASON ]] && FAIL_REASON="exit code $rc"
    local permanent
    case $src in
        dnf | thirdparty | system)
            permanent='No match for argument|Unable to find a match|No match for group|nothing provides|Problem:|conflicts with|is not signed|GPG check FAILED' ;;
        flatpak) permanent='Nothing matches|No remote refs found|not found in remote|Invalid id|No such ref' ;;
        brew) permanent='No available formula|No formulae or casks found|No formulae found|is not a valid' ;;
        dotfiles) permanent='Not possible to fast-forward|would be overwritten|diverged|not a git repository' ;;
        *) permanent='^$' ;;
    esac
    if clean_output < "$STEP_LOG" | grep -qE "$permanent"; then
        return 2
    fi
    return 1
}

# process_item SOURCE NAME FUNC [setup]
# Runs FUNC NAME with retries and records the result. FUNC returns 0 on
# success, 2 for a permanent failure (bad package name...), 130 if the user
# interrupted it, anything else for a retryable failure.
# "setup" items (repo refreshes, installing flatpak/brew themselves) aren't
# counted in the progress bar and are never marked done, since they're cheap
# and idempotent to re-check.
process_item() {
    local src=$1 name=$2 fn=$3 kind=${4:-item} attempt rc start=$SECONDS safe key
    if [[ $kind == item ]] && is_done "$src" "$name"; then
        ITEM_NOTE="done in a previous run"
        finish_item "$src" "$name" OK 0 "$kind"
        return 0
    fi
    safe=${name//[^A-Za-z0-9._@+-]/_}
    for ((attempt = 1; ; attempt++)); do
        ITEM_NOTE="" FAIL_REASON=""
        STEP_SEQ=$((STEP_SEQ + 1))
        STEP_LOG=$(printf '%s/%03d-%s-%s%s.log' "$STEP_LOG_DIR" "$STEP_SEQ" "$src" "$safe" \
            "$( ((attempt > 1)) && printf -- '-try%d' "$attempt")")
        : > "$STEP_LOG"
        ui_item_start "$src" "$name" "$attempt" "$kind"
        log INFO "[$src] $name: attempt $attempt/$MAX_ATTEMPTS (log: ${STEP_LOG#"$LOG_DIR/"})"

        if [[ $src != dotfiles || $name != stow ]] && ! wait_for_network; then
            FAIL_REASON="skipped while offline"
            finish_item "$src" "$name" SKIP $((SECONDS - start)) "$kind"
            return 1
        fi

        rc=0
        "$fn" "$name" || rc=$?
        if ((rc == 0)); then
            [[ $kind == item ]] && mark_done "$src" "$name"
            finish_item "$src" "$name" OK $((SECONDS - start)) "$kind"
            return 0
        fi
        if ((rc != 2 && rc != 130)); then
            classify_failure "$rc" "$src"
            rc=$?
        fi
        log WARN "[$src] $name: attempt $attempt failed (${FAIL_REASON:-exit $rc})"

        if ((rc == 130)); then
            if ((!INTERACTIVE)); then exit 130; fi
            key=$(ui_prompt_key "Interrupted while working on $name: [r]etry  [s]kip it  [q]uit (re-run later to resume)" rsq)
            case $key in
                r) attempt=0; continue ;;
                s) FAIL_REASON="skipped by user"
                   finish_item "$src" "$name" SKIP $((SECONDS - start)) "$kind"
                   return 1 ;;
                *) exit 130 ;;
            esac
        fi
        if ((rc == 2)); then
            ui_note error "$FAIL_REASON"
            ui_note dim "Not retrying - this looks permanent (bad name, dependency problem...)."
            break
        fi
        ((attempt >= MAX_ATTEMPTS)) && break

        ui_note warn "Attempt $attempt/$MAX_ATTEMPTS failed: $FAIL_REASON"
        local backoff=$((attempt * 10))
        key=$(ui_countdown "$backoff" "Retrying $name in %ds   [r] retry now  [s] skip  [q] quit & resume later")
        case $key in
            s) FAIL_REASON="skipped by user"
               finish_item "$src" "$name" SKIP $((SECONDS - start)) "$kind"
               return 1 ;;
            q) exit 130 ;;
        esac
    done
    finish_item "$src" "$name" FAIL $((SECONDS - start)) "$kind"
    return 1
}

finish_item() {
    local src=$1 name=$2 status=$3 secs=$4 kind=$5 detail
    case $status in
        OK) detail=$ITEM_NOTE ;;
        *) detail=$FAIL_REASON ;;
    esac
    record "$src" "$name" "$status" "$secs" "$detail"
    if [[ $kind == item ]]; then
        ITEMS_PROCESSED=$((ITEMS_PROCESSED + 1))
        case $status in
            OK) COUNT_OK=$((COUNT_OK + 1)) ;;
            FAIL) COUNT_FAIL=$((COUNT_FAIL + 1)) ;;
            SKIP) COUNT_SKIP=$((COUNT_SKIP + 1)) ;;
        esac
    fi
    ui_item_done "$src" "$name" "$status" "$secs" "$detail"
}

# fail_items SOURCE REASON NAME... - mark items failed without trying them
# (used when a whole source's setup failed, e.g. Homebrew wouldn't install)
fail_items() {
    local src=$1 reason=$2 name; shift 2
    for name in "$@"; do
        is_done "$src" "$name" && { ITEM_NOTE="done in a previous run"; finish_item "$src" "$name" OK 0 item; continue; }
        FAIL_REASON=$reason
        finish_item "$src" "$name" FAIL 0 item
    done
}
