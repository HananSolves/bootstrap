# shellcheck shell=bash
# lib/ui.sh - everything the user sees:
#   * the live dashboard: a small header pinned to the top of the terminal
#     (phase, progress bar, counts, current item) with command output
#     scrolling underneath it, and the log path pinned to the bottom row
#   * the selection screens' building blocks - menus, checklists, text
#     input, yes/no - drawn with gum when it's available, and as plain
#     numbered prompts otherwise (or with --no-tui)
#   * one-key inline prompts for retry/skip/quit decisions mid-run
#   * desktop notifications
# Sourced, never executed directly.

shopt -s extglob   # for stripping color codes when measuring text

DASHBOARD=0          # 1 while the pinned-header layout is active
HAVE_GUM=0
NOTIFY=1             # 0 = --no-notify
DASH_TOP=5           # rows reserved for the header
ROWS=24
COLS=80
DASH_STATUS=""       # text of the "current item" header row
PHASE_LABEL=""
PHASE_INDEX=0
PHASE_TOTAL=0
RUN_START=$SECONDS
BUSY_PID=""

ui_init() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_INV=$'\e[7m'
        C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_ACCENT=$'\e[36m'
        UI_COLOR=1
    else
        C_RESET="" C_BOLD="" C_DIM="" C_INV="" C_RED="" C_GREEN="" C_YELLOW="" C_ACCENT=""
        UI_COLOR=0
    fi
    if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then
        SYM_OK="✓" SYM_FAIL="✗" SYM_SKIP="↷" SYM_RUN="›" SYM_WARN="!" SYM_SETUP="•"
        SYM_ON="●" SYM_OFF="○" SYM_BACK="←" SYM_START="→" SYM_ADD="+" SYM_BRAND="◆"
        BAR_FULL="━" BAR_EMPTY="━" HR_CHAR="─"
        SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    else
        SYM_OK="+" SYM_FAIL="x" SYM_SKIP="~" SYM_RUN=">" SYM_WARN="!" SYM_SETUP="*"
        SYM_ON="[x]" SYM_OFF="[ ]" SYM_BACK="<" SYM_START=">" SYM_ADD="+" SYM_BRAND="*"
        BAR_FULL="#" BAR_EMPTY="-" HR_CHAR="-"
        SPIN_FRAMES=('|' '/' '-' '\')
    fi
    command -v gum &>/dev/null && HAVE_GUM=1
    # gum theme: one cyan accent, grey hints, no boxes. Plain ANSI numbers so
    # it also looks right on the 16-color Linux console.
    export GUM_CHOOSE_CURSOR="$SYM_RUN " GUM_CHOOSE_CURSOR_FOREGROUND=6 \
        GUM_CHOOSE_HEADER_FOREGROUND=8 GUM_CHOOSE_ITEM_FOREGROUND="" \
        GUM_CHOOSE_SELECTED_FOREGROUND=6 GUM_CHOOSE_SELECTED_PREFIX="$SYM_ON " \
        GUM_CHOOSE_UNSELECTED_PREFIX="$SYM_OFF " GUM_CHOOSE_CURSOR_PREFIX="$SYM_OFF " \
        GUM_INPUT_PROMPT="$SYM_RUN " GUM_INPUT_PROMPT_FOREGROUND=6 GUM_INPUT_CURSOR_FOREGROUND=6 \
        GUM_INPUT_HEADER_FOREGROUND=8 \
        GUM_CONFIRM_PROMPT_FOREGROUND="" GUM_CONFIRM_SELECTED_BACKGROUND=6 \
        GUM_CONFIRM_SELECTED_FOREGROUND=0 GUM_CONFIRM_UNSELECTED_BACKGROUND="" \
        GUM_CONFIRM_UNSELECTED_FOREGROUND=8
    ui_measure
}

ui_measure() {
    local size
    if size=$( { stty size < /dev/tty; } 2>/dev/null) && [[ $size == *' '* ]]; then
        ROWS=${size% *} COLS=${size#* }
    else
        ROWS=$(tput lines 2>/dev/null || echo 24) COLS=$(tput cols 2>/dev/null || echo 80)
    fi
}

# repeat CHAR COUNT
repeat() {
    local out
    (($2 > 0)) || return 0
    printf -v out '%*s' "$2" ''
    printf '%s' "${out// /$1}"
}

# fit TEXT WIDTH - truncate with an ellipsis so it never wraps
fit() {
    local s=$1 w=$2
    ((${#s} <= w)) && { printf '%s' "$s"; return; }
    ((w > 1)) && printf '%s…' "${s:0:w-1}"
}

# vislen TEXT - length as displayed, i.e. without color codes
vislen() {
    local s=${1//$'\e['*([0-9;])m/}
    printf '%d' "${#s}"
}

tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

# wrap_lines WIDTH - word-wrap stdin; continuation lines are indented past
# the original line's own indent so wrapped list entries stay readable
wrap_lines() {
    awk -v w="$1" '{
        match($0, /^ */); ind = RLENGTH
        if (length($0) <= w) { print; next }
        pad = sprintf("%*s", ind + 4, ""); line = substr($0, 1, ind)
        n = split(substr($0, ind + 1), word, " "); cur = ""
        for (i = 1; i <= n; i++) {
            if (cur != "" && length(line cur " " word[i]) > w) { print line cur; line = pad; cur = word[i] }
            else cur = (cur == "" ? word[i] : cur " " word[i])
        }
        print line cur
    }'
}

# ------------------------------------------------------------ dashboard ----
ui_dash_start() {
    ((DASHBOARD)) || return 0
    ui_measure
    if ((ROWS < 16 || COLS < 50)); then
        DASHBOARD=0   # too small for a pinned header - plain scrolling output
        return 0
    fi
    RUN_START=$SECONDS
    ui_dash_layout
    trap 'ui_measure; ui_dash_layout' WINCH
}

ui_dash_layout() {
    ((DASHBOARD)) || return 0
    # clear, pin the scroll region between the header and the footer row
    printf '\e[2J\e[%d;%dr' $((DASH_TOP + 1)) $((ROWS - 1))
    ui_draw_header
    ui_draw_footer
    printf '\e[%d;1H' $((ROWS - 1))
}

ui_dash_stop() {
    ((DASHBOARD)) || return 0
    DASHBOARD=0
    trap - WINCH
    # drop the scroll region and the pinned footer, continue below the output
    printf '\e[r\e[%d;1H\e[2K' "$ROWS"
}

# (autowrap off while drawing: a long row is clipped, never spills over)
_dash_row() { printf '\e[%d;1H\e[2K\e[?7l%s\e[?7h' "$1" "$2"; }

# the counts row - zero failures/skips stay hidden to keep it quiet
_dash_counts() {
    local fresh=$((COUNT_OK - COUNT_PRESENT - COUNT_REMOVED)) out
    out="${C_GREEN}${SYM_OK} ${fresh} installed${C_RESET}"
    ((COUNT_REMOVED)) && out+="  ${C_GREEN}${SYM_OK} ${COUNT_REMOVED} removed${C_RESET}"
    ((COUNT_PRESENT)) && out+="  ${C_DIM}${SYM_OK} ${COUNT_PRESENT} already done${C_RESET}"
    ((COUNT_FAIL)) && out+="  ${C_RED}${SYM_FAIL} ${COUNT_FAIL} failed${C_RESET}"
    ((COUNT_SKIP)) && out+="  ${C_YELLOW}${SYM_SKIP} ${COUNT_SKIP} skipped${C_RESET}"
    out+="  ${C_DIM}$((TOTAL_ITEMS - ITEMS_PROCESSED)) left${C_RESET}"
    printf '%s' "$out"
}

ui_draw_header() {
    ((DASHBOARD)) || return 0
    local pct=0 barw filled left right pad
    ((TOTAL_ITEMS > 0)) && pct=$((ITEMS_PROCESSED * 100 / TOTAL_ITEMS))
    barw=$((COLS - 22)); ((barw > 60)) && barw=60
    filled=$((barw * pct / 100))

    left=" ${C_ACCENT}${SYM_BRAND}${C_RESET} ${C_BOLD}Fedora Bootstrap${C_RESET}"
    [[ -n $PHASE_LABEL ]] && left+="  ${C_DIM}·${C_RESET}  $(fit "$PHASE_LABEL" $((COLS - 45)))  ${C_DIM}${PHASE_INDEX}/${PHASE_TOTAL}${C_RESET}"
    right="$(fmt_duration $((SECONDS - RUN_START))) "
    pad=$((COLS - $(vislen "$left") - ${#right})); ((pad < 1)) && pad=1

    printf '\e7'
    _dash_row 1 "${left}$(repeat ' ' "$pad")${C_DIM}${right}${C_RESET}"
    _dash_row 2 " ${C_ACCENT}$(repeat "$BAR_FULL" "$filled")${C_RESET}${C_DIM}$(repeat "$BAR_EMPTY" $((barw - filled)))${C_RESET}  ${C_BOLD}${pct}%${C_RESET}  ${C_DIM}${ITEMS_PROCESSED}/${TOTAL_ITEMS}${C_RESET}"
    _dash_row 3 " $(_dash_counts)"
    _dash_row 4 "$DASH_STATUS"
    _dash_row 5 "${C_DIM}$(repeat "$HR_CHAR" "$COLS")${C_RESET}"
    printf '\e8'
}

ui_draw_footer() {
    ((DASHBOARD)) || return 0
    printf '\e7'
    _dash_row "$ROWS" "${C_DIM}$(fit " ctrl-c pause  ·  log $(tilde "$LOG_ROOT")/latest/bootstrap.log" "$COLS")${C_RESET}"
    printf '\e8'
}

# ui_status_line TEXT - transient status (countdowns, prompts). Written to
# stderr so it still reaches the terminal from inside $(...) captures.
ui_status_line() {
    if ((DASHBOARD)); then
        printf '\e7\e[4;1H\e[2K\e[?7l %s\e[?7h\e8' "$1" >&2
    elif ((UI_COLOR)); then
        printf '\r\e[2K%s' "$1" >&2
    fi
}
ui_status_line_clear() {
    if ((DASHBOARD)); then
        printf '\e7\e[4;1H\e[2K\e[?7l%s\e[?7h\e8' "$DASH_STATUS" >&2
    elif ((UI_COLOR)); then
        printf '\r\e[2K' >&2
    fi
}

# ------------------------------------------------------- run-time output ----
# ui_phase INDEX TOTAL LABEL ITEMS
ui_phase() {
    PHASE_INDEX=$1 PHASE_TOTAL=$2 PHASE_LABEL=$3
    log INFO "===== phase $1/$2: $3 ====="
    printf '\n%s%s%s  %s%s%s\n' "$C_BOLD" "$3" "$C_RESET" "$C_DIM" "${4:-0} item$( ((${4:-0} == 1)) || echo s)" "$C_RESET"
    ui_draw_header
}

ui_item_start() {
    local src=$1 name=$2 attempt=$3 kind=$4 tries=""
    ((attempt > 1)) && tries="  ${C_YELLOW}attempt $attempt/$MAX_ATTEMPTS${C_RESET}"
    if [[ $kind == setup ]]; then
        DASH_STATUS=" ${C_DIM}${SYM_SETUP}${C_RESET} $(fit "$name" $((COLS - 30)))${tries}"
        printf '%s%s %s%s%s\n' "$C_DIM" "$SYM_SETUP" "$name" "$C_RESET" "$tries"
    else
        DASH_STATUS=" ${C_ACCENT}${SYM_RUN}${C_RESET} ${C_BOLD}$(fit "$name" $((COLS - 40)))${C_RESET}  ${C_DIM}$((ITEMS_PROCESSED + 1))/$TOTAL_ITEMS${C_RESET}${tries}"
        printf '%s%s%s %s%s%s  %s%d/%d%s%s\n' "$C_ACCENT" "$SYM_RUN" "$C_RESET" "$C_BOLD" "$name" "$C_RESET" \
            "$C_DIM" $((ITEMS_PROCESSED + 1)) "$TOTAL_ITEMS" "$C_RESET" "$tries"
    fi
    ui_draw_header
}

ui_item_done() {
    local src=$1 name=$2 status=$3 secs=$4 detail=$5 took=""
    ((secs > 0)) && took="  ${C_DIM}$(fmt_duration "$secs")${C_RESET}"
    case $status in
        OK) if is_present_note "$detail"; then
                printf '  %s%s %s  %s%s\n' "$C_DIM" "$SYM_OK" "$name" "$detail" "$C_RESET"
            else
                printf '  %s%s%s %s%s%s\n' "$C_GREEN" "$SYM_OK" "$C_RESET" "$name" \
                    "${detail:+  ${C_DIM}$detail${C_RESET}}" "$took"
            fi ;;
        SKIP) printf '  %s%s %s  skipped%s%s\n' "$C_YELLOW" "$SYM_SKIP" "$name" "${detail:+ - $detail}" "$C_RESET" ;;
        FAIL) printf '  %s%s %s%s%s\n' "$C_RED" "$SYM_FAIL" "$name" "${detail:+  $detail}" "$C_RESET" ;;
    esac
    DASH_STATUS=""
    ui_draw_header
}

# ui_note ok|warn|error|info|dim MESSAGE
ui_note() {
    local color sym
    case $1 in
        ok) color=$C_GREEN sym=$SYM_OK ;;
        warn) color=$C_YELLOW sym=$SYM_WARN ;;
        error) color=$C_RED sym=$SYM_FAIL ;;
        dim) color=$C_DIM sym=" " ;;
        *) color=$C_ACCENT sym=$SYM_RUN ;;
    esac
    printf '  %s%s %s%s\n' "$color" "$sym" "$2" "$C_RESET"
    [[ $1 == dim ]] || log "${1^^}" "$2"
}

# ui_countdown SECONDS PRINTF_FORMAT - wait, showing a live countdown. Prints
# the lowercased key the user pressed to cut it short (empty if none).
ui_countdown() {
    local secs=$1 fmt=$2 key="" i
    for ((i = secs; i > 0; i--)); do
        # shellcheck disable=SC2059  # the caller's format string is intended
        ui_status_line "${C_YELLOW}$(printf "$fmt" "$i")${C_RESET}"
        if ((INTERACTIVE)); then
            if read -rsn1 -t 1 key < /dev/tty; then
                [[ -n $key ]] && break
            fi
        else
            sleep 1
        fi
    done
    ui_status_line_clear
    printf '%s' "${key,,}"
}

# ui_prompt_key MESSAGE ALLOWED_KEYS - block until one of ALLOWED_KEYS is
# pressed and print it. Non-interactive runs get the first allowed key.
ui_prompt_key() {
    local msg=$1 allowed=$2 key
    if ((!INTERACTIVE)); then
        printf '%s' "${allowed:0:1}"
        return
    fi
    read -rs -t 0.1 -n 10000 _ < /dev/tty 2>/dev/null   # drop typed-ahead keys
    while :; do
        if ((DASHBOARD)); then
            ui_status_line "${C_INV}${C_YELLOW} ${msg} ${C_RESET}"$'\a'
        else
            printf '\n%s%s%s ' "$C_YELLOW$C_BOLD" "$msg" "$C_RESET" >&2
        fi
        read -rsn1 key < /dev/tty || key=${allowed:0:1}
        key=${key,,}
        [[ -n $key && $allowed == *"$key"* ]] && break
    done
    ((DASHBOARD)) && ui_status_line_clear || printf '%s\n' "$key" >&2
    printf '%s' "$key"
}

# ui_busy_start TEXT / ui_busy_stop - a spinner while something slow runs
# in the foreground (searching repos, checking what's installed)
ui_busy_start() {
    ui_busy_stop
    if ((!UI_COLOR)); then
        printf '%s...\n' "$1" >&2
        return 0
    fi
    (
        trap 'exit 0' TERM
        i=0
        printf '\e[?25l' >&2
        while :; do
            printf '\r\e[2K  %s%s%s %s' "$C_ACCENT" "${SPIN_FRAMES[i++ % ${#SPIN_FRAMES[@]}]}" "$C_RESET" "$1" >&2
            sleep 0.1
        done
    ) 9>&- &
    BUSY_PID=$!
}
ui_busy_stop() {
    [[ -n $BUSY_PID ]] || return 0
    kill "$BUSY_PID" 2>/dev/null
    wait "$BUSY_PID" 2>/dev/null
    BUSY_PID=""
    printf '\r\e[2K\e[?25h' >&2
}

# ------------------------------------------------------ notifications ----
# notify_desktop URGENCY(low|normal|critical) ICON TITLE BODY - a desktop
# notification for when the terminal isn't in front: the run finished, or it
# is waiting for an answer. Also rings the terminal bell, which makes Konsole
# and most other terminals flag the tab. Does nothing without a graphical
# session (SSH, a text console) or with --no-notify.
notify_desktop() {
    ((NOTIFY)) || return 0
    ((INTERACTIVE)) && printf '\a' > /dev/tty 2>/dev/null
    [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} || -S ${XDG_RUNTIME_DIR:-/nonexistent}/bus ]] || return 0
    [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]] || return 0
    if command -v notify-send &>/dev/null; then
        timeout 5 notify-send --app-name="Fedora Bootstrap" --urgency="$1" --icon="$2" -- "$3" "$4" &>/dev/null
    elif command -v gdbus &>/dev/null; then
        timeout 5 gdbus call --session --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify \
            "Fedora Bootstrap" 0 "$2" "$3" "$4" '[]' '{}' -1 &>/dev/null
    fi
    log INFO "notification: $3 - $4"
    return 0
}

# ------------------------------------------------- selection building blocks ----
# These draw with gum when available, else as plain numbered prompts. Every
# one returns 1 when the user backs out (Esc / "b") so callers can go back a
# screen; Ctrl-C quits the whole script.

# ui_screen TITLE [LINE...] - start a new screen: one title line, then text
ui_screen() {
    local title=$1 line; shift
    ui_measure
    ((HAVE_GUM)) && printf '\e[H\e[2J'
    printf '\n  %s%s%s %sFedora Bootstrap%s' "$C_ACCENT" "$SYM_BRAND" "$C_RESET" "$C_BOLD" "$C_RESET"
    [[ -n $title ]] && printf '  %s/%s  %s' "$C_DIM" "$C_RESET" "$title"
    printf '\n\n'
    for line; do printf '  %s\n' "$line"; done
    (($#)) && printf '\n'
}

# _gum_rc RC - map gum's exit code: 0 ok, 1 back; Ctrl-C (130) quits
_gum_rc() {
    (($1 == 130)) && exit 130
    return "$1"
}

# ui_menu OUT HINT [--cursor VALUE] VALUE|LABEL...  - pick one
ui_menu() {
    local -n _menu_out=$1
    local _mn_header=$2 _mn_cursor="" _mn_spec _mn_i _mn_rc=0 _mn_res _mn_a _mn_def=1; shift 2
    if [[ ${1:-} == --cursor ]]; then _mn_cursor=$2; shift 2; fi
    local -a _mn_values=() _mn_labels=()
    for _mn_spec; do _mn_values+=("${_mn_spec%%|*}"); _mn_labels+=("${_mn_spec#*|}"); done

    if ((HAVE_GUM)); then
        local -a _mn_opts=() _mn_sel=()
        for _mn_i in "${!_mn_values[@]}"; do
            _mn_opts+=("${_mn_labels[_mn_i]}"$'\t'"${_mn_values[_mn_i]}")
            [[ ${_mn_values[_mn_i]} == "$_mn_cursor" ]] && _mn_sel=(--selected="${_mn_labels[_mn_i]}")
        done
        _mn_res=$(gum choose --header "$_mn_header" --height $((ROWS - 8)) --label-delimiter=$'\t' \
            "${_mn_sel[@]}" -- "${_mn_opts[@]}") || _mn_rc=$?
        _gum_rc "$_mn_rc" || return 1
        _menu_out=$_mn_res
        return 0
    fi

    for _mn_i in "${!_mn_values[@]}"; do
        printf '  %s%2d%s  %s\n' "$C_ACCENT" $((_mn_i + 1)) "$C_RESET" "${_mn_labels[_mn_i]}"
        [[ ${_mn_values[_mn_i]} == "$_mn_cursor" ]] && _mn_def=$((_mn_i + 1))
    done
    while :; do
        read -rp $'\n'"  Choose 1-${#_mn_values[@]} (Enter = $_mn_def, b = back): " _mn_a < /dev/tty || return 1
        _mn_a=${_mn_a:-$_mn_def}
        [[ ${_mn_a,,} == b* ]] && return 1
        if [[ $_mn_a =~ ^[0-9]+$ ]] && ((_mn_a >= 1 && _mn_a <= ${#_mn_values[@]})); then
            _menu_out=${_mn_values[_mn_a - 1]}
            return 0
        fi
    done
}

# ui_multiselect OUT HINT PRESELECTED_ARRAY VALUE|LABEL...  - pick any
ui_multiselect() {
    local -n _ms_out=$1 _ms_pre=$3
    local _ms_header=$2 _ms_spec _ms_i _ms_rc=0 _ms_res _ms_a _ms_label; shift 3
    local -a _ms_values=() _ms_labels=()
    local -A _ms_on=()
    for _ms_a in "${_ms_pre[@]}"; do _ms_on[$_ms_a]=1; done
    for _ms_spec; do
        _ms_label=${_ms_spec#*|}
        _ms_values+=("${_ms_spec%%|*}")
        # gum's --selected takes a comma-separated list of labels
        [[ -n ${_ms_on[${_ms_spec%%|*}]:-} ]] && _ms_label=${_ms_label//,/;}
        _ms_labels+=("$_ms_label")
    done

    if ((HAVE_GUM)); then
        local -a _ms_opts=() _ms_sel=() _ms_flag=()
        for _ms_i in "${!_ms_values[@]}"; do
            _ms_opts+=("${_ms_labels[_ms_i]}"$'\t'"${_ms_values[_ms_i]}")
            [[ -n ${_ms_on[${_ms_values[_ms_i]}]:-} ]] && _ms_sel+=("${_ms_labels[_ms_i]}")
        done
        ((${#_ms_sel[@]})) && _ms_flag=(--selected="$(IFS=,; printf '%s' "${_ms_sel[*]}")")
        _ms_res=$(gum choose --no-limit --header "$_ms_header" --height $((ROWS - 8)) \
            --label-delimiter=$'\t' "${_ms_flag[@]}" -- "${_ms_opts[@]}") || _ms_rc=$?
        _gum_rc "$_ms_rc" || return 1
        mapfile -t _ms_out < <(grep . <<< "$_ms_res")
        return 0
    fi

    printf '  %sy/n for each · Enter keeps the current choice · b goes back%s\n\n' "$C_DIM" "$C_RESET"
    _ms_out=()
    for _ms_i in "${!_ms_values[@]}"; do
        if [[ -n ${_ms_on[${_ms_values[_ms_i]}]:-} ]]; then
            read -rp "  ${_ms_labels[_ms_i]}  [Y/n/b] " _ms_a < /dev/tty || return 1
            [[ ${_ms_a,,} == b* ]] && return 1
            [[ ${_ms_a,,} == n* ]] || _ms_out+=("${_ms_values[_ms_i]}")
        else
            read -rp "  ${_ms_labels[_ms_i]}  [y/N/b] " _ms_a < /dev/tty || return 1
            [[ ${_ms_a,,} == b* ]] && return 1
            [[ ${_ms_a,,} == y* ]] && _ms_out+=("${_ms_values[_ms_i]}")
        fi
    done
    return 0
}

# ui_input OUT HINT PLACEHOLDER - a line of text; empty input counts as back
ui_input() {
    local -n _in_out=$1
    local rc=0 out
    if ((HAVE_GUM)); then
        out=$(gum input --header "$2" --placeholder "$3") || rc=$?
        _gum_rc "$rc" || return 1
    else
        read -rp "  $3 (empty = back): " out < /dev/tty || return 1
    fi
    out="${out#"${out%%[![:space:]]*}"}"
    out="${out%"${out##*[![:space:]]}"}"
    [[ -n $out ]] || return 1
    _in_out=$out
}

# ui_yesno TITLE TEXT DEFAULT(yes|no) [YES_LABEL NO_LABEL] - returns 0 for yes
ui_yesno() {
    local title=$1 text=$2 def=${3:-yes} yes=${4:-Yes} no=${5:-No} a rc=0
    local -a lines
    mapfile -t lines <<< "$text"
    ui_screen "$title" "${lines[@]}"
    if ((HAVE_GUM)); then
        gum confirm --default="$([[ $def == yes ]] && echo true || echo false)" \
            --affirmative "$yes" --negative "$no" "" || rc=$?
        _gum_rc "$rc"
        return
    fi
    if [[ $def == yes ]]; then
        read -rp "  $yes? [Y/n] " a < /dev/tty
        [[ ${a,,} != n* ]]
    else
        read -rp "  $yes? [y/N] " a < /dev/tty
        [[ ${a,,} == y* ]]
    fi
}

ui_confirm_quit() {
    ui_yesno "Quit" "Nothing has been changed yet." no "Quit" "Keep going" && exit 0
    return 0
}
