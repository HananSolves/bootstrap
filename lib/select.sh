# shellcheck shell=bash
# lib/select.sh - choosing what to do.
#
# A main menu lists every phase and package source with its current
# selection. Any of them can be opened, changed and re-opened, in any order,
# until "Start" is picked - nothing changes on the system before that.
# Each source can be taken in full, narrowed down package by package, or
# extended with packages found by searching Fedora's repos, Flathub or
# Homebrew (or, for removals, the installed packages). What's already in the
# wanted state - installed, or for removals already gone - is detected up
# front and marked on every screen that lists it.
# Sourced, never executed directly.

PKG_SOURCES=(remove thirdparty dnf flatpak brew)
declare -A SRC_TITLE=(
    [remove]="Remove packages" [thirdparty]="Third-party apps" [dnf]="DNF packages"
    [flatpak]="Flatpak apps" [brew]="Homebrew"
)
declare -A SRC_FILE=([remove]=$REMOVE_LIST [dnf]=packages-dnf.txt [flatpak]=packages-flatpak.txt [brew]=Brewfile)
SEARCH_LIMIT=150

declare -A PHASE_ON=()   # upgrade / dotfiles -> 1 when they will run
declare -A PICKED=()     # "src/name" -> 1 when selected
declare -A SATISFIED=()  # "src/name" -> 1 when nothing needs doing: already
                         #   installed, or (for removals) already not installed
declare -A NOTE=()       # "src/name" -> description shown next to the name
declare -A ADDED=()      # "src/name" -> 1 when added through search
NAMES_remove=() NAMES_thirdparty=() NAMES_dnf=() NAMES_flatpak=() NAMES_brew=()
SEL_PHASES=()            # phases offered in this run (all, or --only)
SEL_FLASH=""             # one-off message for the next screen ("Added 2 ...")
FLATHUB_READY=0

# ------------------------------------------------------------- state ----
sel_offered() { [[ " ${SEL_PHASES[*]} " == *" $1 "* ]]; }
is_picked() { [[ ${PICKED[$1/$2]:-0} == 1 ]]; }

# sel_names OUT SRC - copy SRC's candidate names into the array OUT
sel_names() {
    local -n _sn_out=$1 _sn_src=NAMES_$2
    _sn_out=("${_sn_src[@]}")
}

# sel_load PHASE... - read the package lists; everything listed starts selected
sel_load() {
    SEL_PHASES=("$@")
    NAMES_thirdparty=("${THIRDPARTY_APPS[@]}")
    mapfile -t NAMES_remove < <(read_list "$SCRIPT_DIR/$REMOVE_LIST")
    mapfile -t NAMES_dnf < <(read_list "$SCRIPT_DIR/packages-dnf.txt")
    mapfile -t NAMES_flatpak < <(read_list "$SCRIPT_DIR/packages-flatpak.txt")
    mapfile -t NAMES_brew < <(brewfile_entries "$SCRIPT_DIR/Brewfile" brew)
    local name src
    for name in "${THIRDPARTY_APPS[@]}"; do NOTE[thirdparty/$name]=${TP_DESC[$name]}; done
    for name in "${NAMES_dnf[@]}" "${NAMES_remove[@]}"; do
        [[ $name == @* ]] && NOTE[dnf/$name]="group" NOTE[remove/$name]="group"
    done
    for name in "${NAMES_remove[@]}"; do
        [[ $name == flatpak:* ]] && NOTE[remove/$name]="Flatpak app"
    done
    PHASE_ON[upgrade]=0
    PHASE_ON[dotfiles]=1
    for src in "${PKG_SOURCES[@]}"; do sel_set "$src" all; done
}

# sel_set SRC all|missing|none
sel_set() {
    local src=$1 how=$2 name
    local -a names
    sel_names names "$src"
    for name in "${names[@]}"; do
        case $how in
            all) PICKED[$src/$name]=1 ;;
            none) PICKED[$src/$name]=0 ;;
            missing) PICKED[$src/$name]=$([[ -n ${SATISFIED[$src/$name]:-} ]] && echo 0 || echo 1) ;;
        esac
    done
}

# sel_add SRC NAME - add a search result to SRC's candidates, selected
sel_add() {
    local -n _sa_names=NAMES_$1
    [[ " ${_sa_names[*]} " == *" $2 "* ]] || _sa_names+=("$2")
    ADDED[$1/$2]=1
    PICKED[$1/$2]=1
}

# sel_stats SRC - sets S_TOTAL, S_PICKED, S_HAVE (nothing to do), S_ADDED
# and S_TODO (selected and still to do)
sel_stats() {
    local src=$1 name key
    local -a names
    sel_names names "$src"
    S_TOTAL=${#names[@]} S_PICKED=0 S_HAVE=0 S_ADDED=0 S_TODO=0
    for name in "${names[@]}"; do
        key=$src/$name
        [[ -n ${SATISFIED[$key]:-} ]] && S_HAVE=$((S_HAVE + 1))
        [[ -n ${ADDED[$key]:-} ]] && S_ADDED=$((S_ADDED + 1))
        if is_picked "$src" "$name"; then
            S_PICKED=$((S_PICKED + 1))
            [[ -n ${SATISFIED[$key]:-} ]] || S_TODO=$((S_TODO + 1))
        fi
    done
}

# sel_plan_stats - T_ITEMS, T_TODO, T_HAVE over everything selected
sel_plan_stats() {
    local src
    T_ITEMS=0 T_TODO=0 T_HAVE=0
    if sel_offered upgrade && ((PHASE_ON[upgrade])); then T_ITEMS=$((T_ITEMS + 1)) T_TODO=$((T_TODO + 1)); fi
    if sel_offered dotfiles && ((PHASE_ON[dotfiles])); then T_ITEMS=$((T_ITEMS + 2)) T_TODO=$((T_TODO + 2)); fi
    for src in "${PKG_SOURCES[@]}"; do
        sel_offered "$src" || continue
        sel_stats "$src"
        T_ITEMS=$((T_ITEMS + S_PICKED)) T_TODO=$((T_TODO + S_TODO)) T_HAVE=$((T_HAVE + S_PICKED - S_TODO))
    done
}

# ------------------------------------------------- what's installed ----
sel_scan_installed() {
    local name
    if sel_offered thirdparty; then
        for name in "${NAMES_thirdparty[@]}"; do
            tp_is_installed "$name" && SATISFIED[thirdparty/$name]=1
        done
    fi
    sel_offered remove && sel_mark_remove "${NAMES_remove[@]}"
    sel_offered dnf && sel_mark_dnf "${NAMES_dnf[@]}"
    sel_offered flatpak && sel_mark_flatpak "${NAMES_flatpak[@]}"
    sel_offered brew && sel_mark_brew "${NAMES_brew[@]}"
    return 0
}

# rpm_installed NAME... - print the names (packages or @groups) that are
# installed, with a single rpm call for all the plain package names
rpm_installed() {
    local name
    local -a pkgs=()
    local -A found=()
    for name; do
        if [[ $name == @* ]]; then
            # cache-only: don't stall on a metadata download just to label a group
            dnf -q -C group info "${name#@}" < /dev/null 2>/dev/null |
                grep -qE '^Installed[[:space:]]*:[[:space:]]*yes' && printf '%s\n' "$name"
        else
            pkgs+=("$name")
        fi
    done
    ((${#pkgs[@]})) || return 0
    # "package X is not installed" lines have spaces; names never do
    while IFS= read -r name; do found[$name]=1; done < <(rpm -q --qf '%{NAME}\n' -- "${pkgs[@]}" 2>/dev/null | grep -v ' ')
    for name in "${pkgs[@]}"; do
        if [[ -n ${found[$name]:-} ]] || rpm -q --quiet --whatprovides "$name" 2>/dev/null; then
            printf '%s\n' "$name"
        fi
    done
}

sel_mark_dnf() {
    local name
    while IFS= read -r name; do SATISFIED[dnf/$name]=1; done < <(rpm_installed "$@")
}

sel_mark_flatpak() {
    command -v flatpak &>/dev/null || return 0
    local list name
    list=$(flatpak list --app --columns=application 2>/dev/null)
    for name; do
        grep -qxF -- "$name" <<< "$list" && SATISFIED[flatpak/$name]=1
    done
    return 0
}

sel_mark_brew() {
    brew_load_env || return 0
    local list name
    list=$(brew list --formula -1 2>/dev/null)
    for name; do
        grep -qxF -- "${name##*/}" <<< "$list" && SATISFIED[brew/$name]=1
    done
    return 0
}

# removals are satisfied when the package is NOT installed
sel_mark_remove() {
    local name list=""
    local -a pkgs=()
    local -A present=()
    for name; do [[ $name == flatpak:* ]] || pkgs+=("$name"); done
    while IFS= read -r name; do present[$name]=1; done < <(rpm_installed "${pkgs[@]}")
    command -v flatpak &>/dev/null && list=$(flatpak list --app --columns=application 2>/dev/null)
    for name; do
        if [[ $name == flatpak:* ]]; then
            grep -qxF -- "${name#flatpak:}" <<< "$list" && present[$name]=1
        fi
        [[ -n ${present[$name]:-} ]] || SATISFIED[remove/$name]=1
    done
    return 0
}

# ------------------------------------------------------------ labels ----
# sel_item_label SRC NAME WIDTH - "name     installed · description"
sel_item_label() {
    local src=$1 name=$2 key=$1/$2 status=""
    if [[ $src == remove ]]; then
        [[ -n ${SATISFIED[$key]:-} ]] && status="not installed" || status="installed"
    else
        [[ -n ${SATISFIED[$key]:-} ]] && status="installed"
    fi
    [[ -n ${ADDED[$key]:-} ]] && status+="${status:+ · }added"
    [[ -n ${NOTE[$key]:-} ]] && status+="${status:+ · }${NOTE[$key]}"
    printf '%-*s  %s' "$3" "$(fit "$name" "$3")" "$(fit "$status" $((COLS - $3 - 12)))"
}

# sel_label_width NAME... - name column width for a list of names
sel_label_width() {
    local name w=12
    for name; do ((${#name} > w)) && w=${#name}; done
    ((w > 36)) && w=36
    printf '%d' "$w"
}

sel_hub_label() {
    local p=$1 on title detail
    case $p in
        upgrade)
            title="System upgrade" on=${PHASE_ON[upgrade]}
            detail="dnf upgrade --refresh" ;;
        dotfiles)
            title="Dotfiles" on=${PHASE_ON[dotfiles]}
            if [[ -d $DOTFILES_DIR/.git ]]; then detail="pull + restow"; else detail="clone + stow"; fi ;;
        *)
            title=${SRC_TITLE[$p]}
            sel_stats "$p"
            on=$((S_PICKED > 0))
            if ((S_TOTAL == 0)); then detail="empty - open to search"
            elif ((S_PICKED == 0)); then detail="nothing selected"
            elif [[ $p == remove ]]; then
                detail="$S_TODO to remove"
                ((S_PICKED > S_TODO)) && detail+=" · $((S_PICKED - S_TODO)) already gone"
            else
                detail="$S_TODO to install"
                ((S_PICKED > S_TODO)) && detail+=" · $((S_PICKED - S_TODO)) installed"
            fi
            ((S_ADDED > 0)) && detail+=" · $S_ADDED added" ;;
    esac
    [[ $p == upgrade || $p == dotfiles ]] && ((!on)) && detail="off"
    printf '%s %-18s %s' "$( ((on)) && echo "$SYM_ON" || echo "$SYM_OFF")" "$title" "$(fit "$detail" $((COLS - 32)))"
}

# ------------------------------------------------------------- screens ----
# take the pending flash message as an extra screen line
_flash_lines() {
    local -n _fl=$1
    [[ -n $SEL_FLASH ]] && _fl+=("" "$SEL_FLASH")
    SEL_FLASH=""
}

sel_hub() {
    local choice cursor="" p start
    while :; do
        local -a items=() lines=()
        for p in "${ALL_PHASES[@]}"; do
            sel_offered "$p" && items+=("$p|$(sel_hub_label "$p")")
        done
        sel_plan_stats
        start="$T_TODO to do"
        ((T_HAVE > 0)) && start+=" · $T_HAVE already done"
        ((T_ITEMS == 0)) && start="nothing selected"
        items+=("start|$SYM_START $(printf '%-18s %s' Start "$start")")
        lines=("${C_DIM}Pick what to set up. Nothing changes until you start.${C_RESET}")
        _flash_lines lines
        ui_screen "" "${lines[@]}"
        if ! ui_menu choice "esc quit" --cursor "$cursor" "${items[@]}"; then
            ui_confirm_quit
            continue
        fi
        cursor=$choice
        case $choice in
            upgrade | dotfiles) PHASE_ON[$choice]=$((1 - PHASE_ON[$choice])) ;;
            start)
                if ((T_ITEMS == 0)); then
                    SEL_FLASH="${C_YELLOW}Nothing is selected yet.${C_RESET}"
                    continue
                fi
                sel_review && return 0 ;;
            *) sel_source_menu "$choice" ;;
        esac
    done
}

sel_search_where() {
    case $1 in
        remove) printf 'installed packages' ;;
        dnf) printf "Fedora's repos" ;;
        flatpak) printf 'Flathub' ;;
        brew) printf 'Homebrew' ;;
    esac
}

sel_source_menu() {
    local src=$1 choice cursor=pick title=${SRC_TITLE[$1]} info
    while :; do
        local -a lines=() items=()
        sel_stats "$src"
        info="$((S_TOTAL - S_ADDED)) in ${SRC_FILE[$src]:-lib/thirdparty.sh}"
        if [[ $src == remove ]]; then
            info+=" · $((S_TOTAL - S_HAVE)) installed"
        else
            info+=" · $S_HAVE installed"
        fi
        ((S_ADDED)) && info+=" · $S_ADDED added"
        info+=" · ${C_BOLD}$S_PICKED selected${C_RESET}"
        lines=("$info")
        case $src in
            brew) brew_load_env || lines+=("${C_DIM}Homebrew itself gets installed first.${C_RESET}") ;;
            flatpak) command -v flatpak &>/dev/null || lines+=("${C_DIM}Flatpak itself gets installed first.${C_RESET}") ;;
            remove) lines+=("${C_DIM}A package that other installed packages still need is left alone,${C_RESET}"
                "${C_DIM}unless those are selected for removal too.${C_RESET}") ;;
        esac
        _flash_lines lines

        ((S_TOTAL > 0)) && items+=("pick|Pick packages")
        [[ $src != thirdparty ]] && items+=("search|Search $(sel_search_where "$src")")
        ((S_TOTAL > 0)) && items+=("all|Select all")
        [[ $src != remove ]] && ((S_HAVE > 0 && S_HAVE < S_TOTAL)) &&
            items+=("missing|Select only the $((S_TOTAL - S_HAVE)) not installed")
        ((S_TOTAL > 0)) && items+=("none|Select none")
        items+=("back|$SYM_BACK Back")
        ((S_TOTAL > 0)) || cursor=search
        ui_screen "$title" "${lines[@]}"
        ui_menu choice "esc back" --cursor "$cursor" "${items[@]}" || return 0
        cursor=$choice
        case $choice in
            all | missing | none) sel_set "$src" "$choice"; return 0 ;;
            pick) sel_choose "$src" && return 0 ;;
            search) sel_search "$src" ;;
            back) return 0 ;;
        esac
    done
}

# sel_choose SRC - toggle SRC's packages one by one; returns 1 if cancelled
sel_choose() {
    local src=$1 name w
    local -a names items=() pre=() chosen=()
    sel_names names "$src"
    w=$(sel_label_width "${names[@]}")
    for name in "${names[@]}"; do
        items+=("$name|$(sel_item_label "$src" "$name" "$w")")
        is_picked "$src" "$name" && pre+=("$name")
    done
    ui_screen "${SRC_TITLE[$src]}"
    ui_multiselect chosen "esc cancel" pre "${items[@]}" || return 1
    sel_set "$src" none
    for name in "${chosen[@]}"; do PICKED[$src/$name]=1; done
    log INFO "chose ${#chosen[@]} of ${#names[@]} for $src"
}

# ------------------------------------------------------------- search ----
# search_SRC QUERY - print "name<TAB>description" lines for matches

search_dnf() {
    local -a words
    read -r -a words <<< "$1"
    dnf -q --assumeno search -- "${words[@]}" < /dev/null 2>/dev/null |
        awk -F'\t' '/^ [^ ]/ {
            n = $1; sub(/^ +/, "", n); sub(/\.[^.]+$/, "", n)   # drop " " and ".arch"
            if (!seen[n]++) print n "\t" $2 }'
}

search_flatpak() {
    # flatpak's own order buries apps under their themes and plugins, so
    # rank: exact name, name prefix, name match, anything else; add-ons last
    flatpak search --columns=application,name,description,remotes -- "$1" 2>/dev/null |
        awk -F'\t' -v q="${1,,}" '$4 ~ /flathub/ && !seen[$1]++ {
            n = tolower($2)
            s = (n == q) ? 0 : (index(n, q) == 1) ? 1 : index(n, q) ? 2 : 3
            if ($1 ~ /Gtk3theme|\.Plugin\.|\.Extension\.|\.Addon|\.Codecs|\.Platform|\.Sdk|\.BaseApp|\.KStyle|\.Locale|\.Debug/) s += 10
            d = $2; if ($3 != "") d = d " - " $3
            print s "\t" $1 "\t" d }' |
        sort -s -n -k1,1 | cut -f2-
}

search_brew() {
    local name json desc
    local -a words
    read -r -a words <<< "$1"
    if brew_load_env; then
        brew search --formula -- "${words[@]}" 2>/dev/null |
            awk '!/^==>/ { for (i = 1; i <= NF; i++) print $i "\tHomebrew formula" }'
        return
    fi
    # no brew yet: look up exact names in Homebrew's online formula index
    for name in "${words[@]}"; do
        name=${name,,}
        [[ $name =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] || continue
        json=$(curl -fsS --max-time 20 "https://formulae.brew.sh/api/formula/$name.json" 2>/dev/null) || continue
        desc=$(grep -o '"desc":"[^"]*"' <<< "$json" | head -n 1 | cut -d'"' -f4)
        printf '%s\t%s\n' "$name" "${desc:-Homebrew formula}"
    done
}

# installed rpms and Flatpak apps whose name or summary contains every
# word of the query; name matches first
search_remove() {
    {
        rpm -qa --qf '%{NAME}\t%{SUMMARY}\n' 2>/dev/null
        command -v flatpak &>/dev/null &&
            flatpak list --app --columns=application,name 2>/dev/null | awk -F'\t' '{ print "flatpak:" $1 "\t" $2 " (Flatpak)" }'
    } | awk -F'\t' -v q="${1,,}" '
        BEGIN { n = split(q, w, " ") }
        !seen[$1]++ {
            line = tolower($0); for (i = 1; i <= n; i++) if (!index(line, w[i])) next
            name = tolower($1); s = (name == q) ? 0 : index(name, w[1]) ? 1 : 2
            print s "\t" $0 }' |
        sort -t$'\t' -k1,1n -k2,2 | cut -f2-
}

# sel_search_prepare SRC - make searching possible; 1 (with SEL_FLASH) if not
sel_search_prepare() {
    [[ $1 == flatpak ]] || return 0
    if ! command -v flatpak &>/dev/null; then
        SEL_FLASH="${C_YELLOW}Flatpak isn't installed yet, so Flathub can't be searched before this run.${C_RESET}"
        return 1
    fi
    ((FLATHUB_READY)) && return 0
    # same --user remote the install phase sets up; fetch its app catalogue
    ui_busy_start "Fetching the Flathub catalogue..."
    if ! flatpak remotes --user --columns=name 2>/dev/null | grep -qx flathub; then
        flatpak remote-add --if-not-exists --user flathub "$FLATHUB_URL" &>/dev/null
    fi
    flatpak update --user --appstream flathub < /dev/null &>/dev/null
    ui_busy_stop
    FLATHUB_READY=1
}

sel_search() {
    local src=$1 query results name desc where w example title
    where=$(sel_search_where "$src")
    title="${SRC_TITLE[$src]}  ${C_DIM}/${C_RESET}  Search $where"
    sel_search_prepare "$src" || return 0
    case $src in
        remove) example="e.g. kmahjongg, or a word like games" ;;
        dnf) example="e.g. video editor" ;;
        flatpak) example="e.g. obsidian" ;;
        brew) example="e.g. ripgrep" ;;
    esac
    while :; do
        local -a lines=() names=() items=() none=() chosen=() listed=()
        local -A in_list=()
        local skipped=0 more=0
        [[ $src == brew ]] && ! brew_load_env &&
            lines+=("${C_DIM}Homebrew isn't installed yet: type exact formula names, separated by spaces.${C_RESET}")
        _flash_lines lines
        ui_screen "$title" "${lines[@]}"
        ui_input query "esc back" "$example" || return 0

        ui_busy_start "Searching $where for \"$query\"..."
        results=$("search_$src" "$query")
        ui_busy_stop
        log INFO "search $src '$query': $(grep -c . <<< "$results") result(s)"

        sel_names listed "$src"
        for name in "${listed[@]}"; do in_list[$name]=1; done
        while IFS=$'\t' read -r name desc; do
            [[ -n $name ]] || continue
            if [[ -n ${in_list[$name]:-} ]]; then skipped=$((skipped + 1)); continue; fi
            if ((${#names[@]} >= SEARCH_LIMIT)); then more=1; break; fi
            names+=("$name")
            NOTE[$src/$name]=$desc
        done <<< "$results"

        if ((${#names[@]} == 0)); then
            if ((skipped > 0)); then
                SEL_FLASH="${C_YELLOW}Everything matching \"$query\" is already in the list.${C_RESET}"
            elif [[ $src != remove ]] && ! net_online; then
                SEL_FLASH="${C_YELLOW}No results - and no internet connection, which searching needs.${C_RESET}"
            else
                SEL_FLASH="${C_YELLOW}No matches for \"$query\".${C_RESET}"
            fi
            continue
        fi

        "sel_mark_$src" "${names[@]}"
        w=$(sel_label_width "${names[@]}")
        for name in "${names[@]}"; do items+=("$name|$(sel_item_label "$src" "$name" "$w")"); done
        lines=("${#names[@]} result$( ((${#names[@]} == 1)) || echo s) for \"$query\"")
        ((skipped)) && lines[0]+="${C_DIM} · $skipped more already in the list${C_RESET}"
        ((more)) && lines+=("${C_YELLOW}Showing the first $SEARCH_LIMIT - be more specific to see the rest.${C_RESET}")
        ui_screen "$title" "${lines[@]}"
        ui_multiselect chosen "esc new search" none "${items[@]}" || continue
        if ((${#chosen[@]} == 0)); then
            SEL_FLASH="${C_YELLOW}Nothing was selected - press x or space to select, then enter.${C_RESET}"
            continue
        fi
        for name in "${chosen[@]}"; do sel_add "$src" "$name"; done
        log INFO "added to $src from search: ${chosen[*]}"
        SEL_FLASH="${C_GREEN}${SYM_OK} Added ${#chosen[@]}: $(fit "${chosen[*]}" $((COLS - 20)))${C_RESET}"
        return 0
    done
}

# ----------------------------------------------------------- finishing ----
sel_review() {
    local p choice detail
    local -a lines=()
    sel_plan_stats
    for p in "${ALL_PHASES[@]}"; do
        sel_offered "$p" || continue
        case $p in
            upgrade) ((PHASE_ON[upgrade])) && lines+=("$(printf '%-20s %s' "System upgrade" "dnf upgrade --refresh")") ;;
            dotfiles) ((PHASE_ON[dotfiles])) && lines+=("$(printf '%-20s %s' "Dotfiles" "clone or pull, then stow")") ;;
            *)
                sel_stats "$p"
                ((S_PICKED > 0)) || continue
                if [[ $p == remove ]]; then
                    detail="$S_TODO to remove"
                    ((S_PICKED > S_TODO)) && detail+="${C_DIM} · $((S_PICKED - S_TODO)) already gone${C_RESET}"
                else
                    detail="$S_TODO to install"
                    ((S_PICKED > S_TODO)) && detail+="${C_DIM} · $((S_PICKED - S_TODO)) installed${C_RESET}"
                fi
                lines+=("$(printf '%-20s %s' "${SRC_TITLE[$p]}" "$detail")") ;;
        esac
    done
    lines+=("${C_DIM}$(repeat "$HR_CHAR" 44)${C_RESET}"
        "${C_BOLD}$(printf '%-20s %s' "Total" "$T_TODO to do")${C_RESET}$( ((T_HAVE)) && printf '%s · %d already done%s' "$C_DIM" "$T_HAVE" "$C_RESET")"
        ""
        "${C_DIM}Failed steps are retried, and a dropped connection is waited out.${C_RESET}"
        "${C_DIM}ctrl-c pauses the run; quitting saves progress for a resume.${C_RESET}")
    ui_screen "Ready" "${lines[@]}"
    ui_menu choice "esc back" "start|$SYM_START Start" "back|$SYM_BACK Back" || return 1
    [[ $choice == start ]] || return 1
    sel_offer_save
    return 0
}

# sel_offer_save - offer to append search additions to the package lists
sel_offer_save() {
    local src name n=0 them
    local -a files=() names
    for src in "${PKG_SOURCES[@]}"; do
        local had=$n
        sel_names names "$src"
        for name in "${names[@]}"; do
            [[ -n ${ADDED[$src/$name]:-} ]] && is_picked "$src" "$name" && n=$((n + 1))
        done
        ((n > had)) && files+=("${SRC_FILE[$src]}")
    done
    ((n > 0)) || return 0
    them=$( ((n == 1)) && echo it || echo them)
    ui_yesno "Save to lists" "$(printf 'You added %d package%s by searching. Also add %s to\n%s, so future runs include %s too?' \
        "$n" "$( ((n == 1)) || echo s)" "$them" "${files[*]}" "$them")" \
        no "Save" "This run only" || return 0
    for src in "${PKG_SOURCES[@]}"; do
        sel_names names "$src"
        for name in "${names[@]}"; do
            [[ -n ${ADDED[$src/$name]:-} ]] && is_picked "$src" "$name" && sel_append_to_list "$src" "$name"
        done
    done
}

sel_append_to_list() {
    local file=$SCRIPT_DIR/${SRC_FILE[$1]}
    # keep the file's last line intact if it has no trailing newline
    [[ -s $file && -n $(tail -c 1 "$file") ]] && printf '\n' >> "$file"
    if [[ $1 == brew ]]; then
        printf 'brew "%s"\n' "$2" >> "$file"
    else
        printf '%s\n' "$2" >> "$file"
    fi
    log INFO "saved $2 to ${SRC_FILE[$1]}"
}

sel_to_plan() {
    local p name
    local -a names
    plan_reset
    for p in "${ALL_PHASES[@]}"; do
        sel_offered "$p" || continue
        case $p in
            upgrade) ((PHASE_ON[upgrade])) && plan_add system upgrade ;;
            dotfiles) ((PHASE_ON[dotfiles])) && { plan_add dotfiles repo; plan_add dotfiles stow; } ;;
            *)
                sel_names names "$p"
                local -a chosen=()
                for name in "${names[@]}"; do
                    is_picked "$p" "$name" && { plan_add "$p" "$name"; chosen+=("$name"); }
                done
                log INFO "selected for $p: ${#chosen[@]} - ${chosen[*]}" ;;
        esac
    done
}

# choose_plan - work out what to do (interactively unless -y) and write it
# to the plan file
choose_plan() {
    local -a phases
    if [[ -n $ONLY ]]; then
        read -r -a phases <<< "${ONLY//,/ }"
    else
        phases=("${ALL_PHASES[@]}")
    fi
    sel_load "${phases[@]}"
    # asked for by name with --only: the upgrade is wanted
    [[ -n $ONLY ]] && sel_offered upgrade && PHASE_ON[upgrade]=1
    if ((!ASSUME_YES && INTERACTIVE)); then
        ui_busy_start "Checking what's installed..."
        sel_scan_installed
        ui_busy_stop
        sel_hub
    fi
    sel_to_plan
}
