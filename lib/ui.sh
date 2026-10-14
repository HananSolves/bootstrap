# shellcheck shell=bash
# lib/ui.sh - everything the user sees:
#   * the live dashboard: a header pinned to the top of the terminal (phase,
#     progress bar, counts, current item) with command output scrolling
#     underneath it, and the log path pinned to the bottom row
#   * whiptail dialogs to pick what to install, with plain y/n prompts as a
#     fallback when whiptail isn't available (or with --no-tui)
#   * one-key inline prompts for retry/skip/quit decisions mid-run
# Sourced, never executed directly.

DASHBOARD=0          # 1 while the pinned-header layout is active
HAVE_WHIPTAIL=0
DASH_TOP=6           # rows reserved for the header
ROWS=24
COLS=80
DASH_STATUS=""       # text of the "current item" header row
PHASE_LABEL=""
PHASE_INDEX=0
PHASE_TOTAL=0
RUN_START=$SECONDS
WT_BACKTITLE="Fedora Bootstrap"

ui_init() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_INV=$'\e[7m'
        C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
        UI_COLOR=1
    else
        C_RESET="" C_BOLD="" C_DIM="" C_INV="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
        UI_COLOR=0
    fi
    if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then
        SYM_OK="✔" SYM_FAIL="✘" SYM_SKIP="↷" SYM_RUN="▶" SYM_WARN="⚠" SYM_SETUP="⚙"
        BAR_FULL="█" BAR_EMPTY="░" HR_CHAR="─"
    else
        SYM_OK="+" SYM_FAIL="x" SYM_SKIP="~" SYM_RUN=">" SYM_WARN="!" SYM_SETUP="*"
        BAR_FULL="#" BAR_EMPTY="-" HR_CHAR="-"
    fi
    command -v whiptail &>/dev/null && HAVE_WHIPTAIL=1
    export NEWT_COLORS='
root=white,black
roottext=brightcyan,black
border=cyan,black
window=white,black
shadow=,black
title=brightcyan,black
textbox=white,black
label=white,black
button=black,cyan
actbutton=black,brightcyan
compactbutton=white,black
checkbox=white,black
actcheckbox=black,cyan
listbox=white,black
actlistbox=black,cyan
sellistbox=brightcyan,black
actsellistbox=black,brightcyan
emptyscale=,black
fullscale=,cyan
'
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

tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

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

_dash_row() { printf '\e[%d;1H\e[2K%s' "$1" "$2"; }

ui_draw_header() {
    ((DASHBOARD)) || return 0
    local pct=0 barw filled title right phase counts
    ((TOTAL_ITEMS > 0)) && pct=$((ITEMS_PROCESSED * 100 / TOTAL_ITEMS))
    barw=$((COLS - 24)); ((barw > 60)) && barw=60
    filled=$((barw * pct / 100))

    title=" Fedora Bootstrap"
    right="elapsed $(fmt_duration $((SECONDS - RUN_START))) "
    phase=" Phase ${PHASE_INDEX}/${PHASE_TOTAL}  ${PHASE_LABEL}"
    counts="${C_GREEN}${SYM_OK} ${COUNT_OK} done${C_RESET}   ${C_RED}${SYM_FAIL} ${COUNT_FAIL} failed${C_RESET}   ${C_YELLOW}${SYM_SKIP} ${COUNT_SKIP} skipped${C_RESET}   ${C_DIM}$((TOTAL_ITEMS - ITEMS_PROCESSED)) remaining${C_RESET}"

    printf '\e7'
    _dash_row 1 "${C_INV}${C_BOLD}${title}$(repeat ' ' $((COLS - ${#title} - ${#right})))${right}${C_RESET}"
    _dash_row 2 "${C_BOLD}$(fit "$phase" "$COLS")${C_RESET}"
    _dash_row 3 " ${C_CYAN}$(repeat "$BAR_FULL" "$filled")${C_DIM}$(repeat "$BAR_EMPTY" $((barw - filled)))${C_RESET} ${C_BOLD}${ITEMS_PROCESSED}/${TOTAL_ITEMS}${C_RESET} (${pct}%)"
    _dash_row 4 " $counts"
    _dash_row 5 "$DASH_STATUS"
    _dash_row 6 "${C_DIM}$(repeat "$HR_CHAR" "$COLS")${C_RESET}"
    printf '\e8'
}

ui_draw_footer() {
    ((DASHBOARD)) || return 0
    printf '\e7'
    _dash_row "$ROWS" "${C_DIM}$(fit " Log: $(tilde "$LOG_FILE")   |   Ctrl-C: retry / skip / quit & resume later" "$COLS")${C_RESET}"
    printf '\e8'
}

# ui_status_line TEXT - transient status (countdowns, prompts). Written to
# stderr so it still reaches the terminal from inside $(...) captures.
ui_status_line() {
    if ((DASHBOARD)); then
        printf '\e7\e[5;1H\e[2K %s\e8' "$1" >&2
    elif ((UI_COLOR)); then
        printf '\r\e[2K%s' "$1" >&2
    fi
}
ui_status_line_clear() {
    if ((DASHBOARD)); then
        printf '\e7\e[5;1H\e[2K%s\e8' "$DASH_STATUS" >&2
    elif ((UI_COLOR)); then
        printf '\r\e[2K' >&2
    fi
}

# ------------------------------------------------------- run-time output ----
ui_phase() {
    PHASE_INDEX=$1 PHASE_TOTAL=$2 PHASE_LABEL=$3
    log INFO "===== phase $1/$2: $3 ====="
    printf '\n%s%s%s %s %s\n' "$C_BOLD$C_BLUE" "$(repeat "$HR_CHAR" 3)" "" "$3" "$(repeat "$HR_CHAR" $((COLS - ${#3} - 6)))$C_RESET"
    ui_draw_header
}

ui_item_start() {
    local src=$1 name=$2 attempt=$3 kind=$4 counter="" tries=""
    ((attempt > 1)) && tries="  (attempt $attempt/$MAX_ATTEMPTS)"
    if [[ $kind == setup ]]; then
        DASH_STATUS=" ${C_CYAN}${SYM_SETUP}${C_RESET} ${C_BOLD}$(fit "$name" $((COLS - 30)))${C_RESET}${tries}"
        printf '%s%s %s%s%s\n' "$C_CYAN" "$SYM_SETUP" "$name" "$tries" "$C_RESET"
    else
        counter="[$((ITEMS_PROCESSED + 1))/$TOTAL_ITEMS]"
        DASH_STATUS=" ${C_CYAN}${SYM_RUN}${C_RESET} ${C_DIM}${counter} ${src}${C_RESET} ${C_BOLD}$(fit "$name" $((COLS - 40)))${C_RESET}${C_YELLOW}${tries}${C_RESET}"
        printf '%s%s %s %s%s%s%s\n' "$C_BOLD$C_CYAN" "$SYM_RUN" "$counter" "$src:" " $name" "$tries" "$C_RESET"
    fi
    ui_draw_header
}

ui_item_done() {
    local src=$1 name=$2 status=$3 secs=$4 detail=$5 took=""
    ((secs > 0)) && took=" ${C_DIM}($(fmt_duration "$secs"))${C_RESET}"
    case $status in
        OK) printf '  %s%s %s%s%s%s\n' "$C_GREEN" "$SYM_OK" "$name" "$C_RESET" "${detail:+ ${C_DIM}- $detail${C_RESET}}" "$took" ;;
        SKIP) printf '  %s%s %s skipped%s%s\n' "$C_YELLOW" "$SYM_SKIP" "$name" "${detail:+ - $detail}" "$C_RESET" ;;
        FAIL) printf '  %s%s %s failed%s%s%s\n' "$C_RED$C_BOLD" "$SYM_FAIL" "$name" "$C_RESET$C_RED" "${detail:+ - $detail}" "$C_RESET" ;;
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
        *) color=$C_CYAN sym=$SYM_RUN ;;
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

# ------------------------------------------------------- selection (TUI) ----
wt() { whiptail --backtitle "$WT_BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

# wt_dims [CONTENT_ROWS] - dialog size: fit the content, never the screen
wt_dims() {
    ui_measure
    local max=$((ROWS - 4))
    WT_H=$((${1:-24} + 8)); ((WT_H > max)) && WT_H=$max
    WT_W=$((COLS - 8)); ((WT_W > 90)) && WT_W=90
    WT_LIST=$((WT_H - 8)); ((WT_LIST < 3)) && WT_LIST=3
}

ui_confirm_quit() {
    if ((HAVE_WHIPTAIL)); then
        wt --title "Quit?" --yesno "Quit the bootstrap without installing anything?" 8 60 && exit 0
    else
        local a
        read -rp "Quit without installing anything? [y/N] " a < /dev/tty
        [[ ${a,,} == y* ]] && exit 0
    fi
    return 0
}

# ui_yesno TITLE TEXT DEFAULT(yes|no) - returns 0 for yes
ui_yesno() {
    local title=$1 text=$2 def=${3:-yes} a
    if ((HAVE_WHIPTAIL)); then
        local lines
        lines=$(printf '%s\n' "$text" | wc -l)
        wt_dims $((lines - 1))
        local -a extra=()
        [[ $def == no ]] && extra=(--defaultno)
        wt --title "$title" "${extra[@]}" --yesno "$text" "$WT_H" "$WT_W"
        return
    fi
    printf '\n%s%s%s\n%s\n' "$C_BOLD" "$title" "$C_RESET" "$text"
    if [[ $def == yes ]]; then
        read -rp "[Y/n] " a < /dev/tty
        [[ ${a,,} != n* ]]
    else
        read -rp "[y/N] " a < /dev/tty
        [[ ${a,,} == y* ]]
    fi
}

# ui_choose_phases OUT_ARRAY KEY|LABEL|ON/OFF ... - checklist of what to set up
ui_choose_phases() {
    local -n _phases_out=$1; shift
    local -a args=() keys=()
    local spec key label state sel
    for spec in "$@"; do
        IFS='|' read -r key label state <<< "$spec"
        args+=("$key" "$label" "$state")
        keys+=("$key")
    done
    if ((HAVE_WHIPTAIL)); then
        wt_dims $((${#keys[@]} + 1))
        while :; do
            if sel=$(wt --title "What should be set up?" --separate-output --checklist \
                "Space toggles, Enter confirms. Next you'll choose all-or-some packages for each source." \
                "$WT_H" "$WT_W" "$WT_LIST" "${args[@]}"); then
                mapfile -t _phases_out < <(grep . <<< "$sel")
                return 0
            fi
            ui_confirm_quit
        done
    fi
    # plain prompts: one yes/no per phase
    local a i
    _phases_out=()
    printf '\n%sWhat should be set up?%s\n' "$C_BOLD" "$C_RESET"
    for ((i = 0; i < ${#args[@]}; i += 3)); do
        if [[ ${args[i + 2]} == ON ]]; then
            read -rp "  ${args[i + 1]}? [Y/n] " a < /dev/tty
            [[ ${a,,} == n* ]] || _phases_out+=("${args[i]}")
        else
            read -rp "  ${args[i + 1]}? [y/N] " a < /dev/tty
            [[ ${a,,} == y* ]] && _phases_out+=("${args[i]}")
        fi
    done
}

# ui_select_packages OUT_ARRAY TITLE NAMES_ARRAY STATUS_ASSOC
# Asks "all or choose?", and on "choose" shows every package for an
# individual yes/no (a checklist in the TUI, one prompt per package otherwise).
# STATUS_ASSOC maps name -> short note shown next to it ("installed", ...).
ui_select_packages() {
    local -n _sel_out=$1 _sel_names=$3 _sel_status=$4
    local title=$2 n=${#_sel_names[@]} choice sel name a
    _sel_out=()
    ((n == 0)) && return 0
    if ((HAVE_WHIPTAIL)); then
        wt_dims "$n"
        while :; do
            choice=$(wt --title "$title" --notags --menu \
                "$n packages are listed for this source. Install all of them, or pick one by one?" \
                12 "$WT_W" 2 all "Install all $n" pick "Choose individually...") || { ui_confirm_quit; continue; }
            if [[ $choice == all ]]; then
                _sel_out=("${_sel_names[@]}")
                return 0
            fi
            local -a args=()
            for name in "${_sel_names[@]}"; do
                args+=("$name" "${_sel_status[$name]:-}" ON)
            done
            if sel=$(wt --title "$title - choose packages" --separate-output --checklist \
                "Space toggles a package, Enter confirms, Esc goes back." \
                "$WT_H" "$WT_W" "$WT_LIST" "${args[@]}"); then
                mapfile -t _sel_out < <(grep . <<< "$sel")
                return 0
            fi
        done
    fi
    printf '\n%s%s%s (%d)\n' "$C_BOLD" "$title" "$C_RESET" "$n"
    read -rp "  Install [a]ll $n, or [c]hoose one by one? [A/c] " choice < /dev/tty
    if [[ ${choice,,} != c* ]]; then
        _sel_out=("${_sel_names[@]}")
        return 0
    fi
    for name in "${_sel_names[@]}"; do
        read -rp "    $name${_sel_status[$name]:+ (${_sel_status[$name]})}? [Y/n] " a < /dev/tty
        [[ ${a,,} == n* ]] || _sel_out+=("$name")
    done
}
