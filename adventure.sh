#!/usr/bin/env bash

# ADVENTURESH
# A pure Bash port of Colossal Cave Adventure (1977)

declare -r TITLE="ADVENTURESH"
declare -r VERSION="1.0"
declare -r AUTHOR="Rodney Shupe"
declare -r ABOUT="A pure-Bash port of Colossal Cave Adventure (1977): play the Crowther/Woods 350-point game, or use --crowther for Crowther-compatible mode (Woods engine restricted to Crowther's 21-location footprint, in spirit rather than byte-identical)."

set -u

declare -r SCRIPT_PATH="$0"

declare -r TRUE=0
declare -r FALSE=1

declare -i USE_MIXEDCASE=$FALSE

# --- Global State Arrays ---
declare -a LLINE
declare -a IOBJ ICHAIN IPLACE IFIXED COND PROP ABB
declare -a LTEXT STEXT KEY DEFAULT TRAVEL
declare -a TK KTAB ATAB BTEXT
declare -a RTEXT

declare -a HINTLC HINTED
declare -i HNTMAX=0
declare -i HINT_DUE=-1

for i in {1..300}; do
    IOBJ[$i]=0; ICHAIN[$i]=0; IPLACE[$i]=0; IFIXED[$i]=0; COND[$i]=0; PROP[$i]=0; ABB[$i]=0
    LTEXT[$i]=0; STEXT[$i]=0; KEY[$i]=0; DEFAULT[$i]=0; TRAVEL[$i]=0
    if (( i <= 100 )); then RTEXT[$i]=0; fi
    if (( i <= 200 )); then BTEXT[$i]=0; fi
done

declare -r -i KEYS=1
declare -r -i LAMP=2
declare -r -i GRATE=3
declare -r -i CAGE=4
declare -r -i ROD=5
declare -r -i ROD2=6
declare -r -i BIRD=8
declare -r -i NUGGET=50
declare -r -i SNAKE=11
declare -r -i FISSUR=12
declare -r -i FOOD=19
declare -r -i WATER=21
declare -r -i AXE=28
declare -r -i KNIFE=18
declare -r -i BEAR=35
declare -r -i CHAIN=64
declare -r -i VEND=38
declare -r -i BATTER=39
declare -r -i COINS=54
declare -r -i CHEST=55
declare -r -i EMRALD=59
declare -r -i PYRAM=60

declare -r -a JSPKT=(0 24 29 0 31 0 31 38 38 42 42 43 46 77 71 73 75)

# ---------------------------------------------------------------------------
#  Object placement
# ---------------------------------------------------------------------------

declare -i DFLAG=0
declare -i IFIRST=1
declare -i IWEST=0
declare -i ILONG=1
declare -i HOLDNG=0
declare -i OBJ=0

declare -i KNFLOC=0
declare -i CLOSED=$FALSE
declare -i CLOSNG=0
declare -i BONUS=0
declare -i GAVEUP=0
declare -i SCORNG=0
declare -i SUSPENDED=$FALSE

declare -i CROWTHER_MODE=$FALSE

declare -i DATIME_D=0
declare -i DATIME_T=0
declare -i DATIME_WDAY=0

declare -i PRIMTM=0
declare -i WKDAY=0
declare -i WKEND=0
declare -i HOLID=0

declare -i HBEGIN=0
declare -i HEND=0
declare -a HNAME

declare -i SHORT=30
declare MAGIC_WORD="DWARF"
declare -i MAGNM=11111
declare -i LATNCY=90
declare -i SAVED=0
declare -i SAVET=0
declare -i SETUP=0
declare -i DEMO=$FALSE
declare -i NEWHRX_RESULT=0

declare MOTD=""

declare WIZCOM_FILE="adventure.wizcom"
declare -ar WIZCOM_SCALARS=(
    WKDAY WKEND HOLID HBEGIN HEND
    SHORT MAGIC_WORD MAGNM LATNCY
    MOTD
)
declare -ar WIZCOM_ARRAYS=(HNAME)

declare -i CLOCK1=30
declare -i CLOCK2=50
declare -i PANIC=$FALSE

declare -i LIMIT=330
declare -i LMWARN=$FALSE

declare -i RESURRECTED=$FALSE

declare -i TURNS=0

declare -i FOOBAR=0

declare -i NUMDIE=0
declare -i MAXDIE=0
declare -i LAST_SCORE=0 LAST_MXSCOR=0

# ---------------------------------------------------------------------------
#  Object placement — 350-point encoding (section 7)
# ---------------------------------------------------------------------------

declare -a PLAC FIXD

# parse_object_placement_350 — must be called directly, not in $(...).
function parse_object_placement_350() {
    local line
    local -a fields
    local -i obj

    PLAC=(); FIXD=()

    for line in "${RAW_PLAC[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 2 )) || continue
        obj=${fields[0]}
        PLAC[$obj]=${fields[1]}
        FIXD[$obj]=${fields[2]:-0}
    done
}

# ---------------------------------------------------------------------------
#  Action-verb defaults — 350-point encoding (section 8)
# ---------------------------------------------------------------------------

declare -a ACTSPK

# parse_action_defaults_350 — must be called directly, not in $(...).
function parse_action_defaults_350() {
    local line
    local -a fields
    local -i verb

    ACTSPK=()

    for line in "${RAW_ACTSPK[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 2 )) || continue
        verb=${fields[0]}
        [[ "$verb" =~ ^[0-9]+$ ]] || continue
        ACTSPK[$verb]=${fields[1]}
    done
}

# ---------------------------------------------------------------------------
#  COND bits per location — 350-point encoding (section 9)
# ---------------------------------------------------------------------------

declare -r -i COND_MAX_LOCS_PER_LINE=20
declare -r -i LOCSIZ350=150

# parse_cond_bits_350 — must be called directly, not in $(...).
function parse_cond_bits_350() {
    local line loc
    local -a fields
    local -i bit n

    for line in "${RAW_COND[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 1 )) || continue
        bit=${fields[0]}
        [[ "$bit" =~ ^[0-9]+$ ]] || continue

        # 0 ends the location list for this bit.
        for (( n = 1; n <= COND_MAX_LOCS_PER_LINE && n < ${#fields[@]}; n++ )); do
            loc=${fields[$n]}
            [[ "$loc" =~ ^[0-9]+$ ]] || break
            (( loc == 0 )) && break
            (( COND[loc] |= (1 << bit) ))
        done
    done
}

# parse_hints_350 — must be called directly, not in $(...).
function parse_hints_350() {
    local line
    local -a fields
    local -i hint

    HINT_TURNS=()
    HINT_PENALTY=()
    HINT_QMSG=()
    HINT_HINTMSG=()
    HNTMAX=0

    for line in "${RAW_HINTS[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 5 )) || continue
        hint=${fields[0]}
        [[ "$hint" =~ ^[0-9]+$ ]] || continue

        HINT_TURNS[$hint]=${fields[1]}
        HINT_PENALTY[$hint]=${fields[2]}
        HINT_QMSG[$hint]=${fields[3]}
        HINT_HINTMSG[$hint]=${fields[4]}

        (( hint > HNTMAX )) && HNTMAX=$hint
    done
}

# ---------------------------------------------------------------------------
#  Object descriptions — 350-point encoding (section 5)
# ---------------------------------------------------------------------------

declare -r -i OBJPROP_SCALE=100

# parse_object_text_350 — must be called directly, not in $(...).
function parse_object_text_350() {
    local line id text
    local -i prev_id=-1 cur_obj=0 cur_prop=-1 key

    INVEN_TEXT=(); OBJ_TEXT=()

    for line in "${RAW_OBJTEXT[@]}"; do
        read -r id text <<< "$line"
        [[ "$id" =~ ^[0-9]+$ ]] || continue

        if (( id == prev_id )); then
            # Continuation of whichever message is currently open.
            if (( cur_prop < 0 )); then
                INVEN_TEXT[cur_obj]="${INVEN_TEXT[cur_obj]:-}${text}\n"
            else
                key=$(( cur_obj * OBJPROP_SCALE + cur_prop ))
                OBJ_TEXT[key]="${OBJ_TEXT[key]:-}${text}\n"
            fi
        elif (( id != 0 && id % 100 != 0 )); then
            # A real object number: starts that object's inventory-name entry.
            cur_obj=$id
            cur_prop=-1
            INVEN_TEXT[cur_obj]="${text}\n"
        else
            # A PROP-index marker: starts the next room-description message.
            (( cur_prop++ ))
            key=$(( cur_obj * OBJPROP_SCALE + cur_prop ))
            OBJ_TEXT[key]="${text}\n"
        fi

        prev_id=$id
    done
}

# init_objects — must be called directly, not in $(...).
function init_objects() {
    local -i i k ktem

    # A second call would otherwise chain objects onto the previous run's
    # lists and loop forever building them.
    for (( i = 1; i <= 300; i++ )); do IOBJ[i]=0; done
    HOLDNG=0

    if (( ${#RAW_OBJTEXT[@]} > 0 )); then
        parse_object_text_350
    fi

    if (( ${#RAW_ACTSPK[@]} > 0 )); then
        parse_action_defaults_350
    fi

    if (( ${#RAW_HINTS[@]} > 0 )); then
        parse_hints_350
        # HINTED must start FALSE ($FALSE=1) or hint_check reads every hint
        # as already given and never accumulates dwell time.
        for (( i = 1; i <= HNTMAX; i++ )); do
            HINTLC[i]=0
            HINTED[i]=$FALSE
        done
    fi

    if (( ${#RAW_COND[@]} > 0 )); then
        parse_cond_bits_350

        # Forced-motion override, applied after the data-driven bits above
        # so it wins per the section-9 comment.
        parse_travel_table
        for (( i = 1; i <= LOCSIZ350; i++ )); do
            [[ -n "${RAW_TEXT[i]:-}" ]] || continue
            (( ${KEY[i]:-0} == 0 )) && continue
            (( TRAVEL_KEY[${KEY[i]}] == TRAVEL_ANY )) && COND[i]=$COND_FORCED
        done
    else
        for (( i = 1; i <= 10; i++ )); do COND[i]=1; done
        for i in 16 20 21 22 23 24 25 26 31 32 79; do COND[i]=$COND_FORCED; done
    fi

    if (( ${#RAW_PLAC[@]} > 0 )); then
        parse_object_placement_350

        for (( i = 1; i <= 200; i++ )); do ICHAIN[i]=0; done
        for (( i = 1; i <= 100; i++ )); do IPLACE[i]=0; IFIXED[i]=0; done

        # Two-placed objects only, dropped first (backwards) so
        # single-placed objects end up described last.
        for (( i = 1; i <= 100; i++ )); do
            k=$(( 101 - i ))
            (( ${FIXD[k]:-0} > 0 )) || continue

            ktem=${FIXD[k]}
            ICHAIN[$((k + 100))]=${IOBJ[ktem]}
            IOBJ[ktem]=$(( k + 100 ))

            IPLACE[k]=${PLAC[k]:-0}
            ktem=${PLAC[k]:-0}
            if (( ktem > 0 )); then
                ICHAIN[k]=${IOBJ[ktem]}
                IOBJ[ktem]=$k
            fi
        done

        # FIXED copied for every object, then the (backwards-walked)
        # single-placement drop for the rest.
        for (( i = 1; i <= 100; i++ )); do
            k=$(( 101 - i ))
            IFIXED[k]=${FIXD[k]:-0}
            (( ${PLAC[k]:-0} != 0 && ${FIXD[k]:-0} <= 0 )) || continue

            IPLACE[k]=${PLAC[k]}
            ktem=${PLAC[k]}
            ICHAIN[k]=${IOBJ[ktem]}
            IOBJ[ktem]=$k
        done
    else
        # Fallback: Crowther-era hardcoded placement table.
        local -a iplt=(0 3 3 8 10 11 14 13 9 15 18 19 17 27 28 29 30 0 0 3 3)
        local -a ifixt=(0 0 0 1 0 0 1 0 1 1 0 1 1 0 0 0 0 0 0 0 0)

        for (( i = 1; i <= 100; i++ )); do
            IPLACE[i]=${iplt[i]:-0}
            IFIXED[i]=${ifixt[i]:-0}
            ICHAIN[i]=0
        done

        for (( i = 1; i <= 100; i++ )); do
            ktem=${IPLACE[i]}
            (( ktem == 0 )) && continue
            if (( IOBJ[ktem] == 0 )); then
                IOBJ[ktem]=$i
            else
                ktem=${IOBJ[ktem]}
                while (( ICHAIN[ktem] != 0 )); do
                    ktem=${ICHAIN[ktem]}
                done
                ICHAIN[ktem]=$i
            fi
        done
    fi

    # Every treasure present in the data starts at PROP=-1 (found but not
    # yet described); TALLY is the count of those.
    TALLY=0
    for (( i = TREASURE_MIN; i <= TREASURE_MAX; i++ )); do
        [[ -n "${INVEN_TEXT[i]:-}" ]] && PROP[i]=-1
        TALLY=$(( TALLY - PROP[i] ))
    done

    DFLAG=0
    IFIRST=1
    IWEST=0
    ILONG=1
    IDETAL=0
    KNFLOC=0
    TURNS=0
    NUMDIE=0
    GAVEUP=$FALSE
    SCORNG=$FALSE
    CLOSNG=$FALSE
    BONUS=0
    CLOCK1=30
    CLOCK2=50
    PANIC=$FALSE
    LMWARN=$FALSE   # LIMIT itself is set later, in play_game

    # MAXDIE is however many of the five reincarnation obituary messages
    # the loaded data actually defines.
    MAXDIE=0
    for (( i = 0; i <= 4; i++ )); do
        [[ -n "${RAW_MSG[$(( 2 * i + 81 ))]:-}" ]] && MAXDIE=$(( i + 1 ))
    done

    # Dwarves start in five hard-wired rooms, no two adjacent; the pirate
    # (slot 6) always starts at his chest's eventual hiding place.
    for (( i = 1; i <= PIRATE; i++ )); do
        DLOC[i]=${DSTART[$i]}
        ODLOC[i]=0
        DSEEN[i]=0
    done
}

# dump_objects
function dump_objects() {
    local -i room obj base

    for (( room = 1; room <= 150; room++ )); do
        (( ${IOBJ[room]:-0} == 0 )) && continue
        printf 'room %3d:' "$room"
        obj=${IOBJ[room]}
        while (( obj != 0 )); do
            base=$obj
            (( base > 100 )) && base=$(( base - 100 ))
            printf ' obj=%-3d%s%s' "$obj" \
                "$( (( obj > 100 )) && printf '(2nd loc of %d)' "$base" )" \
                "$( (( ${IFIXED[base]:-0} != 0 )) && echo '(fixed)' )"
            obj=${ICHAIN[obj]:-0}
        done
        printf '\n'
    done

    local -i i unplaced=0
    for (( i = 1; i <= 100; i++ )); do
        (( ${IPLACE[i]:-0} == 0 )) || continue
        (( unplaced == 0 )) && printf 'unplaced:'
        printf ' obj=%d' "$i"
        unplaced=1
    done
    (( unplaced == 1 )) && printf '\n'
}

# dump_object_text OBJ...
function dump_object_text() {
    local -i obj prop key
    local text

    if (( $# == 0 )); then
        # List all objects that have any PROP text
        for (( obj = 1; obj <= 100; obj++ )); do
            local has_text=0
            for (( prop = 0; prop <= 10; prop++ )); do
                key=$(( obj * OBJPROP_SCALE + prop ))
                [[ -n "${OBJ_TEXT[$key]:-}" ]] && has_text=1 && break
            done
            (( has_text == 0 )) && continue

            printf 'obj %3d (%s):\n' "$obj" "${INVEN_TEXT[$obj]:-<no inventory name>}"
            for (( prop = 0; prop <= 10; prop++ )); do
                key=$(( obj * OBJPROP_SCALE + prop ))
                text="${OBJ_TEXT[$key]:-}"
                if [[ -z "$text" ]]; then
                    # Only show PROP if we've already seen text for this object
                    (( prop == 0 )) && continue
                    # Check if there's any higher PROP text (to avoid showing gaps)
                    local found_higher=0
                    for (( p = prop + 1; p <= 10; p++ )); do
                        k=$(( obj * OBJPROP_SCALE + p ))
                        [[ -n "${OBJ_TEXT[$k]:-}" ]] && found_higher=1 && break
                    done
                    (( found_higher == 0 )) && break
                    printf '  PROP %d: <none>\n' "$prop"
                else
                    # Compact single-line display; preserve newlines within message
                    text="${text%$'\n'}"  # strip trailing newline from load_data
                    printf '  PROP %d: %s\n' "$prop" "${text}"
                fi
            done
        done
        return
    fi

    # With specific object args, show their full PROP chains
    for obj in "$@"; do
        printf 'obj %3d (%s):\n' "$obj" "${INVEN_TEXT[$obj]:-<no inventory name>}"
        for (( prop = 0; prop <= 10; prop++ )); do
            key=$(( obj * OBJPROP_SCALE + prop ))
            text="${OBJ_TEXT[$key]:-}"
            if [[ -z "$text" ]]; then
                printf '  PROP %d: <none>\n' "$prop"
            else
                text="${text%$'\n'}"  # strip trailing newline
                printf '  PROP %d: %s\n' "$prop" "${text}"
            fi
        done
    done
}

# dump_actspk [VERB...]
function dump_actspk() {
    local -i verb

    if (( $# == 0 )); then
        for verb in "${!ACTSPK[@]}"; do
            printf 'verb %2d -> msg %d\n' "$verb" "${ACTSPK[$verb]}"
        done | sort -n -k2
        return
    fi

    for verb in "$@"; do
        printf 'verb %2d -> msg %s\n' "$verb" "${ACTSPK[$verb]:-<unset>}"
    done
}

# dump_cond LOC...
function dump_cond() {
    local -i loc b val

    for loc in "$@"; do
        val=${COND[$loc]:-0}
        printf 'loc %3d: COND=%-3d bits:' "$loc" "$val"
        for (( b = 0; b <= 9; b++ )); do
            bitset "$loc" "$b" && printf ' %d' "$b"
        done
        printf '\n'
    done
}

# dump_hints [HINT#...]
function dump_hints() {
    local -i hint

    if (( $# == 0 )); then
        for hint in "${!HINT_TURNS[@]}"; do
            printf 'hint %d: turns=%d penalty=%d qmsg=%d hintmsg=%d\n' \
                "$hint" "${HINT_TURNS[$hint]}" "${HINT_PENALTY[$hint]}" \
                "${HINT_QMSG[$hint]}" "${HINT_HINTMSG[$hint]}"
        done | sort -n -k2
        printf 'HNTMAX=%d\n' "$HNTMAX"
        return
    fi

    for hint in "$@"; do
        printf 'hint %d: turns=%s penalty=%s qmsg=%s hintmsg=%s\n' "$hint" \
            "${HINT_TURNS[$hint]:-<unset>}" "${HINT_PENALTY[$hint]:-<unset>}" \
            "${HINT_QMSG[$hint]:-<unset>}" "${HINT_HINTMSG[$hint]:-<unset>}"
    done
}

# dump_ctext [THRESHOLD...]
function dump_ctext() {
    local -i threshold

    if (( $# == 0 )); then
        for threshold in "${!RAW_CTEXT[@]}"; do
            printf 'threshold %d: %s\n' "$threshold" "${RAW_CTEXT[$threshold]}"
        done | sort -n -k2
        return
    fi

    for threshold in "$@"; do
        printf 'threshold %d: %s\n' "$threshold" "${RAW_CTEXT[$threshold]:-<unset>}"
    done
}

# dump_magic [ID...]
function dump_magic() {
    local -i id

    if (( $# == 0 )); then
        for id in "${!RAW_MAGIC[@]}"; do
            printf 'magic %d: %s\n' "$id" "${RAW_MAGIC[$id]}"
        done | sort -n -k2
        return
    fi

    for id in "$@"; do
        printf 'magic %d: %s\n' "$id" "${RAW_MAGIC[$id]:-<unset>}"
    done
}

# --- Parser and Loader ---

declare -a RAW_TEXT
declare -a RAW_SHORT
declare -a RAW_TRAVEL=()
declare -a VOCAB_ID=()
declare -a VOCAB_WORD=()
declare -a RAW_OBJTEXT=()
declare -a OBJ_TEXT
declare -a INVEN_TEXT
declare -a RAW_MSG

# ---------------------------------------------------------------------------
#  350-point data-file format
# ---------------------------------------------------------------------------
#
# Section -> raw storage array:
#    1  long location descriptions          -> RAW_TEXT
#    2  short location descriptions         -> RAW_SHORT
#    3  travel table (LOC/NEWLOC/verbs)     -> RAW_TRAVEL
#    4  vocabulary (word, N; M=N/1000=class) -> VOCAB_ID/VOCAB_WORD
#    5  object descriptions (PROP-indexed)  -> RAW_OBJTEXT
#    6  arbitrary messages (RTEXT)          -> RAW_MSG
#    7  initial object locations (PLAC/FIXD) -> RAW_PLAC
#    8  action-verb default responses (ACTSPK) -> RAW_ACTSPK
#    9  COND bits per location              -> RAW_COND
#   10  player-classification messages (CTEXT/CVAL) -> RAW_CTEXT
#   11  hints (HINTS(20,4)/HINTLC/HINTED)    -> RAW_HINTS
#   12  magic messages (MTEXT)               -> RAW_MAGIC
#    0  end of database                      -> loop terminator
declare -a RAW_PLAC
declare -a RAW_ACTSPK
declare -a RAW_COND=()
declare -a RAW_CTEXT
declare -a RAW_HINTS=()
declare -a RAW_MAGIC

# RAW_HINTS decodes into four parallel arrays per hint number.
declare -a HINT_TURNS
declare -a HINT_PENALTY
declare -a HINT_QMSG
declare -a HINT_HINTMSG

# load_message_line TARGET_ARRAY — must be called directly, not in $(...).
function load_message_line() {
    local target_array=$1
    local id text
    read -r id text <<< "$line"
    [[ "$id" =~ ^[0-9]+$ ]] || return
    eval "${target_array}[\$id]=\"\${${target_array}[\$id]:-}\${text}\n\""
}

function load_data() {
    local file="${1:-$SCRIPT_PATH}"
    local source_desc="$file"

    # If file doesn't exist and we're trying to read the script, use stdin instead (for piped execution)
    if [[ ! -f "$file" ]] && [[ "$file" == "$SCRIPT_PATH" ]]; then
        source_desc="stdin"
    fi

    echo "Loading game data from $source_desc..."
    local section=-1
    local id text
    local in_data=0
    local vocab_idx=0

    # Clear arrays to avoid mixing old and new data
    RAW_TEXT=()
    RAW_SHORT=()
    RAW_TRAVEL=()
    VOCAB_ID=()
    VOCAB_WORD=()
    RAW_OBJTEXT=()
    RAW_MSG=()
    RAW_PLAC=()
    RAW_ACTSPK=()
    RAW_COND=()
    RAW_CTEXT=()
    RAW_HINTS=()
    RAW_MAGIC=()

    # If reading from an external file (not the script itself), don't scan for DATA_START
    if [[ "$file" != "$SCRIPT_PATH" ]]; then
        in_data=1
    fi

    while IFS= read -r line; do
        if (( in_data == 0 )); then
            [[ "$line" == "DATA_START" ]] && in_data=1
            continue
        fi

        # Check for section ends (-1)
        if [[ "$line" == "-1"* ]]; then
            continue
        fi

        # A bare section number of 0 marks the end of the data (the Fortran
        # loader's "READ section number, 0 means done" at label 1002).
        if [[ "$line" == "0" ]]; then
            break
        fi

        # A bare number opens a section (1-12); must cover the whole range or
        # an unmatched header gets read as a data line and corrupts whatever
        # section is currently active.
        if [[ "$line" =~ ^[1-9]$|^1[0-2]$ ]]; then
            section="$line"
            continue
        fi

        # Uppercase data unless -m flag was set (vocabulary always uppercase)
        if (( section == 4 || USE_MIXEDCASE == FALSE )); then
            line=$(echo "$line" | tr '[:lower:]' '[:upper:]')
        fi

        if (( section == 1 )); then
            load_message_line RAW_TEXT
        elif (( section == 2 )); then
            load_message_line RAW_SHORT
        elif (( section == 3 )); then
            RAW_TRAVEL+=("$line")
        elif (( section == 4 )); then
            read -r id text _ <<< "$line"
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                VOCAB_ID[$vocab_idx]=$id
                VOCAB_WORD[$vocab_idx]=$text
                ((vocab_idx++))
            fi
        elif (( section == 5 )); then
            RAW_OBJTEXT+=("$line")
        elif (( section == 6 )); then
            load_message_line RAW_MSG
        elif (( section == 7 )); then
            RAW_PLAC+=("$line")
        elif (( section == 8 )); then
            RAW_ACTSPK+=("$line")
        elif (( section == 9 )); then
            RAW_COND+=("$line")
        elif (( section == 10 )); then
            load_message_line RAW_CTEXT
        elif (( section == 11 )); then
            RAW_HINTS+=("$line")
        elif (( section == 12 )); then
            load_message_line RAW_MAGIC
        fi
    done < "$file"
    echo "Data loaded."
}

# ---------------------------------------------------------------------------
#  Travel table (section 3)
# ---------------------------------------------------------------------------

declare -r -i TRAVEL_SCALE=1000
declare -r -i TRAVEL_ANY=1
declare -r -i TRAVEL_DEST_MAX=300
declare -r -i TRAVEL_SPECIAL_MAX=500
declare -r -i TRAVEL_SPECIAL_BASE=300
declare -r -i TRAVEL_MSG_BASE=500
declare -r -i TRAVEL_MAX_KEYWORDS=20
declare -r -i TRAVEL_MAX_ENTRIES=750

declare -a TRAVEL_SRC TRAVEL_KEY TRAVEL_NEWLOC TRAVEL_COND TRAVEL_DEST TRAVEL_LAST
declare -i TRAVEL_COUNT=0

# parse_travel_table — must be called directly, not in $(...).
function parse_travel_table() {
    local line src newloc
    local -a fields
    local -i idx=1 n=0 mot=0 packed=0

    KEY=(); TRAVEL=(); TRAVEL_SRC=(); TRAVEL_KEY=(); TRAVEL_NEWLOC=()
    TRAVEL_COND=(); TRAVEL_DEST=(); TRAVEL_LAST=()

    for line in "${RAW_TRAVEL[@]}"; do
        # Default-IFS splitting covers the tabs; load_data already drops the
        # section terminator, so only real data lines should arrive here.
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 3 )) || continue
        src=${fields[0]}
        newloc=${fields[1]}
        [[ "$src" =~ ^[0-9]+$ && "$newloc" =~ ^[0-9]+$ ]] || continue
        # Skip LOC=0 lines (artifact from old format)
        (( src == 0 )) && continue
        # An empty motion list would make the "flag the last entry" step below
        # reach back into the *previous* location's run and corrupt it.
        [[ "${fields[2]}" =~ ^[0-9]+$ ]] && (( fields[2] != 0 )) || continue

        if (( ${KEY[$src]:-0} == 0 )); then
            KEY[$src]=$idx
        else
            # Un-flag the previous line's last entry. The flag
            # belongs to the final line of a contiguous run of lines sharing a
            # source room, and this toggling is how the Fortran gets there.
            TRAVEL[$((idx - 1))]=$(( -TRAVEL[idx - 1] ))
        fi

        for (( n = 2; n < ${#fields[@]} && n - 2 < TRAVEL_MAX_KEYWORDS; n++ )); do
            mot=${fields[$n]}
            (( mot == 0 )) && break   # Fortran stops the TK loop on the first 0

            TRAVEL[$idx]=$(( newloc * TRAVEL_SCALE + mot ))
            TRAVEL_SRC[$idx]=$src
            (( idx++ ))
        done

        # Provisionally this location's last entry; undone above if a further
        # line for the same source follows.
        TRAVEL[$((idx - 1))]=$(( -TRAVEL[idx - 1] ))
    done

    TRAVEL_COUNT=$(( idx - 1 ))
    if (( TRAVEL_COUNT >= TRAVEL_MAX_ENTRIES )); then
        bug 3
    fi

    # Second pass: a sign is only final once every line has been seen.
    for (( n = 1; n <= TRAVEL_COUNT; n++ )); do
        packed=${TRAVEL[$n]}
        if (( packed < 0 )); then
            TRAVEL_LAST[$n]=$TRUE
            packed=$(( -packed ))
        else
            TRAVEL_LAST[$n]=$FALSE
        fi
        TRAVEL_KEY[$n]=$(( packed % TRAVEL_SCALE ))
        newloc=$(( packed / TRAVEL_SCALE ))
        TRAVEL_NEWLOC[$n]=$newloc
        TRAVEL_COND[$n]=$(( newloc / 1000 ))
        TRAVEL_DEST[$n]=$(( newloc % 1000 ))
    done
}

# travel_cond_desc M
function travel_cond_desc() {
    local -i m=$1 k=$(( $1 % 100 ))

    if (( m == 0 )); then
        printf 'always'
    elif (( m < 100 )); then
        printf '%d%% of the time' "$m"
    elif (( m == 100 )); then
        printf 'always (dwarves barred)'
    elif (( m <= 200 )); then
        printf 'if carrying obj %d' "$k"
    elif (( m <= 300 )); then
        printf 'if carrying or with obj %d' "$k"
    else
        printf 'if prop[%d] != %d' "$k" "$(( m / 100 - 3 ))"
    fi
}

# travel_dest_desc N
function travel_dest_desc() {
    local -i n=$1

    # printf -- : the format strings below lead with "->", which printf would
    # otherwise try to read as an option.
    if (( n <= TRAVEL_DEST_MAX )); then
        printf -- '-> room %d' "$n"
    elif (( n <= TRAVEL_SPECIAL_MAX )); then
        printf -- '-> special %d' "$(( n - TRAVEL_SPECIAL_BASE ))"
    else
        printf 'say msg %d, stay' "$(( n - TRAVEL_MSG_BASE ))"
    fi
}

# dump_travel_table ROOM...
function dump_travel_table() {
    local room
    local -i i

    for room in "$@"; do
        i=${KEY[$room]:-0}
        if (( i == 0 )); then
            printf 'room %3d: no travel entries\n' "$room"
            continue
        fi
        printf 'room %3d: KEY=%d\n' "$room" "$i"
        while true; do
            printf '  [%3d] motion=%-4s%-6s newloc=%-7s %-30s %s\n' \
                "$i" "${TRAVEL_KEY[$i]}" \
                "$( (( TRAVEL_KEY[i] == TRAVEL_ANY )) && printf '(any)')" \
                "${TRAVEL_NEWLOC[$i]}" \
                "$(travel_cond_desc "${TRAVEL_COND[$i]}")" \
                "$(travel_dest_desc "${TRAVEL_DEST[$i]}")"
            (( TRAVEL_SRC[i] == room )) || printf \
                '  !! entry %d is sourced from room %d — section-3 lines for a room must be contiguous\n' \
                "$i" "${TRAVEL_SRC[$i]}" >&2
            (( TRAVEL_LAST[i] == TRUE )) && break
            (( i++ ))
        done
    done
    printf '%d travel entries total\n' "$TRAVEL_COUNT"
}

# ---------------------------------------------------------------------------
#  Output and randomness
# ---------------------------------------------------------------------------

# speak MSG_ID
function speak() {
    echo -e "${RAW_MSG[$1]:-}"
}

# mspeak ID
function mspeak() {
    local -i msg=$1
    (( msg != 0 )) && echo -e "${RAW_MAGIC[$msg]:-}"
}

# ran_gt PERCENT
function ran_gt() {
    (( RANDOM % 100 >= $1 ))
}

# ran N
function ran() {
    echo $(( RANDOM % $1 ))
}

# ---------------------------------------------------------------------------
#  Fatal errors (BUG)
# ---------------------------------------------------------------------------

# bug NUM
function bug() {
    local -i num=$1
    printf 'Fatal error, see source code for interpretation.\nProbable cause: erroneous info in database.\nError code = %d\n' \
        "$num" >&2
    exit 1
}

# ---------------------------------------------------------------------------
#  Movement
# ---------------------------------------------------------------------------

# Motion word IDs the travel dispatch singles out by name (data section 4).
declare -r MOT_FORWARD=7
declare -r MOT_BACK=8
declare -r MOT_OUT=11
declare -r MOT_CRAWL=17
declare -r MOT_IN=19
declare -r MOT_UP=29
declare -r MOT_DOWN=30
declare -r MOT_LEFT=36
declare -r MOT_RIGHT=37
declare -r MOT_EAST=43
declare -r MOT_COMPASS_MAX=50   # EAST..NW (43-50): 8 compass points
declare -r MOT_XYZZY=62
declare -r MOT_PLUGH=65
declare -r MOT_LOOK=57
declare -r MOT_CAVE=67

declare -r COND_FORCED=2
declare -r MOT_NULL=21
declare -r -i DARK_PIT_PCT=25
declare -r MAX_FORCED_MOVES=20

declare -i LOC=1
declare -i OLDLOC=1
declare -i OLDLC2=1

declare -i IDETAL=0
declare -i JVERB=0
declare -i IDARK=0
declare -i GAME_OVER=$FALSE
declare -i MOVE_RESULT=$FALSE
declare -i NEXT_LOC=1

# pct N
#   True N% of the time.
function pct() {
    (( RANDOM % 100 < $1 ))
}

# datime — must be called directly, not in $(...).
function datime() {
    if [[ -n "${ADVENTURE_FAKE_DATIME:-}" ]]; then
        # Parse first two fields (D T), ignore optional third (weekday override for update_day_class)
        local d t wday
        read -r d t wday <<< "$ADVENTURE_FAKE_DATIME"
        DATIME_D=$d
        DATIME_T=$t
    else
        DATIME_D=$(( $(date +%s) / 86400 ))
        local -i hours=$(date +%H)
        local -i minutes=$(date +%M)
        DATIME_T=$(( hours * 60 + minutes ))
    fi
}

# update_day_class
function update_day_class() {
    if [[ -n "${ADVENTURE_FAKE_DATIME:-}" ]]; then
        # Fake mode: try to extract optional third field (weekday override)
        local wday_field="${ADVENTURE_FAKE_DATIME##* }"
        if [[ "$wday_field" =~ ^[1-7]$ ]]; then
            # Explicit weekday provided
            DATIME_WDAY=${wday_field}
        else
            # No explicit weekday: derive from fake day count
            # Epoch 1970-01-01 was Thursday (4), so (day % 7) + 4 gives weekday
            DATIME_WDAY=$(( (DATIME_D % 7) + 4 ))
            (( DATIME_WDAY > 7 )) && (( DATIME_WDAY -= 7 ))
        fi
    else
        # Real mode: use date +%u (1=Mon..7=Sun)
        DATIME_WDAY=$(date +%u)
    fi

    # Set PRIMTM based on weekday, then check holiday override
    # Fortran: PRIMTM=WKDAY; IF(MOD(D,7).LE.1)PRIMTM=WKEND
    # In real calendar: 1=Mon, 2=Tue, ..., 6=Sat, 7=Sun
    if (( DATIME_WDAY == 6 || DATIME_WDAY == 7 )); then
        PRIMTM=$WKEND
    else
        PRIMTM=$WKDAY
    fi

    # Holiday override.
    if (( DATIME_D >= HBEGIN && DATIME_D <= HEND )); then
        PRIMTM=$HOLID
    fi
}

# refuse_motion MOTION_ID
function refuse_motion() {
    local -i k=$1
    local -i spk=12    # "I DON'T KNOW HOW TO APPLY THAT WORD HERE."

    (( k >= MOT_EAST && k <= MOT_COMPASS_MAX )) && spk=9   # 8 compass points
    (( k == MOT_UP || k == MOT_DOWN )) && spk=9
    (( k == MOT_FORWARD || k == MOT_LEFT || k == MOT_RIGHT )) && spk=10
    (( k == MOT_OUT || k == MOT_IN )) && spk=11
    (( JVERB == 1 )) && spk=59      # FIND/INVENTORY <direction>
    (( k == MOT_XYZZY || k == MOT_PLUGH )) && spk=42   # a magic word that
                                                         # does nothing here
    (( k == MOT_CRAWL )) && spk=80  # "WHICH WAY?"

    speak "$spk"
}

# arrive ROOM — must be called directly.
function arrive() {
    local -i j=$1

    # A hollow voice occasionally gives away PLUGH at Y2.
    (( j == 33 )) && ! ran_gt 25 && speak 8

    LOC=$j

    # ABB counts visits modulo 5, so the long description comes back round
    # every fifth time rather than never again.
    ABB[$j]=$(( (ABB[j] + 1) % 5 ))

    # An even COND means the room is unlit; if so and the lamp isn't here
    # and lit, set IDARK and warn about pits.
    IDARK=0
    if dark; then
        IDARK=1
        speak 16
    fi
}

# resolve_travel_special CODE — must be called directly, not in $(...).
function resolve_travel_special() {
    local -i code=$1

    if (( code == 1 )); then
        plover_alcove
        return
    fi

    if (( code == 2 )); then
        plover_transport
        return
    fi

    if (( code == 3 )); then
        troll_bridge
        return
    fi

    printf 'travel special %d not yet implemented\n' "$code" >&2
    NEXT_LOC=$LOC
}

# plover_alcove — must be called directly, not in $(...).
function plover_alcove() {
    if (( HOLDNG == 0 )) || { (( HOLDNG == 1 )) && toting "$EMRALD"; }; then
        NEXT_LOC=$(( 199 - LOC ))
    else
        speak 117
        NEXT_LOC=$LOC
    fi
}

# plover_transport — must be called directly, not in $(...).
function plover_transport() {
    drop "$EMRALD" "$LOC"
    # Stay at the same location; the move is still credited.
    NEXT_LOC=$LOC
    # Dispatch a null move next so the room reprints and dwarf/dark checks run.
    CMD_PENDING=1
    WORD1=$MOT_NULL
}

# troll_bridge — must be called directly, not in $(...).
function troll_bridge() {
    if (( PROP[TROLL] == 1 )); then
        pspeak "$TROLL" 1
        PROP[TROLL]=0
        move "$TROLL2" 0
        move $(( TROLL2 + 100 )) 0
        move "$TROLL" "${PLAC[TROLL]}"
        move $(( TROLL + 100 )) "${FIXD[TROLL]}"
        juggle "$CHASM"
        NEXT_LOC=$LOC
        return
    fi

    NEXT_LOC=$(( PLAC[TROLL] + FIXD[TROLL] - LOC ))
    (( PROP[TROLL] == 0 )) && PROP[TROLL]=1

    toting "$BEAR" || return

    speak 162
    PROP[CHASM]=1
    PROP[TROLL]=2
    drop "$BEAR" "$NEXT_LOC"
    IFIXED[BEAR]=-1
    PROP[BEAR]=3
    (( PROP[SPICES] < 0 )) && TALLY2=$(( TALLY2 + 1 ))
    OLDLC2=$NEXT_LOC
    handle_death
}

# resolve_travel_dest NEWLOC_FULL — must be called directly.
function resolve_travel_dest() {
    local -i n=$(( $1 % TRAVEL_SCALE ))

    if (( n <= TRAVEL_DEST_MAX )); then
        NEXT_LOC=$n
    elif (( n <= TRAVEL_SPECIAL_MAX )); then
        resolve_travel_special $(( n - TRAVEL_SPECIAL_BASE ))
    else
        speak $(( n - TRAVEL_MSG_BASE ))
        NEXT_LOC=$LOC
    fi
}

# travel_choose MOTION_ID — must be called directly, not in $(...).
function travel_choose() {
    local -i k=$1
    local -i kk mm obj_k prop_threshold newloc_full

    kk=${KEY[$LOC]:-0}
    if (( kk == 0 )); then
        # This port warns and stays put instead of exiting mid-playthrough.
        printf 'BUG(26): location %d has no travel entries\n' "$LOC" >&2
        NEXT_LOC=$LOC
        return
    fi

    if (( k == MOT_NULL )); then           # no motion at all
        NEXT_LOC=$LOC
        return
    fi
    if (( k == MOT_LOOK )); then
        (( IDETAL < 3 )) && speak 15
        (( IDETAL++ ))
        ABB[$LOC]=0
        NEXT_LOC=$LOC
        return
    fi
    if (( k == MOT_CAVE )); then
        if (( LOC < 8 )); then speak 57; else speak 58; fi
        NEXT_LOC=$LOC
        return
    fi

    if (( k == MOT_BACK )); then
        local -i target=$OLDLOC fallback_kk=0 lookkk lookdest j
        forced "$target" && target=$OLDLC2
        OLDLC2=$OLDLOC
        OLDLOC=$LOC

        if (( target == LOC )); then
            speak 91
            NEXT_LOC=$LOC
            return
        fi

        lookkk=$kk
        while true; do
            lookdest=${TRAVEL_DEST[$lookkk]}
            if (( lookdest == target )); then
                fallback_kk=$lookkk
                break                       # exact match, stop looking
            fi
            if (( lookdest <= TRAVEL_DEST_MAX )); then
                j=${KEY[$lookdest]:-0}
                if (( j != 0 )) && forced "$lookdest" \
                        && (( ${TRAVEL_DEST[$j]:-0} == target )); then
                    fallback_kk=$lookkk     # one-hop-through-a-forced-room match
                fi
            fi
            (( TRAVEL_LAST[$lookkk] == TRUE )) && break
            (( lookkk++ ))
        done

        if (( fallback_kk == 0 )); then
            speak 140
            NEXT_LOC=$LOC
            return
        fi

        # label 25: recover that entry's own motion word and re-dispatch
        # through the ordinary scan below using it, exactly as advent.for
        # falls through from label 25 back into label 9.
        k=${TRAVEL_KEY[$fallback_kk]}
        kk=${KEY[$LOC]}
    fi

    # label 9: scan this room's entries for one whose motion word matches (or
    # the TRAVEL_ANY wildcard), stopping at the entry flagged last.
    while true; do
        if (( TRAVEL_KEY[kk] == TRAVEL_ANY || TRAVEL_KEY[kk] == k )); then
            break
        fi
        if (( TRAVEL_LAST[kk] == TRUE )); then
            refuse_motion "$k"
            NEXT_LOC=$LOC
            return
        fi
        (( kk++ ))
    done

    OLDLC2=$OLDLOC
    OLDLOC=$LOC
    newloc_full=${TRAVEL_NEWLOC[$kk]}

    # Evaluate the M-condition gating this option; on failure, skip to the
    # next option (the next entry whose NEWLOC field differs).
    while true; do
        mm=$(( newloc_full / 1000 ))
        obj_k=$(( mm % 100 ))

        if (( mm > 300 )); then
            prop_threshold=$(( mm / 100 - 3 ))
            (( ${PROP[$obj_k]:-0} != prop_threshold )) && break
        elif (( mm > 100 )); then
            # TOTING(K), or — for M>200 — also AT(K): carried, or in the same
            # room as (or the fixed side of) a two-placed object.
            toting "$obj_k" && break
            (( mm > 200 )) && at "$obj_k" && break
        else
            (( mm == 0 )) && break          # unconditional
            pct "$mm" && break               # M<100: taken M% of the time
        fi                                  # M=100 unconditional-for-player
                                             # falls through pct 100, always true

        # Skip forward to the next entry with a different NEWLOC.
        while true; do
            if (( TRAVEL_LAST[kk] == TRUE )); then
                # This port warns and stays put instead of exiting mid-playthrough.
                printf 'BUG(25): location %d ran out of travel options\n' "$LOC" >&2
                NEXT_LOC=$LOC
                return
            fi
            (( kk++ ))
            if (( TRAVEL_NEWLOC[kk] != newloc_full )); then
                newloc_full=${TRAVEL_NEWLOC[$kk]}
                break
            fi
        done
    done

    resolve_travel_dest "$newloc_full"
}

# attempt_motion MOTION_ID — must be called directly, not in $(...).
function attempt_motion() {
    local -i k=$1
    local -i start=$LOC
    local -i steps=0

    # Dark pit check (outside loop so forced-move chains cost one draw).
    if (( IDARK != 0 )) && ! ran_gt "$DARK_PIT_PCT"; then
        fall_in_pit
        MOVE_RESULT=$FALSE
        return
    fi

    while (( steps++ < MAX_FORCED_MOVES )); do
        travel_choose "$k"

        # Travel special may kill player or trigger resurrection.
        if (( GAME_OVER == TRUE || RESURRECTED == TRUE )); then
            MOVE_RESULT=$FALSE
            return
        fi

        # While closing: only main office exits allowed; grace period on first attempt.
        if (( CLOSNG == TRUE && NEXT_LOC < 9 && NEXT_LOC != 0 )); then
            speak 130
            NEXT_LOC=$LOC
            (( PANIC == FALSE )) && CLOCK2=15
            PANIC=$TRUE
        fi

        # Dwarf blocks doorway (unless forced-room or pirate area).
        if (( NEXT_LOC != LOC )) && ! forced "$LOC" \
                && ! bitset "$LOC" $COND_NOPIRATE; then
            dwarf_blocks "$NEXT_LOC" && NEXT_LOC=$LOC
        fi

        LOC=$NEXT_LOC

        # Dwarves don't follow into pits, forced rooms, or pirate areas.
        if (( LOC != 0 )) && ! forced "$LOC" \
                && ! bitset "$LOC" $COND_NOPIRATE; then
            if ! dwarf_turn; then
                MOVE_RESULT=$FALSE
                return
            fi
        fi

        print_desc "$LOC"

        if ! forced "$LOC"; then
            arrive "$LOC"
            hint_check
            (( HINT_DUE != -1 )) && hint_offer
            MOVE_RESULT=$(( LOC == start ? FALSE : TRUE ))
            return
        fi

        k=$TRAVEL_ANY   # forced room re-enters with any verb
    done

    MOVE_RESULT=$(( LOC == start ? FALSE : TRUE ))
}

# walk_travel LOC MOTION...
function walk_travel() {
    LOC=$1; OLDLOC=$1; OLDLC2=$1
    shift

    printf 'start: room %d\n' "$LOC"
    local motion
    for motion in "$@"; do
        attempt_motion "$motion"
        printf '  motion %-4s -> room %d\n' "$motion" "$LOC"
    done
}

# ---------------------------------------------------------------------------
#  Predicates
# ---------------------------------------------------------------------------

declare -r -i BOTTLE=20
declare -r -i OIL=22

# toting OBJ
#   True if OBJ is carried.
function toting() {
    local -i obj=$1
    (( IPLACE[obj] == -1 ))
}

# at OBJ
function at() {
    local -i obj=$1
    (( IPLACE[obj] == LOC || IFIXED[obj] == LOC ))
}

# bitset LOC N
function bitset() {
    local -i loc=$1 n=$2
    (( (COND[loc] >> n) & 1 ))
}

# forced LOC
function forced() {
    local -i loc=$1
    (( COND[loc] == COND_FORCED ))
}

# dark (tests the current room)
function dark() {
    (( COND[LOC] % 2 != 0 )) && return $FALSE
    (( PROP[LAMP] == 0 )) && return $TRUE
    object_here "$LAMP" && return $FALSE
    return $TRUE
}

# liq2 PBOTL
function liq2() {
    local -i pbotl=$1
    echo $(( (1 - pbotl) * WATER + (pbotl / 2) * (WATER + OIL) ))
}

# liq (no args)
function liq() {
    local -i p=${PROP[BOTTLE]:-0}
    local -i pbotl=$(( p > (-1 - p) ? p : (-1 - p) ))
    liq2 "$pbotl"
}

# liqloc LOC
function liqloc() {
    local -i loc=$1
    local -i c=${COND[loc]:-0}
    local -i masked=$(( (c / 2 * 2) % 8 ))
    local -i bit2=$(( (c / 4) % 2 ))
    local -i arg=$(( (masked - 5) * bit2 + 1 ))
    liq2 "$arg"
}

# ---------------------------------------------------------------------------
#  Vocabulary — 350-point word classes & treasures (section 4)
# ---------------------------------------------------------------------------

# A section-4 vocab ID N packs a word class into M=N/1000:
#   0  motion word   (N<1000)       — section 3's travel-table keywords
#   1  object/noun   (1000<=N<2000) — object number = N-1000
#   2  action verb   (2000<=N<3000) — e.g. TAKE, DROP, ATTACK
#   3  special verb  (N>=3000)      — N MOD 1000 indexes a section-6 message
declare -r -i VOCAB_CLASS_SCALE=1000
declare -r -i VOCAB_CLASS_MOTION=0
declare -r -i VOCAB_CLASS_OBJECT=1
declare -r -i VOCAB_CLASS_VERB=2
declare -r -i VOCAB_CLASS_SPECIAL=3

# vocab_class ID
function vocab_class() {
    echo $(( $1 / VOCAB_CLASS_SCALE ))
}

declare -r -i TREASURE_MIN=50
declare -r -i TREASURE_MAX=79

declare -i TALLY=0

# is_treasure OBJ
function is_treasure() {
    local -i obj=$1
    (( obj >= TREASURE_MIN && obj <= TREASURE_MAX ))
}

# get_vocab_id WORD
function get_vocab_id() {
    local w=$1
    # Check words up to 5 chars (Fortran limit)
    local trunc_w="${w:0:5}"
    for i in "${!VOCAB_WORD[@]}"; do
        if [[ "${VOCAB_WORD[$i]}" == "$trunc_w" || "${VOCAB_WORD[$i]}" == "$w" ]]; then
            echo "${VOCAB_ID[$i]}"
            return
        fi
    done
    echo "-1"
}

# get_vocab_id_class WORD CLASS
function get_vocab_id_class() {
    local w=$1
    local -i want_class=$2
    local trunc_w="${w:0:5}"
    local -i i
    for i in "${!VOCAB_WORD[@]}"; do
        if [[ "${VOCAB_WORD[$i]}" == "$trunc_w" || "${VOCAB_WORD[$i]}" == "$w" ]]; then
            if (( VOCAB_ID[i] / VOCAB_CLASS_SCALE == want_class )); then
                echo $(( VOCAB_ID[i] % VOCAB_CLASS_SCALE ))
                return
            fi
        fi
    done
    echo "-1"
}

# dump_vocab WORD...
function dump_vocab() {
    local w
    local -i id cls obj

    for w in "$@"; do
        id=$(get_vocab_id "$w")
        if (( id == -1 )); then
            printf '%-6s -1 (not found)\n' "$w"
            continue
        fi
        cls=$(vocab_class "$id")
        case "$cls" in
            "$VOCAB_CLASS_MOTION") printf '%-6s id=%-5d motion\n' "$w" "$id" ;;
            "$VOCAB_CLASS_OBJECT")
                obj=$(( id - VOCAB_CLASS_OBJECT * VOCAB_CLASS_SCALE ))
                printf '%-6s id=%-5d object obj=%-3d%s\n' "$w" "$id" "$obj" \
                    "$(is_treasure "$obj" && printf ' (treasure)')"
                ;;
            "$VOCAB_CLASS_VERB") printf '%-6s id=%-5d action verb\n' "$w" "$id" ;;
            "$VOCAB_CLASS_SPECIAL")
                printf '%-6s id=%-5d special verb msg=%-3d\n' "$w" "$id" \
                    "$(( id % VOCAB_CLASS_SCALE ))"
                ;;
            *) printf '%-6s id=%-5d unknown class %d\n' "$w" "$id" "$cls" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
#  Two-word command read
# ---------------------------------------------------------------------------

declare WORD1="" WORD1X="" WORD2="" WORD2X=""

declare -i GETIN_EOF=$FALSE

declare -i YES_RESULT=$FALSE

# getin — must be called directly, not in $(...).
function getin() {
    local line w1 w2

    GETIN_EOF=$FALSE
    while true; do
        if ! read -r -p "> " line; then
            GETIN_EOF=$TRUE
            WORD1="" WORD1X="" WORD2="" WORD2X=""
            return
        fi
        line=$(echo "$line" | tr '[:lower:]' '[:upper:]')
        w1="" w2=""
        read -r w1 w2 <<< "$line"
        [[ -n "$w1" || -n "$w2" ]] && break
    done

    WORD1="${w1:0:5}"
    WORD1X="${w1:5:5}"
    WORD2="${w2:0:5}"
    WORD2X="${w2:5:5}"
}

# yesx MSG_X MSG_Y MSG_Z SPEAK_FN — must be called directly, not in $(...).
function yesx() {
    local -i msg_x=$1 msg_y=$2 msg_z=$3
    local speak_fn=$4

    while true; do
        (( msg_x != 0 )) && "$speak_fn" "$msg_x"
        getin
        if (( GETIN_EOF == TRUE )); then
            YES_RESULT=$FALSE
            return
        fi
        case "$WORD1" in
            YES|Y) YES_RESULT=$TRUE; break ;;
            NO|N) YES_RESULT=$FALSE; break ;;
            *) printf "$(format_case '\n Please answer the question.\n')" ;;
        esac
    done

    if (( YES_RESULT == TRUE )); then
        (( msg_y != 0 )) && "$speak_fn" "$msg_y"
    else
        (( msg_z != 0 )) && "$speak_fn" "$msg_z"
    fi
}

# yes MSG_X MSG_Y MSG_Z
#   yesx() through section-6 messages. Sets YES_RESULT — must be called
#   directly, not in $(...).
function yes() {
    yesx "$1" "$2" "$3" speak
}

# yesm MSG_X MSG_Y MSG_Z
#   yesx() through section-12 messages, used by wizard-mode prompts. Sets
#   YES_RESULT — must be called directly, not in $(...).
function yesm() {
    yesx "$1" "$2" "$3" mspeak
}

# a5toa1 WORD WORDX SUFFIX
function a5toa1() {
    local word="${1}${2}"
    local suffix=$3

    if [[ -z "$suffix" ]]; then
        echo "$word"
    elif [[ "$suffix" =~ ^[A-Za-z0-9] ]]; then
        echo "$word $suffix"
    else
        echo "$word$suffix"
    fi
}

# parse_command
function parse_command() {
    local -i id1=-1
    local -i id2=-1

    [[ -n "$WORD1" ]] && id1=$(get_vocab_id "$WORD1")
    [[ -n "$WORD2" ]] && id2=$(get_vocab_id "$WORD2")

    echo "$id1 $id2"
}

# ---------------------------------------------------------------------------
#  Dwarves
# ---------------------------------------------------------------------------

declare -r -i MAX_DWARVES=5
declare -r -i PIRATE=6

declare -a DLOC ODLOC DSEEN

declare -r -i CHLOC=114
declare -r -i CHLOC2=140
declare -r -a DSTART=(0 19 27 33 44 64 "$CHLOC")

declare -r -i DALTLC=18
declare -r -i DWARF_HALL=15
declare -r -i DWARF_SKIP_PCT=95
declare -r -i DWARF_CULL_PCT=50
declare -r -i DWARF_KNIFE_PER_MILLE=95
declare -r -i DWARF_MAX_CHOICES=20
declare -r -i TRAVEL_COND_NODWARF=100
declare -r -i COND_NOPIRATE=3

# dwarf_blocks DEST
function dwarf_blocks() {
    local -i dest=$1
    local -i i

    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        if (( ODLOC[i] == dest && DSEEN[i] != 0 )); then
            speak 2
            return $TRUE
        fi
    done

    return $FALSE
}

# dwarf_step I
#   One dwarf's random move from DLOC(I); backtracks to ODLOC(I) if no valid moves.
#   Mutates DLOC/ODLOC — call directly, not in $(...).
function dwarf_step() {
    local -i i=$1
    local -i j=1 kk newloc ok
    local -a tk=()

    kk=${KEY[${DLOC[$i]}]:-0}
    while (( kk != 0 )); do
        newloc=${TRAVEL_DEST[$kk]}

        ok=$TRUE
        (( newloc > TRAVEL_DEST_MAX )) && ok=$FALSE     # not a room at all
        (( newloc < DWARF_HALL )) && ok=$FALSE          # never above the Mists
        (( newloc == ODLOC[i] )) && ok=$FALSE           # no backtracking
        (( newloc == DLOC[i] )) && ok=$FALSE            # no standing still
        (( j > 1 && newloc == tk[j - 1] )) && ok=$FALSE # no duplicate of the
                                                        # entry just accepted
        (( j >= DWARF_MAX_CHOICES )) && ok=$FALSE       # TK(20) is full
        (( TRAVEL_COND[kk] == TRAVEL_COND_NODWARF )) && ok=$FALSE
        forced "$newloc" && ok=$FALSE
        (( i == PIRATE )) && bitset "$newloc" $COND_NOPIRATE && ok=$FALSE

        if (( ok == TRUE )); then
            tk[j]=$newloc
            (( j++ ))
        fi

        (( TRAVEL_LAST[kk] == TRUE )) && break
        (( kk++ ))
    done

    # TK(J), the slot past the accepted candidates, is the retreat.
    # Decrementing J when anything was accepted excludes it from the draw;
    # with nothing accepted J stays 1 and the draw can only pick it.
    tk[j]=${ODLOC[$i]}
    (( j >= 2 )) && (( j-- ))
    j=$(( 1 + $(ran $j) ))
    ODLOC[i]=${DLOC[$i]}
    DLOC[i]=${tk[$j]}
}

# pirate_spotted_player — must be called directly, not in $(...).
function pirate_spotted_player() {
    local -i j k=0 stole=$FALSE

    (( CROWTHER_MODE == TRUE )) && return
    (( LOC == CHLOC || PROP[CHEST] >= 0 )) && return

    for (( j = TREASURE_MIN; j <= TREASURE_MAX; j++ )); do
        (( j == PYRAM && ( LOC == ${PLAC[PYRAM]:-0} \
                           || LOC == ${PLAC[EMRALD]:-0} ) )) && continue
        if toting "$j"; then
            stole=$TRUE
            break
        fi
        object_here "$j" && k=1
    done

    if (( stole == TRUE )); then
        speak 128
        (( IPLACE[MESSAG] == 0 )) && move "$CHEST" "$CHLOC"
        move "$MESSAG" "$CHLOC2"

        for (( j = TREASURE_MIN; j <= TREASURE_MAX; j++ )); do
            (( j == PYRAM && ( LOC == ${PLAC[PYRAM]:-0} \
                               || LOC == ${PLAC[EMRALD]:-0} ) )) && continue
            at "$j" && (( IFIXED[j] == 0 )) && carry "$j" "$LOC"
            toting "$j" && drop "$j" "$CHLOC"
        done

        pirate_vanish
        return
    fi

    if (( TALLY == TALLY2 + 1 && k == 0 && IPLACE[CHEST] == 0 )) \
            && object_here "$LAMP" && (( PROP[LAMP] == 1 )); then
        speak 186
        move "$CHEST" "$CHLOC"
        move "$MESSAG" "$CHLOC2"
        pirate_vanish
        return
    fi

    # No tease on a turn he was already standing here.
    (( ODLOC[PIRATE] != DLOC[PIRATE] )) && pct 20 && speak 127
}

# pirate_vanish — must be called directly, not in $(...).
function pirate_vanish() {
    DLOC[PIRATE]=$CHLOC
    ODLOC[PIRATE]=$CHLOC
    DSEEN[PIRATE]=0
}

# dwarf_turn
#   Dwarves: dormant until hall-of-mists (DFLAG=0), armed-encounter on 5% draw (DFLAG=1),
#   then real AI with random moves and knife throws (DFLAG=2+). Returns non-zero if knife kills.
#   Mutates DFLAG/DLOC/ODLOC/DSEEN/KNFLOC/OLDLC2 — must be called directly, not in $(...).
function dwarf_turn() {
    local -i i k
    local -i dtot=0 attack=0 stick=0

    if (( DFLAG == 0 )); then
        (( LOC >= DWARF_HALL )) && DFLAG=1
        return $TRUE
    fi

    if (( DFLAG == 1 )); then
        (( LOC < DWARF_HALL )) && return $TRUE
        pct $DWARF_SKIP_PCT && return $TRUE
        DFLAG=2

        # The draw for which dwarf happens before the draw for whether he
        # dies, so a wasted roll still consumes a dwarf number.
        for (( i = 1; i <= 2; i++ )); do
            k=$(( 1 + $(ran $MAX_DWARVES) ))
            pct $DWARF_CULL_PCT && DLOC[k]=0
        done

        # Nobody gets to start the fight standing on the player.
        for (( i = 1; i <= MAX_DWARVES; i++ )); do
            (( DLOC[i] == LOC )) && DLOC[i]=$DALTLC
            ODLOC[i]=${DLOC[$i]}
        done

        speak 3
        drop "$AXE" "$LOC"
        return $TRUE
    fi

    # Things are in full swing.
    for (( i = 1; i <= PIRATE; i++ )); do
        (( DLOC[i] == 0 )) && continue                  # dead dwarves don't do much

        dwarf_step "$i"

        if (( ( DSEEN[i] != 0 && LOC >= DWARF_HALL )
              || DLOC[i] == LOC || ODLOC[i] == LOC )); then
            DSEEN[i]=1
        else
            DSEEN[i]=0
            continue
        fi
        DLOC[i]=$LOC

        if (( i == PIRATE )); then
            pirate_spotted_player
            continue
        fi

        (( dtot++ ))
        # Only a dwarf that was already here last turn gets to throw.
        (( ODLOC[i] != DLOC[i] )) && continue
        (( attack++ ))
        (( KNFLOC >= 0 )) && KNFLOC=$LOC
        (( $(ran 1000) < DWARF_KNIFE_PER_MILLE * (DFLAG - 2) )) && (( stick++ ))
    done

    (( dtot == 0 )) && return $TRUE

    if (( dtot == 1 )); then
        speak 4
    else
        # This message isn't in the data (the original TYPEs it inline), so
        # it's spelled out here in mixed case, matching the original's format.
        printf "$(format_case ' THERE ARE %d THREATENING LITTLE DWARVES IN THE ROOM WITH YOU.\n\n')" "$dtot"
    fi

    (( attack == 0 )) && return $TRUE
    (( DFLAG == 2 )) && DFLAG=3                         # they warm up

    if (( attack == 1 )); then
        speak 5
        k=52                        # 52 "IT MISSES!" / 53 "IT GETS YOU!"
    else
        printf "$(format_case ' %d OF THEM THROW KNIVES AT YOU!\n\n')" "$attack"
        k=6                         # 6 "NONE OF THEM HIT YOU!" / 7 "ONE ... GETS YOU!"
    fi

    if (( stick <= 1 )); then
        speak $(( k + stick ))
        (( stick == 0 )) && return $TRUE
    else
        printf "$(format_case ' %d OF THEM GET YOU!\n\n')" "$stick"
    fi

    # OLDLC2 is set before the death jump so resurrection has somewhere to
    # put the player's dropped belongings; handle_death decides whether
    # this is a real end or a rebirth.
    OLDLC2=$LOC
    handle_death
    return $FALSE
}

# ---------------------------------------------------------------------------
#  Canonical object mutation subroutines
# ---------------------------------------------------------------------------

# carry OBJ WHERE — must be called directly, not in $(...).
function carry() {
    local -i obj=$1 where=$2
    local -i temp

    if (( obj <= 100 )); then
        if (( IPLACE[obj] == -1 )); then
            return
        fi
        IPLACE[obj]=-1
        (( HOLDNG++ ))
    fi

    if (( IOBJ[where] == obj )); then
        IOBJ[where]=${ICHAIN[obj]}
        return
    fi

    temp=${IOBJ[where]}
    while (( ICHAIN[temp] != obj )); do
        temp=${ICHAIN[temp]}
    done
    ICHAIN[temp]=${ICHAIN[obj]}
}

# drop OBJ WHERE — must be called directly.
function drop() {
    local -i obj=$1 where=$2

    if (( obj > 100 )); then
        IFIXED[obj-100]=$where
    else
        if (( IPLACE[obj] == -1 )); then
            (( HOLDNG-- ))
        fi
        IPLACE[obj]=$where
    fi

    if (( where <= 0 )); then
        return
    fi

    ICHAIN[obj]=${IOBJ[where]}
    IOBJ[where]=$obj
}

# move OBJ WHERE — must be called directly.
function move() {
    local -i obj=$1 where=$2
    local -i from

    if (( obj > 100 )); then
        from=${IFIXED[obj-100]}
    else
        from=${IPLACE[obj]}
    fi

    if (( from > 0 && from <= 300 )); then
        carry "$obj" "$from"
    fi

    drop "$obj" "$where"
}

# juggle OBJ — must be called directly.
function juggle() {
    local -i obj=$1

    move "$obj" "${IPLACE[obj]}"
    move $((obj + 100)) "${IFIXED[obj]}"
}

# dstroy OBJ
#   Permanently destroy an object by moving it to location 0 (non-existent).
#   Must be called directly — mutates via move().
function dstroy() {
    local -i obj=$1
    move "$obj" 0
}

# ---------------------------------------------------------------------------
#  Object interaction (verbs)
# ---------------------------------------------------------------------------

# object_here OBJ
function object_here() {
    local -i obj=$1

    if (( IPLACE[obj] == LOC )) || toting "$obj"; then
        return $TRUE
    fi

    if (( obj == WATER || obj == OIL )); then
        (( $(liq) == obj )) && object_here "$BOTTLE" && return $TRUE
        (( $(liqloc "$LOC") == obj )) && return $TRUE
    fi

    return $FALSE
}

# do_take OBJ
#   Handle TAKE (redirects WATER/OIL to bottle, bird needs cage, etc.).
#   Mutates IPLACE/IOBJ/ICHAIN/HOLDNG/PROP — must be called directly, not in $(...).
function do_take() {
    local -i obj=$1

    if (( obj == KNIFE )); then
        speak 54
        return
    fi

    if toting "$obj"; then
        speak "${JSPKT[1]}"
        return
    fi

    local -i spk=25
    (( obj == PLANT && PROP[PLANT] <= 0 )) && spk=115
    (( obj == BEAR && PROP[BEAR] == 1 )) && spk=169
    (( obj == CHAIN && PROP[BEAR] != 0 )) && spk=170

    if (( IFIXED[obj] != 0 )); then
        speak "$spk"
        return
    fi

    if (( obj == WATER || obj == OIL )); then
        if object_here "$BOTTLE" && (( $(liq) == obj )); then
            obj=$BOTTLE
        else
            obj=$BOTTLE
            if toting "$BOTTLE" && (( PROP[BOTTLE] == 1 )); then
                do_fill "$BOTTLE"
                return
            fi
            (( PROP[BOTTLE] != 1 )) && spk=105   # "YOUR BOTTLE IS ALREADY FULL."
            toting "$BOTTLE" || spk=104            # "YOU HAVE NOTHING IN WHICH TO CARRY IT."
            speak "$spk"
            return
        fi
    fi

    if (( HOLDNG >= 7 )); then
        speak 92
        return
    fi

    if (( obj == BIRD && PROP[BIRD] == 0 )); then
        if toting "$ROD"; then
            speak 26
            return
        fi
        if ! toting "$CAGE"; then
            speak 27
            return
        fi
        PROP[BIRD]=1
    fi

    if (( (obj == BIRD || obj == CAGE) && PROP[BIRD] != 0 )); then
        carry $(( BIRD + CAGE - obj )) "$LOC"
    fi
    carry "$obj" "$LOC"

    local -i k
    k=$(liq)
    (( obj == BOTTLE && k != 0 )) && IPLACE[k]=-1

    speak 54
}

# do_drop OBJ
#   Handle DROP (bird on snake destroys it, coins at vending machine, etc.).
#   Mutates IPLACE/IOBJ/ICHAIN/HOLDNG/PROP — must be called directly, not in $(...).
function do_drop() {
    local -i obj=$1

    if (( obj == KNIFE )); then
        speak 54
        return
    fi

    if ! toting "$obj"; then
        speak "${JSPKT[2]}"
        return
    fi

    if (( obj == BIRD )) && object_here "$SNAKE"; then
        speak 30
        dstroy "$SNAKE"
        PROP[SNAKE]=1

    elif (( obj == COINS )) && object_here "$VEND"; then
        dstroy "$COINS"
        drop "$BATTER" "$LOC"
        pspeak "$BATTER" 0
        return

    elif (( obj == BIRD )) && at "$DRAGON" && (( PROP[DRAGON] == 0 )); then
        speak 154
        dstroy "$BIRD"
        PROP[BIRD]=0
        (( IPLACE[SNAKE] == ${PLAC[SNAKE]:-0} )) && TALLY2=$(( TALLY2 + 1 ))
        return

    elif (( obj == BEAR )) && at "$TROLL"; then
        speak 163
        banish_troll 2

    elif (( obj == VASE && LOC != ${PLAC[PILLOW]:-0} )); then
        PROP[VASE]=2
        at "$PILLOW" && PROP[VASE]=0
        pspeak "$VASE" "$(( PROP[VASE] + 1 ))"
        (( PROP[VASE] != 0 )) && IFIXED[VASE]=-1

    else
        speak 54
    fi

    local -i k
    k=$(liq)
    (( k == obj )) && obj=$BOTTLE
    (( obj == BOTTLE && k != 0 )) && IPLACE[k]=0
    (( obj == CAGE && PROP[BIRD] != 0 )) && drop "$BIRD" "$LOC"
    (( obj == BIRD )) && PROP[BIRD]=0

    drop "$obj" "$LOC"
}

# Object identity constants for the lock/unlock cluster. GRATE/CAGE/KEYS/
# CHAIN/BEAR are already declared above.
declare -r -i CLAM=14
declare -r -i OYSTER=15
declare -r -i TRIDNT=57
declare -r -i PEARL=61
declare -r -i TABLET=13   # stone tablet
declare -r -i MAGZIN=16   # magazine in dwarvish
declare -r -i MIRROR=23   # mirror
declare -r -i MESSAG=36   # message scrawled in dust

# lock_unlock OBJ IS_LOCK
#   Handle LOCK/UNLOCK (bare => guess object; CLAM/OYSTER special; CHAIN/GRATE routed).
#   Mutates PROP/IFIXED — must be called directly, not in $(...).
function lock_unlock() {
    local -i obj=$1 is_lock=$2

    if (( obj == 0 )); then
        object_here "$CLAM" && obj=$CLAM
        object_here "$OYSTER" && obj=$OYSTER
        at "$DOOR" && obj=$DOOR
        at "$GRATE" && obj=$GRATE

        if (( obj != 0 )) && object_here "$CHAIN"; then
            printf '\n %s\n' "$(a5toa1 "$WORD1" "$WORD1X" 'What?')"
            return
        fi

        object_here "$CHAIN" && obj=$CHAIN

        if (( obj == 0 )); then
            speak 28
            return
        fi
    fi

    if (( obj == CLAM || obj == OYSTER )); then
        lock_unlock_clam_oyster "$obj" "$is_lock"
        return
    fi

    local -i spk=33   # ACTSPK[4]/ACTSPK[6] default

    if (( obj == DOOR )); then
        spk=111
        (( PROP[DOOR] == 1 )) && spk=54
    elif (( obj == CAGE )); then
        spk=32
    elif (( obj == KEYS )); then
        spk=55
    elif (( obj == GRATE || obj == CHAIN )); then
        spk=31
    fi

    if (( spk != 31 )) || ! object_here "$KEYS"; then
        speak "$spk"
        return
    fi

    if (( obj == CHAIN )); then
        lock_unlock_chain "$is_lock"
        return
    fi

    local -i k=$(( 34 + PROP[GRATE] ))
    PROP[GRATE]=1
    (( is_lock == TRUE )) && PROP[GRATE]=0
    k=$(( k + 2 * PROP[GRATE] ))
    speak "$k"
}

# lock_unlock_clam_oyster OBJ IS_LOCK
#   UNLOCK clam (needs trident) => reveals oyster, drop pearl. Mutates IOBJ/ICHAIN/IPLACE/IFIXED.
#   Call directly, not in $(...).
function lock_unlock_clam_oyster() {
    local -i obj=$1 is_lock=$2
    local -i k=0 spk

    (( obj == OYSTER )) && k=1
    spk=$(( 124 + k ))
    toting "$obj" && spk=$(( 120 + k ))
    ! toting "$TRIDNT" && spk=$(( 122 + k ))
    (( is_lock == TRUE )) && spk=61

    if (( spk == 124 )); then
        dstroy "$CLAM"
        drop "$OYSTER" "$LOC"
        drop "$PEARL" 105
    fi

    speak "$spk"
}

# lock_unlock_chain IS_LOCK
#   Unlock chain (frees bear) or lock it (must be at its starting location).
#   Mutates PROP/IFIXED/IOBJ/ICHAIN/IPLACE — must be called directly, not in $(...).
function lock_unlock_chain() {
    local -i is_lock=$1
    local -i spk

    if (( is_lock == TRUE )); then
        spk=172
        (( PROP[CHAIN] != 0 )) && spk=34
        (( LOC != PLAC[CHAIN] )) && spk=173
        if (( spk == 172 )); then
            PROP[CHAIN]=2
            toting "$CHAIN" && drop "$CHAIN" "$LOC"
            IFIXED[CHAIN]=-1
        fi
        speak "$spk"
        return
    fi

    spk=171
    (( PROP[BEAR] == 0 )) && spk=41
    (( PROP[CHAIN] == 0 )) && spk=37
    if (( spk == 171 )); then
        PROP[CHAIN]=0
        IFIXED[CHAIN]=0
        (( PROP[BEAR] != 3 )) && PROP[BEAR]=2
        IFIXED[BEAR]=$(( 2 - PROP[BEAR] ))
    fi
    speak "$spk"
}

# do_lock OBJ — must be called directly, not in $(...).
function do_lock() {
    lock_unlock "$1" "$TRUE"
}

# do_unlock OBJ — must be called directly, not in $(...).
function do_unlock() {
    lock_unlock "$1" "$FALSE"
}

# do_light OBJ
#   Handle LIGHT/ON (lamp must be present, fuel must remain). Sets PROP/IDARK.
#   Mutates PROP/IDARK — must be called directly, not in $(...).
function do_light() {
    local -i obj=$1

    if (( IPLACE[LAMP] != LOC && IPLACE[LAMP] != -1 )); then
        speak 38
        return
    fi

    if (( LIMIT < 0 )); then
        speak 184
        return
    fi

    PROP[LAMP]=1
    IDARK=0
    speak 39
}

# do_extinguish OBJ — must be called directly, not in $(...).
function do_extinguish() {
    local -i obj=$1

    if (( IPLACE[LAMP] != LOC && IPLACE[LAMP] != -1 )); then
        speak 38
        return
    fi

    PROP[LAMP]=0
    speak 40
    if dark 0; then
        speak 16
    fi
}

# do_strike OBJ
#   Handle WAVE/SWING (rod at fissure toggles bridge span). ROD/ROD2 functionally equivalent.
#   Mutates PROP — must be called directly, not in $(...).
function do_strike() {
    local -i obj=$1
    local -i spk=42   # ACTSPK[9]

    if ! toting "$obj" && { (( obj != ROD )) || ! toting "$ROD2"; }; then
        spk=29
    fi

    if (( obj != ROD )) || ! at "$FISSUR" || ! toting "$obj"; then
        speak "$spk"
        return
    fi

    PROP[FISSUR]=$(( 1 - PROP[FISSUR] ))
    pspeak "$FISSUR" "$(( 2 - PROP[FISSUR] ))"
}

# ---------------------------------------------------------------------------
#  Creature combat — ATTACK/THROW and the dwarf/dragon/bear/troll
# ---------------------------------------------------------------------------

declare -r -i DWARF=17
declare -r -i DRAGON=31
declare -r -i CHASM=32
declare -r -i TROLL=33
declare -r -i TROLL2=34
declare -r -i EGGS=56
declare -r -i RUG=62
declare -r -i SPICES=63

declare -r -i VERB_KILL=12
declare -r -i VERB_THROW=17
declare -r -i VERB_FIND=19

declare -i DKILL=0
declare -i TALLY2=0
declare -i CMD_PENDING=$FALSE

# dwarf_here — must be called directly, not in $(...).
declare -i DWARF_INDEX=0
function dwarf_here() {
    local -i i

    DWARF_INDEX=0
    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        if (( DLOC[i] == LOC && DFLAG >= 2 )); then
            DWARF_INDEX=$i
            return $TRUE
        fi
    done

    return $FALSE
}

# noun_present OBJ
function noun_present() {
    local -i obj=$1

    (( IFIXED[obj] == LOC )) && return $TRUE
    object_here "$obj" && return $TRUE
    (( obj == DWARF )) && dwarf_here && return $TRUE

    return $FALSE
}

# ask_what
function ask_what() {
    printf '\n %s\n' "$(a5toa1 "$WORD1" "$WORD1X" 'What?')"
}

# do_attack OBJ [VERB] — must be called directly, not in $(...).
function do_attack() {
    local -i obj=$1
    local -i verb=${2:-$VERB_KILL}
    local -i spk=${ACTSPK[$verb]:-110}
    local -i i k

    dwarf_here                                        # sets DWARF_INDEX

    if (( obj == 0 )); then
        (( DWARF_INDEX != 0 )) && obj=$DWARF
        object_here "$SNAKE" && obj=$(( obj * 100 + SNAKE ))
        if at "$DRAGON" && (( PROP[DRAGON] == 0 )); then
            obj=$(( obj * 100 + DRAGON ))
        fi
        at "$TROLL" && obj=$(( obj * 100 + TROLL ))
        if object_here "$BEAR" && (( PROP[BEAR] == 0 )); then
            obj=$(( obj * 100 + BEAR ))
        fi

        if (( obj > 100 )); then                      # two enemies: ambiguous
            ask_what
            return
        fi

        if (( obj == 0 )); then
            if (( verb != VERB_THROW )) && object_here "$BIRD"; then
                obj=$BIRD
            fi
            if object_here "$CLAM" || object_here "$OYSTER"; then
                obj=$(( 100 * obj + CLAM ))
            fi
            if (( obj > 100 )); then                  # bird *and* clam
                ask_what
                return
            fi
        fi
    fi

    if (( obj == BIRD )); then
        spk=137
        dstroy "$BIRD"
        PROP[BIRD]=0
        (( IPLACE[SNAKE] == ${PLAC[SNAKE]:-0} )) && TALLY2=$(( TALLY2 + 1 ))
        spk=45
    fi

    # Message ladder; later assignments win, so the order is load-bearing.
    (( obj == 0 )) && spk=44
    (( obj == CLAM || obj == OYSTER )) && spk=150
    (( obj == SNAKE )) && spk=46
    (( obj == DWARF )) && spk=49
    (( obj == DRAGON )) && spk=167
    (( obj == TROLL )) && spk=157
    (( obj == BEAR )) && spk=$(( 165 + (PROP[BEAR] + 1) / 2 ))

    if (( obj != DRAGON || PROP[DRAGON] != 0 )); then
        speak "$spk"
        return
    fi

    speak 49
    getin
    (( GETIN_EOF == TRUE )) && return
    if [[ "$WORD1" != "Y" && "$WORD1" != "YES" ]]; then
        # Not a yes: the word just read is the next command (GOTO 2608).
        CMD_PENDING=$TRUE
        return
    fi

    pspeak "$DRAGON" 1
    PROP[DRAGON]=2
    PROP[RUG]=0
    k=$(( (PLAC[DRAGON] + FIXD[DRAGON]) / 2 ))
    move $(( DRAGON + 100 )) -1     # dragon stays fixed, but nowhere in a chain
    move $(( RUG + 100 )) 0         # the rug is now takeable
    move "$DRAGON" "$k"
    move "$RUG" "$k"
    # Everything in either of the dragon's two rooms follows it to the middle
    # one, so the room the player is standing in keeps its contents.
    for (( i = 1; i <= 100; i++ )); do
        if (( IPLACE[i] == PLAC[DRAGON] || IPLACE[i] == FIXD[DRAGON] )); then
            move "$i" "$k"
        fi
    done
    LOC=$k
    attempt_motion "$MOT_NULL"
}

# feed_bear
#   Tame wild bear by feeding food; frees axe if lost to bear. Mutates PROP/IFIXED.
#   Call directly, not in $(...).
function feed_bear() {
    local -i spk=${ACTSPK[21]:-174}   # FEED's own default, "I'M GAME..."

    (( PROP[BEAR] == 0 )) && spk=102
    (( PROP[BEAR] == 3 )) && spk=110

    if ! object_here "$FOOD"; then
        speak "$spk"
        return
    fi

    dstroy "$FOOD"
    PROP[BEAR]=1
    IFIXED[AXE]=0
    PROP[AXE]=0
    speak 168
}

# banish_troll PROP_AFTER
#   Troll vanishes (paid off by treasure or crushed by bear), TROLL2 replaces it.
#   Mutates IPLACE/IFIXED/IOBJ/ICHAIN/PROP — call directly, not in $(...).
function banish_troll() {
    local -i prop_after=$1

    move "$TROLL" 0
    move $(( TROLL + 100 )) 0
    move "$TROLL2" "${PLAC[TROLL]}"
    move $(( TROLL2 + 100 )) "${FIXD[TROLL]}"
    juggle "$CHASM"
    PROP[TROLL]=$prop_after
}

# throw_axe_lands SPK
#   Speak the outcome, leave the axe on the floor, and spend the turn on a
#   null move so the dwarves respond. Mutates IPLACE/IOBJ/ICHAIN/LOC — call
#   directly, not in $(...).
function throw_axe_lands() {
    speak "$1"
    drop "$AXE" "$LOC"
    attempt_motion "$MOT_NULL"
}

# do_throw OBJ
#   Handle THROW: treasure to troll pays toll, food to bear feeds it, axe kills dwarves.
#   Mutates everything do_attack/do_drop/feed_bear/banish_troll do — must be called directly.
function do_throw() {
    local -i obj=$1
    local -i spk

    if toting "$ROD2" && (( obj == ROD )) && ! toting "$ROD"; then
        obj=$ROD2
    fi

    if ! toting "$obj"; then
        speak "${ACTSPK[$VERB_THROW]:-29}"   # 29, "YOU AREN'T CARRYING IT!"
        return
    fi

    if is_treasure "$obj" && at "$TROLL"; then
        drop "$obj" 0
        banish_troll "${PROP[TROLL]:-0}"
        speak 159
        return
    fi

    if (( obj == FOOD )) && object_here "$BEAR"; then
        feed_bear
        return
    fi

    if (( obj != AXE )); then
        do_drop "$obj"
        return
    fi

    # No DFLAG test here: if the axe is in the player's hands the dwarves
    # are demonstrably already active, so any dwarf in the room counts.
    local -i i idx=0
    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        if (( DLOC[i] == LOC )); then
            idx=$i
            break
        fi
    done

    if (( idx != 0 )); then
        spk=48
        # A 1-in-3 dodge.
        if (( RANDOM % 3 != 0 )); then
            DSEEN[idx]=0
            DLOC[idx]=0
            spk=47
            (( ++DKILL == 1 )) && spk=149
        fi
        throw_axe_lands "$spk"
        return
    fi

    spk=152                                       # bounces off the dragon
    if at "$DRAGON" && (( PROP[DRAGON] == 0 )); then
        throw_axe_lands "$spk"
        return
    fi

    spk=158                                       # the troll tosses it back
    if at "$TROLL"; then
        throw_axe_lands "$spk"
        return
    fi

    if object_here "$BEAR" && (( PROP[BEAR] == 0 )); then
        speak 164
        drop "$AXE" "$LOC"
        IFIXED[AXE]=-1
        PROP[AXE]=1
        juggle "$BEAR"
        return
    fi

    # Nothing worth throwing at: re-enter ATTACK with no target named,
    # carrying the verb through so the bird stays excluded.
    do_attack 0 "$VERB_THROW"
}

# Object identity constants needed only by the liquid verbs below.
# BOTTLE/OIL/WATER are already declared above (Predicates).
declare -r -i DOOR=9
declare -r -i PILLOW=10  # velvet pillow, pillow-room anchor
declare -r -i PLANT=24
declare -r -i PLANT2=25
declare -r -i VASE=58

# do_pour OBJ
#   Handle POUR: oil frees rusty door, water waters plant for beanstalk growth.
#   Mutates PROP/IPLACE/LOC — must be called directly, not in $(...).
function do_pour() {
    local -i obj=$1

    if (( obj == BOTTLE || obj == 0 )); then
        obj=$(liq)
    fi

    if (( obj == 0 )); then
        printf '\n %s\n' "$(a5toa1 "$WORD1" "$WORD1X" 'What?')"
        return
    fi

    if ! toting "$obj"; then
        speak 29   # ACTSPK[13] — "YOU AREN'T CARRYING IT!"
        return
    fi

    if (( obj != OIL && obj != WATER )); then
        speak 78   # "YOU CAN'T POUR THAT."
        return
    fi

    PROP[BOTTLE]=1
    IPLACE[obj]=0

    if at "$DOOR"; then
        PROP[DOOR]=0
        (( obj == OIL )) && PROP[DOOR]=1
        speak $(( 113 + PROP[DOOR] ))
        return
    fi

    if at "$PLANT"; then
        if (( obj == OIL )); then
            speak 112   # plant shakes the oil off, asks "WATER?"
            return
        fi

        pspeak "$PLANT" "$(( PROP[PLANT] + 1 ))"
        PROP[PLANT]=$(( (PROP[PLANT] + 2) % 6 ))
        PROP[PLANT2]=$(( PROP[PLANT] / 2 ))
        attempt_motion "$MOT_NULL"
        return
    fi

    speak 77
}

# do_drink OBJ — must be called directly, not in $(...).
function do_drink() {
    local -i obj=$1
    local -i spk=73   # ACTSPK[15]

    if (( obj == 0 )); then
        if (( $(liqloc "$LOC") != WATER )) \
            && { (( $(liq) != WATER )) || ! object_here "$BOTTLE"; }; then
            printf '\n %s\n' "$(a5toa1 "$WORD1" "$WORD1X" 'What?')"
            return
        fi
    fi

    (( obj != 0 && obj != WATER )) && spk=110

    if (( spk == 110 )) || (( $(liq) != WATER )) || ! object_here "$BOTTLE"; then
        speak "$spk"
        return
    fi

    PROP[BOTTLE]=1
    IPLACE[WATER]=0
    speak 74
}

# do_eat OBJ
#   JVERB==14 (EAT). If FOOD is not present, asks "What?" If present,
#   destroys it and speaks message 72 ("THANK YOU, IT WAS DELICIOUS!").
#   Mutates IPLACE/IOBJ/ICHAIN — must be called directly, not in $(...).
function do_eat() {
    local -i obj=$1

    if ! object_here "$FOOD"; then
        printf '\n %s\n' "$(a5toa1 "$WORD1" "$WORD1X" 'What?')"
        return
    fi

    dstroy "$FOOD"
    speak 72
}

# do_feed OBJ
#   Handle FEED: BIRD refuses, DWARF angers (DFLAG++), BEAR tames (feed_bear),
#   others get special or generic messages. Mutates PROP/IFIXED/DFLAG.
function do_feed() {
    local -i obj=$1
    local -i spk

    # BIRD: you can't feed a bird (no seed).
    if (( obj == BIRD )); then
        speak 100
        return
    fi

    # SNAKE/DRAGON/TROLL.
    if (( obj == SNAKE )) || (( obj == DRAGON )) || (( obj == TROLL )); then
        spk=102   # default "Nothing happens."
        if (( obj == DRAGON && PROP[DRAGON] != 0 )); then
            spk=110   # "The dragon is, after all, dead."
        fi
        if (( obj == TROLL )); then
            spk=182   # "The troll turns out to prefer dwarf meat."
        fi
        if (( obj == SNAKE )) && object_here "$BIRD"; then
            spk=101   # "The snake has now devoured the bird."
            dstroy "$BIRD"
            PROP[BIRD]=0
            TALLY2=$(( TALLY2 + 1 ))
        fi
        speak "$spk"
        return
    fi

    # DWARF: feeding makes him angry.
    if (( obj == DWARF )); then
        if object_here "$FOOD"; then
            speak 103   # "The dwarf refuses to eat the food."
            DFLAG=$(( DFLAG + 1 ))
        else
            speak 14   # "I don't understand that."
        fi
        return
    fi

    if (( obj == BEAR )); then
        feed_bear
        return
    fi

    speak 14   # "I don't understand that."
}

# do_fill OBJ — must be called directly, not in $(...).
function do_fill() {
    local -i obj=$1

    if (( obj == VASE )); then
        speak 109
        return
    fi

    if (( obj != 0 && obj != BOTTLE )); then
        speak 109   # ACTSPK[22] — "YOU CAN'T FILL THAT."
        return
    fi

    if (( obj == 0 )) && ! object_here "$BOTTLE"; then
        printf '\n %s\n' "$(a5toa1 "$WORD1" "$WORD1X" 'What?')"
        return
    fi

    local -i spk=107
    (( $(liqloc "$LOC") == 0 )) && spk=106   # nothing here to fill it with
    (( $(liq) != 0 )) && spk=105             # bottle already full

    if (( spk != 107 )); then
        speak "$spk"
        return
    fi

    PROP[BOTTLE]=$(( (COND[LOC] % 4) / 2 * 2 ))
    local -i k=$(liq)
    toting "$BOTTLE" && IPLACE[k]=-1
    (( k == OIL )) && spk=108
    speak "$spk"
}

# JVERB==16 (RUB/MASSAGE). Only the lamp.
function do_rub() {
    local -i obj=$1
    if (( obj != LAMP )); then
        speak 76   # "OHM, WHAT A MARVELOUS OBJECT THAT THE RAGS, JACK..."
    else
        speak 76
    fi
}

# JVERB==28 (BREAK). Mirror and vase only.
#   Mutates PROP/FIXED — must be called directly, not in $(...).
function do_break() {
    local -i obj=$1

    if (( obj == MIRROR )); then
        speak 148   # Message for breaking mirror
        return
    fi

    if (( obj == VASE && PROP[VASE] == 0 )); then
        if toting "$VASE"; then
            drop "$VASE" "$LOC"
        fi
        PROP[VASE]=2
        IFIXED[VASE]=-1
        speak 198   # "THE VASE SHATTERS IN MYRIAD PIECES."
        return
    fi

    speak 31   # Default "YOU CAN'T DO THAT" refusal for not-breakable objects
}

# JVERB==27 (READ). Magazine, tablet, message, oyster. The oyster branch
#   only becomes reachable once the cave is closed, and asks its own
#   YES(192,193,54) hint prompt the first time, then just repeats message
#   194 afterward.
function do_read() {
    local -i obj_here=0

    # Scan for readable objects in the room, packing multiple into an
    # OBJ*100+OBJ value if more than one is found.
    if object_here "$MAGZIN"; then
        obj_here="$MAGZIN"
    fi
    if object_here "$TABLET"; then
        obj_here=$(( obj_here * 100 + TABLET ))
    fi
    if object_here "$MESSAG"; then
        obj_here=$(( obj_here * 100 + MESSAG ))
    fi
    # Oyster overwrites the whole thing
    if (( CLOSED == TRUE )) && toting "$OYSTER"; then
        obj_here="$OYSTER"
    fi

    # If ambiguous (OBJ > 100), dark, or not found, ask what to read
    if (( obj_here > 100 || obj_here == 0 )) || dark; then
        ask_what
        return
    fi

    # Dispatch on which object to read
    local -i spk=0
    (( obj_here == MAGZIN )) && spk=190
    (( obj_here == TABLET )) && spk=196
    (( obj_here == MESSAG )) && spk=191
    if (( obj_here == OYSTER )); then
        # If the hint has already been given, just repeat message 194 via
        # the generic speak below; otherwise ask the YES(192,193,54)
        # hint-offer prompt directly, which prints its own message.
        if (( HINTED[2] == TRUE )); then
            spk=194
        else
            yes 192 193 54
            HINTED[2]=$YES_RESULT
            return
        fi
    fi

    if (( spk != 0 )); then
        speak "$spk"
    fi
}

# JVERB==3 (SAY). Echoes second word (or first if none). If it's a magic
#   word, re-enters magic-word processing (stub for now).
function do_say() {
    local word="$WORD2"
    [[ -z "$word" ]] && word="$WORD1"

    local txt=$(a5toa1 "$word" "${!word:+${!word}X}" '".')

    printf '\n Okay, "%s\n' "$txt"
}

# JVERB==26 (BRIEF). Intransitive only. Suppresses long descriptions after
#   the first time per location.
function do_brief() {
    ABBNUM=10000  # Force abbreviations (short descriptions)
    DETAIL=3       # Reduce detail level
    speak 156   # "BRIEF - DESCRIPTIONS OF LOCATIONS WHEN FIRST SEEN WILL NOT BE REPEATED."
}

# do_foo — FEE/FIE/FOE/FOO/FUM sequence; must be called directly, not in $(...).
function do_foo() {
    local -i k
    k=$(get_vocab_id_class "$WORD1" "$VOCAB_CLASS_SPECIAL")

    if (( FOOBAR != 1 - k )); then
        if (( FOOBAR != 0 )); then
            speak 151
        else
            speak 42
        fi
        return
    fi

    FOOBAR=$k
    if (( k != 4 )); then
        speak 54
        return
    fi

    FOOBAR=0
    if (( IPLACE[EGGS] == PLAC[EGGS] )) || { toting "$EGGS" && (( LOC == PLAC[EGGS] )); }; then
        speak 42
        return
    fi

    if (( IPLACE[EGGS] == 0 && IPLACE[TROLL] == 0 && PROP[TROLL] == 0 )); then
        PROP[TROLL]=1
    fi

    local -i msg_k=2
    object_here "$EGGS" && msg_k=1
    (( LOC == PLAC[EGGS] )) && msg_k=0

    move "$EGGS" "${PLAC[EGGS]}"
    pspeak "$EGGS" "$msg_k"
}

# do_wake — must be called directly, not in $(...).
function do_wake() {
    local -i obj=$1

    if (( obj != DWARF || CLOSED == FALSE )); then
        speak "${ACTSPK[29]}"
        return
    fi

    speak 199   # "YOU PROD THE NEAREST DWARF, WHO WAKES UP GRUMPILY..."
    speak 136   # "THE RESULTING RUCKUS HAS AWAKENED THE DWARVES...ALL OF THEM GET YOU!"
    end_game
}

# do_blast — must be called directly, not in $(...).
function do_blast() {
    if (( PROP[ROD2] < 0 || CLOSED == FALSE )); then
        speak "${ACTSPK[23]}"
        return
    fi

    BONUS=133
    (( LOC == 115 )) && BONUS=134
    object_here "$ROD2" && BONUS=135

    speak "$BONUS"
    end_game
}

# do_find OBJNUM [VERB]
function do_find() {
    local -i obj=$1
    local -i verb=${2:-$VERB_FIND}
    local -i spk=${ACTSPK[$verb]:-59}

    if at "$obj" || { (( $(liq) == obj )) && at "$BOTTLE"; } || (( obj == $(liqloc "$LOC") )); then
        spk=94
    fi
    (( obj == DWARF )) && dwarf_here && spk=94
    (( CLOSED == TRUE )) && spk=138
    toting "$obj" && spk=24

    speak "$spk"
}

# do_inventory
#   Bare INVENTORY command only. Loops objects 1-100, skipping BEAR and
#   anything not TOTING. Prints:
#   - message 98 ("YOU'RE NOT CARRYING ANYTHING.") if empty
#   - message 99 ("YOU ARE CURRENTLY HOLDING THE FOLLOWING:") once
#   - each carried item with pspeak(obj,-1)
#   - message 141 ("YOU ARE BEING FOLLOWED...TAME BEAR.") if TOTING(BEAR)
function do_inventory() {
    local -i spk=98 found=$FALSE

    for (( i = 1; i <= 100; i++ )); do
        if (( i == BEAR )) || ! toting "$i"; then
            continue
        fi
        if (( spk == 98 )); then
            speak 99
        fi
        found=$TRUE
        pspeak "$i" -1
        spk=0
    done

    toting "$BEAR" && spk=141
    (( found == FALSE )) && speak 98
    (( spk == 141 )) && speak 141
}

# --- Main Engine ---

# pspeak OBJ PROP_INDEX
function pspeak() {
    local -i obj=$1 prop=$2
    local text

    if (( prop < 0 )); then
        text="${INVEN_TEXT[$obj]:-}"
    else
        local -i key=$(( obj * OBJPROP_SCALE + prop ))
        text="${OBJ_TEXT[$key]:-}"
    fi

    [[ "$text" == '>$<'* ]] && return
    [[ -n "$text" ]] && echo -e "$text"
}

# get_object_text OBJ
#   Prints OBJ's room-description text for its current PROP state.
function get_object_text() {
    local -i obj=$1
    pspeak "$obj" "${PROP[obj]:-0}"
}

# print_desc ROOM — must be called directly, not in $(...).
function print_desc() {
    local -i room=$1

    # First visit, or no short description available: show the long text.
    if [[ ${ABB[$room]:-0} == 0 || -z "${RAW_SHORT[$room]:-}" ]]; then
        echo -e "${RAW_TEXT[$room]:-}"
    else
        echo -e "${RAW_SHORT[$room]:-}"
    fi

    # Walk IOBJ/ICHAIN; handle negative PROP and tally treasures.
    local -i obj=${IOBJ[room]:-0} disp
    local -i lit=$TRUE          # dark() reads LOC, which both callers have
    dark && lit=$FALSE          # already set to ROOM by the time we get here
    while (( obj != 0 )); do
        disp=$obj
        (( disp > 100 )) && disp=$(( disp - 100 ))

        if (( PROP[disp] < 0 )); then
            if (( CLOSED == TRUE )); then
                obj=${ICHAIN[obj]:-0}   # print nothing at all
                continue
            fi
            if (( lit == TRUE )); then
                PROP[disp]=0
                (( disp == RUG || disp == CHAIN )) && PROP[disp]=1
                (( TALLY-- ))
                (( TALLY == TALLY2 && TALLY != 0 && LIMIT > 35 )) && LIMIT=35
            fi
        fi

        get_object_text "$disp"
        obj=${ICHAIN[obj]:-0}
    done

    # ABB is bumped by arrive(), not here: the visit only counts once the
    # player has settled, so pass-through descriptions of forced rooms keep
    # showing their long text.
}

# hint_check
#   Dwell-time accumulation for hints: increment HINTLC for hints in current room's COND bits,
#   set HINT_DUE when threshold reached. Sets HINTLC/HINT_DUE — must be called directly.
function hint_check() {
    local -i hint

    HINT_DUE=-1
    for (( hint = 4; hint <= HNTMAX; hint++ )); do
        (( HINTED[hint] == TRUE )) && continue

        if ! bitset "$LOC" "$hint"; then
            HINTLC[hint]=-1
        fi
        (( HINTLC[hint]++ ))

        if (( HINTLC[hint] >= HINT_TURNS[hint] )); then
            HINT_DUE=$hint
            break
        fi
    done
}

# hint_offer
#   Offer due hint (set by hint_check) after testing per-hint conditions; accepting
#   hint tops up lamp fuel if LIMIT > 30. Mutates HINTLC/HINTED/LIMIT — must be called directly.
function hint_offer() {
    local -i hint=$HINT_DUE

    # Per-hint quick-test gates. If the condition isn't met, reset
    # HINTLC[hint]=0 and return, or (hint 5) just return without reset.
    case $hint in
        4)  # CAVE: PROP(GRATE)==0 AND NOT HERE(KEYS)
            if (( PROP[GRATE] == 0 )) && ! object_here KEYS; then
                : # condition met, fall through
            else
                HINTLC[hint]=0
                return
            fi
            ;;
        5)  # BIRD: HERE(BIRD) AND TOTING(ROD) AND OBJ==BIRD
            # OBJ=0 at hint-check time, so OBJ==BIRD is always false — this
            # hint never fires in practice.
            if object_here BIRD && toting ROD && (( OBJ == BIRD )); then
                : # condition met, fall through
            else
                return
            fi
            ;;
        6)  # SNAKE: HERE(SNAKE) AND NOT HERE(BIRD)
            if object_here SNAKE && ! object_here BIRD; then
                : # condition met, fall through
            else
                HINTLC[hint]=0
                return
            fi
            ;;
        7)  # MAZE: ATLOC(LOC)==0 AND ATLOC(OLDLOC)==0 AND ATLOC(OLDLC2)==0
            #   AND HOLDNG>1
            if (( IOBJ[LOC] == 0 && IOBJ[OLDLOC] == 0 && IOBJ[OLDLC2] == 0 && HOLDNG > 1 )); then
                : # condition met, fall through
            else
                HINTLC[hint]=0
                return
            fi
            ;;
        8)  # DARK: PROP(EMRALD)!=-1 AND PROP(PYRAM)==-1
            if (( PROP[EMRALD] != -1 && PROP[PYRAM] == -1 )); then
                : # condition met, fall through
            else
                HINTLC[hint]=0
                return
            fi
            ;;
        9)  # WITT: unconditional
            ;;
    esac

    # Conditions met (or hint 9) — proceed with the offer.
    HINTLC[hint]=0

    yes "${HINT_QMSG[$hint]}" 0 54
    (( YES_RESULT != TRUE )) && return

    printf "$(format_case '\n I am prepared to give you a hint, but it will cost you %d points.\n')" \
        "${HINT_PENALTY[$hint]}"

    yes 175 "${HINT_HINTMSG[$hint]}" 54
    HINTED[hint]=$YES_RESULT
    (( HINTED[hint] == TRUE && LIMIT > 30 )) && LIMIT=$(( LIMIT + 30 * HINT_PENALTY[hint] ))
}

# ---------------------------------------------------------------------------
#  Scoring & Player Classification
# ---------------------------------------------------------------------------

# score — tallies treasures, bonuses, and penalties; prints classification.
function score() {
    local -i i k score=0 mxscor=0

    for (( i = TREASURE_MIN; i <= TREASURE_MAX; i++ )); do
        [[ -n "${INVEN_TEXT[i]:-}" ]] || continue
        k=12
        (( i == CHEST )) && k=14
        (( i > CHEST )) && k=16
        (( PROP[i] >= 0 )) && score=$(( score + 2 ))
        (( IPLACE[i] == 3 && PROP[i] == 0 )) && score=$(( score + k - 2 ))
        mxscor=$(( mxscor + k ))
    done

    score=$(( score + (MAXDIE - NUMDIE) * 10 ))
    mxscor=$(( mxscor + MAXDIE * 10 ))
    (( SCORNG == FALSE && GAVEUP == FALSE )) && score=$(( score + 4 ))
    mxscor=$(( mxscor + 4 ))
    (( DFLAG != 0 )) && score=$(( score + 25 ))
    mxscor=$(( mxscor + 25 ))
    (( CLOSNG == TRUE )) && score=$(( score + 25 ))
    mxscor=$(( mxscor + 25 ))

    # Endgame bonus tier, gated on CLOSED.
    if (( CLOSED == TRUE )); then
        (( BONUS == 0 )) && score=$(( score + 10 ))
        (( BONUS == 135 )) && score=$(( score + 25 ))
        (( BONUS == 134 )) && score=$(( score + 30 ))
        (( BONUS == 133 )) && score=$(( score + 45 ))
    fi
    mxscor=$(( mxscor + 45 ))

    # Came to Witt's End (room 108) with the magazine.
    (( IPLACE[MAGZIN] == 108 )) && score=$(( score + 1 ))
    mxscor=$(( mxscor + 1 ))

    # Round it off.
    score=$(( score + 2 ))
    mxscor=$(( mxscor + 2 ))

    # Deduct hint penalties.
    for (( i = 1; i <= HNTMAX; i++ )); do
        (( HINTED[i] == TRUE )) && score=$(( score - HINT_PENALTY[i] ))
    done

    LAST_SCORE=$score
    LAST_MXSCOR=$mxscor

    (( SCORNG == TRUE )) && return

    printf "$(format_case '\n\nYou scored %d out of a possible %d, using %d turns.\n')" \
        "$score" "$mxscor" "$TURNS"

    # Player classification. RAW_CTEXT is keyed by threshold; Bash walks an
    # indexed array's "${!arr[@]}" in ascending numeric order.
    local -a thresholds=("${!RAW_CTEXT[@]}")
    local -i n=${#thresholds[@]} idx found=-1
    for (( idx = 0; idx < n; idx++ )); do
        if (( thresholds[idx] >= score )); then
            found=$idx
            break
        fi
    done

    if (( found == -1 )); then
        printf "$(format_case '\n You just went off my scale!!\n')"
        return
    fi

    echo -e "${RAW_CTEXT[${thresholds[$found]}]}"

    if (( found == n - 1 )); then
        printf "$(format_case '\n To achieve the next higher rating would be a neat trick!\n\n Congratulations!!\n')"
        return
    fi

    local -i need=$(( thresholds[found] + 1 - score ))
    local suffix='s.'
    (( need == 1 )) && suffix='. '
    (( USE_MIXEDCASE == FALSE )) && suffix=$(echo "$suffix" | tr '[:lower:]' '[:upper:]')
    printf "$(format_case '\n To achieve the next higher rating, you need%3d more point%s\n')" \
        "$need" "$suffix"
}

# ---------------------------------------------------------------------------
#  Cave Closing — closing trigger & clocks
# ---------------------------------------------------------------------------

# close_cave
#   CLOCK1 warning: grate re-locks, dwarves/pirate wiped, troll banished, bear destroyed
#   unless tamed. Sets CLOSNG. Mutates PROP/DSEEN/DLOC/IPLACE/IFIXED/IOBJ/ICHAIN/CLOCK1.
function close_cave() {
    local -i i

    PROP[GRATE]=0
    PROP[FISSUR]=0
    for (( i = 1; i <= PIRATE; i++ )); do
        DSEEN[i]=0
        DLOC[i]=0
    done
    move "$TROLL" 0
    move $(( TROLL + 100 )) 0
    move "$TROLL2" "${PLAC[TROLL]}"
    move $(( TROLL2 + 100 )) "${FIXD[TROLL]}"
    juggle "$CHASM"
    (( PROP[BEAR] != 3 )) && dstroy "$BEAR"
    PROP[CHAIN]=0
    IFIXED[CHAIN]=0
    PROP[AXE]=0
    IFIXED[AXE]=0
    speak 129

    CLOCK1=-1
    CLOSNG=$TRUE
}

# The repository/storage room the endgame drops the player into. Both
# halves are ordinary section-1 rooms with no data flag marking them as
# the endgame's, so the numbers are hardwired here.
declare -r -i REPO_NE=115
declare -r -i REPO_SW=116

# put OBJ WHERE PVAL
#   move() + negate PVAL to PROP (negated suppresses object description).
#   Returns PUT_PROP (called directly, not in subshell).

declare -i PUT_PROP=0
function put() {
    local -i obj=$1 where=$2 pval=$3

    move "$obj" "$where"
    PUT_PROP=$(( -1 - pval ))
}

# endgame_transport
#   CLOCK2 expired: player lands in repository, endgame begins. Objects stocked with
#   negative PROPs; liquids/keys destroyed. Sets CLOSED. Mutates PROP/IFIXED/LOC/CLOCK2/CLOSED.
#   Must be called directly, not in $(...).
function endgame_transport() {
    local -i i

    put "$BOTTLE" "$REPO_NE" 1; PROP[BOTTLE]=$PUT_PROP
    put "$PLANT"  "$REPO_NE" 0; PROP[PLANT]=$PUT_PROP
    put "$OYSTER" "$REPO_NE" 0; PROP[OYSTER]=$PUT_PROP
    put "$LAMP"   "$REPO_NE" 0; PROP[LAMP]=$PUT_PROP
    put "$ROD"    "$REPO_NE" 0; PROP[ROD]=$PUT_PROP
    put "$DWARF"  "$REPO_NE" 0; PROP[DWARF]=$PUT_PROP
    LOC=$REPO_NE
    OLDLOC=$REPO_NE
    NEXT_LOC=$REPO_NE

    # The grate moves but keeps its (non-negative) PROP, so PUT_PROP is
    # simply not consumed here.
    put "$GRATE"  "$REPO_SW" 0
    put "$SNAKE"  "$REPO_SW" 1; PROP[SNAKE]=$PUT_PROP
    put "$BIRD"   "$REPO_SW" 1; PROP[BIRD]=$PUT_PROP
    put "$CAGE"   "$REPO_SW" 0; PROP[CAGE]=$PUT_PROP
    put "$ROD2"   "$REPO_SW" 0; PROP[ROD2]=$PUT_PROP
    put "$PILLOW" "$REPO_SW" 0; PROP[PILLOW]=$PUT_PROP

    put "$MIRROR" "$REPO_NE" 0; PROP[MIRROR]=$PUT_PROP
    IFIXED[MIRROR]=$REPO_SW

    # Anything still in hand when the flash hits is gone for good.
    for (( i = 1; i <= 100; i++ )); do
        toting "$i" && dstroy "$i"
    done

    speak 132   # "THE SEPULCHRAL VOICE ENTONES, 'THE CAVE IS NOW CLOSED.'..."

    CLOCK2=-1
    CLOSED=$TRUE
}

# ---------------------------------------------------------------------------
#  Ending flow: death/resurrection, forced ends, and the lamp-fuel clock
# ---------------------------------------------------------------------------

# end_game — must be called directly, not in $(...).
function end_game() {
    score
    GAME_OVER=$TRUE
}

# handle_death — must be called directly, not in $(...).
function handle_death() {
    if (( CLOSNG == TRUE )); then
        speak 131
        NUMDIE=$(( NUMDIE + 1 ))
        end_game
        return
    fi

    yes $(( 81 + NUMDIE * 2 )) $(( 82 + NUMDIE * 2 )) 54
    local -i yea=$YES_RESULT
    NUMDIE=$(( NUMDIE + 1 ))
    if (( NUMDIE == MAXDIE || yea == FALSE )); then
        end_game
        return
    fi

    IPLACE[WATER]=0
    IPLACE[OIL]=0
    toting "$LAMP" && PROP[LAMP]=0
    local -i i dest
    for (( i = 100; i >= 1; i-- )); do
        toting "$i" || continue
        dest=$OLDLC2
        (( i == LAMP )) && dest=1
        drop "$i" "$dest"
    done
    LOC=3
    OLDLOC=$LOC
    RESURRECTED=$TRUE
}

# fall_in_pit — must be called directly, not in $(...).
function fall_in_pit() {
    speak 23
    OLDLC2=$LOC
    handle_death
}

# lamp_refill — must be called directly, not in $(...).
function lamp_refill() {
    speak 188
    PROP[BATTER]=1
    toting "$BATTER" && drop "$BATTER" "$LOC"
    LIMIT=$(( LIMIT + 2500 ))
    LMWARN=$FALSE
}

# lamp_warn — must be called directly, not in $(...).
function lamp_warn() {
    (( LMWARN == TRUE )) && return
    object_here "$LAMP" || return
    LMWARN=$TRUE
    local -i spk=187
    (( IPLACE[BATTER] == 0 )) && spk=183
    (( PROP[BATTER] == 1 )) && spk=189
    speak "$spk"
}

# lamp_died — must be called directly, not in $(...).
function lamp_died() {
    LIMIT=-1
    PROP[LAMP]=0
    object_here "$LAMP" && speak 184
}

# lamp_forced_giveup — must be called directly, not in $(...).
function lamp_forced_giveup() {
    speak 185
    GAVEUP=$TRUE
    end_game
}

# --- Suspend/Resume ---

declare SAVE_FILE="adventure.save"
declare -i RESUME_REQUESTED=$FALSE

declare -ar SAVE_ARRAYS=(
    IOBJ ICHAIN IPLACE IFIXED COND PROP ABB
    DLOC ODLOC DSEEN
    HINTLC HINTED
)
declare -ar SAVE_SCALARS=(
    LOC OLDLOC OLDLC2 IDETAL
    DFLAG IFIRST IWEST ILONG HOLDNG KNFLOC
    CLOSED CLOSNG BONUS GAVEUP SCORNG
    CLOCK1 CLOCK2 PANIC
    LIMIT LMWARN
    TURNS FOOBAR NUMDIE MAXDIE
    TALLY TALLY2 DKILL
    SAVED SAVET SETUP
)

function save_game() {
    local file=$1
    local name line

    {
        for name in "${SAVE_ARRAYS[@]}" "${SAVE_SCALARS[@]}"; do
            line=$(declare -p "$name")
            line=${line#declare -a }
            line=${line#declare -i }
            if [[ "$line" == *"='("*")'" ]]; then
                line=${line/=\'/=}
                line=${line%\'}
            fi
            printf '%s\n' "$line"
        done
    } > "$file"
}

# restore_game — must be called directly, not in $(...).
function restore_game() {
    source "$1"
}

# do_suspend — must be called directly, not in $(...).
function do_suspend() {
    printf "$(format_case '\nI can suspend your adventure so you can resume it later.\n')"
    printf "$(format_case 'Your progress will be saved to \"%s\"; run this game again with the\n')" "$SAVE_FILE"
    printf "$(format_case '\"--resume\" flag (or \"--resume=%s\" if you rename the file) to continue.\n')" "$SAVE_FILE"
    yes 200 0 54
    if (( YES_RESULT == TRUE )); then
        datime
        SAVED=$DATIME_D
        SAVET=$DATIME_T
        SETUP=-1   # mark "resuming" for start_gate() to detect next time
        save_game "$SAVE_FILE"
        printf "$(format_case '\nOK, your adventure has been suspended.\n')"
        SUSPENDED=$TRUE
    fi
}

# --- Wizard Mode / Cave Hours ---

# poof — seed WIZCOM defaults on first run.
function poof() {
    WKDAY=$(( 8#777400 ))
    WKEND=0
    HOLID=0
    HBEGIN=0
    HEND=-1
    SHORT=30
    MAGIC_WORD="DWARF"
    MAGNM=11111
    LATNCY=90
}

# load_wizcom — must be called directly, not in $(...).
function load_wizcom() {
    local file="${1:-$WIZCOM_FILE}"

    if [[ -f "$file" ]]; then
        source "$file"
    else
        poof
    fi
}

function save_wizcom() {
    local file="${1:-$WIZCOM_FILE}"
    local name line

    {
        for name in "${WIZCOM_ARRAYS[@]}" "${WIZCOM_SCALARS[@]}"; do
            line=$(declare -p "$name")
            line=${line#declare -a }
            line=${line#declare -i }
            line=${line#declare -- }
            if [[ "$line" == *"='("*")'" ]]; then
                line=${line/=\'/=}
                line=${line%\'}
            fi
            printf '%s\n' "$line"
        done
    } > "$file"
}

# wizard — must be called directly, not in $(...).
function wizard() {
    local -r alpha="ABCDEFGHIJKLMNOPQRSTUVWXYZ"

    yesm 16 0 7
    (( YES_RESULT == FALSE )) && return $FALSE

    mspeak 17
    getin
    if [[ "$WORD1" != "$MAGIC_WORD" ]]; then
        mspeak 20
        return $FALSE
    fi

    datime
    local -i d=$DATIME_D t=$(( DATIME_T * 2 + 1 ))
    local -a val
    local -i y z iters x
    for (( y = 1; y <= 5; y++ )); do
        iters=$(( 79 + d % 5 ))
        d=$(( d / 5 ))
        for (( z = 0; z < iters; z++ )); do
            t=$(( (t * 1027) % 1048576 ))
        done
        val[y]=$(( (t * 26) / 1048576 + 1 ))
    done

    yesm 18 0 0
    if (( YES_RESULT == TRUE )); then
        mspeak 20
        return $FALSE
    fi

    local challenge=""
    for (( y = 1; y <= 5; y++ )); do
        challenge+="${alpha:val[y]-1:1}"
    done
    printf '\n %s\n' "$challenge"
    getin
    local reply="$WORD1"

    datime
    local -i t2=$(( (DATIME_T / 60) * 40 + (DATIME_T / 10) * 10 ))
    local -i d2=$MAGNM
    local expected=""
    for (( y = 1; y <= 5; y++ )); do
        z=$(( y % 5 + 1 ))
        x=$(( ( (val[y] > val[z] ? val[y] - val[z] : val[z] - val[y]) * (d2 % 10) + (t2 % 10) ) % 26 + 1 ))
        t2=$(( t2 / 10 ))
        d2=$(( d2 / 10 ))
        expected+="${alpha:x-1:1}"
    done

    if [[ "$reply" == "$expected" ]]; then
        mspeak 19
        return $TRUE
    fi
    mspeak 20
    return $FALSE
}

function hoursx() {
    local -i h=$1
    local day1="$2" day2="$3"
    local -i first=$TRUE
    local -i from=-1 till

    if (( h == 0 )); then
        printf '          %-5s%-5s  Open all day\n' "$day1" "$day2"
        return
    fi

    while true; do
        from=$(( from + 1 ))
        (( (h >> from) & 1 )) && continue
        if (( from >= 24 )); then
            break
        fi
        till=$from
        while true; do
            till=$(( till + 1 ))
            if (( till != 24 )) && (( ((h >> till) & 1) == 0 )); then
                continue
            fi
            break
        done
        if (( first == TRUE )); then
            printf '          %-5s%-5s%4d:00 to%3d:00\n' "$day1" "$day2" "$from" "$till"
        else
            printf '                    %4d:00 to%3d:00\n' "$from" "$till"
        fi
        first=$FALSE
        from=$till
    done

    (( first == TRUE )) && printf '          %-5s%-5s  Closed all day\n' "$day1" "$day2"
}

# hours — must be called directly, not in $(...).
function hours() {
    echo ""
    hoursx "$WKDAY" "Mon -" " Fri:"
    hoursx "$WKEND" "Sat -" " Sun:"
    hoursx "$HOLID" "Holid" "ays: "

    datime
    if (( HEND < DATIME_D || HEND < HBEGIN )); then
        return
    fi
    if (( HBEGIN > DATIME_D )); then
        local -i d=$(( HBEGIN - DATIME_D ))
        local unit="Days,"
        (( d == 1 )) && unit="Day, "
        printf '\n The next holiday will be in%3d %s namely %s\n' "$d" "$unit" "${HNAME[0]:-}"
        return
    fi
    printf '\n Today is a holiday, namely %s\n' "${HNAME[0]:-}"
}

function newhrx() {
    local day1="$1" day2="$2"
    local -i mask=0 i
    local from till

    printf '\n Prime time on %s%s\n' "$day1" "$day2"
    while true; do
        read -r -p " from: " from
        [[ "$from" =~ ^-?[0-9]+$ ]] || from=-1
        (( from < 0 || from >= 24 )) && break

        read -r -p " till: " till
        [[ "$till" =~ ^-?[0-9]+$ ]] || till=-1
        till=$(( till - 1 ))
        (( till < from || till >= 24 )) && break

        for (( i = from; i <= till; i++ )); do
            mask=$(( mask | 2 ** i ))
        done
    done
    NEWHRX_RESULT=$mask
}

# newhrs — must be called directly, not in $(...).
function newhrs() {
    mspeak 21
    newhrx "Weekd" "ays:"; WKDAY=$NEWHRX_RESULT
    newhrx "Weeke" "nds:"; WKEND=$NEWHRX_RESULT
    newhrx "Holid" "ays:"; HOLID=$NEWHRX_RESULT
    mspeak 22
    hours
}

# maint
#   Wizard configuration: view/edit hours, holiday, demo length, magic word/number, MOTD.
#   Must be called directly — mutates WIZCOM globals and ABB.
function maint() {
    if ! wizard; then
        return
    fi

    yesm 10 0 0
    (( YES_RESULT == TRUE )) && hours

    yesm 11 0 0
    (( YES_RESULT == TRUE )) && newhrs

    yesm 26 0 0
    if (( YES_RESULT == TRUE )); then
        mspeak 27
        local hb=""      # not -i — see newhrx()'s comment on this pattern
        read -r hb
        [[ "$hb" =~ ^-?[0-9]+$ ]] || hb=0
        mspeak 28
        local he=""
        read -r he
        [[ "$he" =~ ^-?[0-9]+$ ]] || he=0
        datime
        HBEGIN=$(( hb + DATIME_D ))
        HEND=$(( HBEGIN + he - 1 ))
        mspeak 29
        local hn=""
        read -r hn
        HNAME[0]="$hn"
    fi

    printf ' Length of short game (null to leave at%3d):\n' "$SHORT"
    local x=""      # not -i — see newhrx()'s comment on this pattern
    read -r x
    if [[ "$x" =~ ^[0-9]+$ ]] && (( x > 0 )); then
        SHORT=$x
    fi

    mspeak 12
    getin
    [[ -n "$WORD1" ]] && MAGIC_WORD="$WORD1"

    mspeak 13
    read -r x
    if [[ "$x" =~ ^[0-9]+$ ]] && (( x > 0 )); then
        MAGNM=$x
    fi

    printf ' Latency for restart (null to leave at%3d):\n' "$LATNCY"
    read -r x
    if [[ "$x" =~ ^[0-9]+$ ]] && (( x > 0 )); then
        (( x < 45 )) && mspeak 30
        (( LATNCY = x > 45 ? x : 45 ))
    fi

    yesm 14 0 0
    (( YES_RESULT == TRUE )) && motd true

    SAVED=0
    SETUP=2
    ABB[1]=0

    mspeak 15
    save_wizcom
}

# motd [ALTER]
#   Display or edit wizard MOTD (stored as single string, preserving newlines).
#   Must be called directly (raw read, not getin).
function motd() {
    local -r alter="${1:-false}"

    if [[ "$alter" == "true" ]]; then
        # Edit mode: let the wizard compose/replace the MOTD, reading raw
        # lines (not via getin which uppercases and splits on whitespace).
        local -i line_count=0
        local new_motd=""
        mspeak 23    # "LIMIT LINES TO 70 CHARS. END WITH NULL LINE."
        while (( line_count < 100 )); do
            local line=""
            read -r -p "" line
            [[ -z "$line" ]] && break      # empty line ends entry
            if (( ${#line} > 70 )); then
                mspeak 24                  # "LINE TOO LONG, RETYPE:"
                continue
            fi
            if [[ -n "$new_motd" ]]; then
                new_motd+=$'\n'
            fi
            new_motd+="$line"
            (( line_count++ ))
        done
        if (( line_count >= 100 )); then
            mspeak 25                      # "NOT ENOUGH ROOM FOR ANOTHER LINE..."
        fi
        MOTD="$new_motd"
    else
        # Display mode: print MOTD at startup if set
        [[ -n "$MOTD" ]] && printf '\n %s\n' "$MOTD"
    fi
}

# start_gate
#   Prime-time gate: checks if inside restricted hours, offers demo on closed hours.
#   Sets DEMO. Can exit directly. Must be called directly, not in $(...).
function start_gate() {
    datime
    update_day_class

    local -i ptime=$FALSE
    (( (PRIMTM >> (DATIME_T / 60)) & 1 )) && ptime=$TRUE
    local -i soon=$FALSE

    DEMO=$FALSE

    if (( SETUP < 0 )); then
        local -i delay=$(( (DATIME_D - SAVED) * 1440 + (DATIME_T - SAVET) ))
        if (( delay < LATNCY )); then
            printf ' This adventure was suspended a mere%3d minutes ago.\n' "$delay"
            soon=$TRUE
            if (( delay < LATNCY / 3 )); then
                mspeak 2
                exit 0
            fi
        fi
    fi

    if (( soon == TRUE )); then
        mspeak 8
        if wizard; then
            SAVED=-1
            return
        fi
        mspeak 9
        exit 0
    fi

    if (( ptime == FALSE )); then
        SAVED=-1
        return
    fi

    # Prime time, not restarting-too-soon: announce hours, then either the
    # wizard bypass or (fresh games only) offer a short demo instead.
    mspeak 3
    hours
    mspeak 4
    if wizard; then
        SAVED=-1
        return
    fi
    if (( SETUP < 0 )); then
        mspeak 9
        exit 0
    fi
    yesm 5 7 7
    DEMO=$YES_RESULT
    if (( DEMO == TRUE )); then
        SAVED=-1
        return
    fi
    exit 0
}

function play_game() {
    if (( RESUME_REQUESTED == FALSE )); then
        start_gate
        motd
        yes 65 1 0
        HINTED[3]=$YES_RESULT
        LIMIT=330
        (( HINTED[3] == TRUE )) && LIMIT=1000

        if (( CROWTHER_MODE == TRUE )); then
            echo ""
            echo "  [Playing in Crowther-compatible mode: Woods engine with Crowther's"
            echo "   21-location footprint. No scoring, pirate, or cave closing.]"
            echo ""
        fi

        print_desc "$LOC"
        arrive "$LOC"
        hint_check
        (( HINT_DUE != -1 )) && hint_offer
    fi

    while true; do
        # Once closed, reveal toted objects with negative PROP.
        if (( CLOSED == TRUE )); then
            local -i idondx
            for (( idondx = 1; idondx <= 100; idondx++ )); do
                if toting "$idondx" && (( PROP[idondx] < 0 )); then
                    PROP[idondx]=$(( -1 - PROP[idondx] ))
                fi
            done
        fi

        (( KNFLOC > 0 && KNFLOC != LOC )) && KNFLOC=0

        if (( CMD_PENDING == TRUE )); then
            CMD_PENDING=$FALSE
        else
            getin
            if (( GETIN_EOF == TRUE )); then
                echo "Quitting game."
                break
            fi
        fi

        FOOBAR=$(( FOOBAR < 0 ? 0 : -FOOBAR ))

        if (( TURNS == 0 )) && [[ "$WORD1" == "MAGIC" && "$WORD2" == "MODE" ]]; then
            maint
            continue
        fi

        TURNS=$(( TURNS + 1 ))

        if (( DEMO == TRUE && TURNS >= SHORT )); then
            mspeak 1
            end_game
            break
        fi

        if (( CROWTHER_MODE == FALSE && TALLY == 0 && LOC >= 15 && LOC != 33 )); then
            CLOCK1=$(( CLOCK1 - 1 ))
        fi
        local -i run_limit=$TRUE
        if (( CLOCK1 == 0 )); then
            close_cave
            run_limit=$FALSE
        elif (( CLOCK1 < 0 )); then
            CLOCK2=$(( CLOCK2 - 1 ))
            if (( CLOCK2 == 0 )); then
                endgame_transport
                print_desc "$LOC"
                arrive "$LOC"
                hint_check
                (( HINT_DUE != -1 )) && hint_offer
                continue
            fi
        fi

        if (( run_limit == TRUE )); then
            (( PROP[LAMP] == 1 )) && LIMIT=$(( LIMIT - 1 ))
            if (( LIMIT <= 30 )) && object_here "$BATTER" \
                    && (( PROP[BATTER] == 0 )) && object_here "$LAMP"; then
                lamp_refill
            elif (( LIMIT == 0 )); then
                lamp_died
            elif (( LIMIT < 0 && LOC <= 8 )); then
                lamp_forced_giveup
            elif (( LIMIT <= 30 )); then
                lamp_warn
            fi
            (( GAME_OVER == TRUE )) && break
        fi

        if [[ "$WORD1" == "QUIT" || "$WORD1" == "EXIT" ]]; then
            yes 22 54 54
            if (( YES_RESULT == TRUE )); then
                echo "Quitting game."
                GAVEUP=$TRUE
                (( CROWTHER_MODE == FALSE )) && score
                break
            fi
            continue
        fi

        local parsed
        parsed=$(parse_command)
        local v1="${parsed%% *}"
        local v2="${parsed#* }"

        local verb=-1 noun=-1 motion=-1 msg=-1
        for id in "$v1" "$v2"; do
            if (( id == -1 )); then continue; fi
            if (( id < 1000 )); then motion=$id
            elif (( id < 2000 )); then noun=$id
            elif (( id < 3000 )); then verb=$id
            elif (( id < 4000 )); then msg=$id
            fi
        done

        JVERB=0
        (( verb != -1 )) && JVERB=$(( verb - 2000 ))

        if (( noun - 1000 == KNIFE && KNFLOC == LOC )); then
            KNFLOC=-1
            speak 116
            continue
        fi

        if (( msg != -1 )); then
            speak $(( msg % 1000 ))
            OBJ=0
        elif (( motion != -1 )); then
            attempt_motion "$motion"
        elif (( verb != -1 && noun != -1 )); then
            local -i objnum=$(( noun - 1000 ))
            if (( JVERB == 1 || JVERB == 2 )); then
                if (( objnum == ROD )); then
                    if (( JVERB == 1 )) && ! object_here "$ROD" && object_here "$ROD2"; then
                        objnum=$ROD2
                    elif (( JVERB == 2 )) && toting "$ROD2" && ! toting "$ROD"; then
                        objnum=$ROD2
                    fi
                fi
                if object_here "$objnum"; then
                    if (( JVERB == 1 )); then
                        do_take "$objnum"
                    else
                        do_drop "$objnum"
                    fi
                else
                    echo "$(format_case 'I see no such thing here.')"
                fi
            elif (( JVERB == 4 )); then
                do_unlock "$objnum"
            elif (( JVERB == 6 )); then
                do_lock "$objnum"
            elif (( JVERB == 7 )); then
                do_light "$objnum"
            elif (( JVERB == 8 )); then
                do_extinguish "$objnum"
            elif (( JVERB == 9 )); then
                do_strike "$objnum"
            elif (( JVERB == 10 )); then
                speak "${ACTSPK[10]}"
            elif (( JVERB == 12 || JVERB == 17 )); then
                if noun_present "$objnum"; then
                    if (( JVERB == 12 )); then
                        do_attack "$objnum" "$VERB_KILL"
                    else
                        do_throw "$objnum"
                    fi
                else
                    echo "$(format_case 'I see no such thing here.')"
                fi
            elif (( JVERB == 13 )); then
                do_pour "$objnum"
            elif (( JVERB == 14 )); then
                do_eat "$objnum"
            elif (( JVERB == 15 )); then
                do_drink "$objnum"
            elif (( JVERB == 21 )); then
                do_feed "$objnum"
            elif (( JVERB == 22 )); then
                do_fill "$objnum"
            elif (( JVERB == 16 )); then
                do_rub "$objnum"
            elif (( JVERB == 28 )); then
                do_break "$objnum"
            elif (( JVERB == 27 )); then
                do_read "$objnum"
            elif (( JVERB == 23 )); then
                do_blast "$objnum"
            elif (( JVERB == 29 )); then
                do_wake "$objnum"
            elif (( JVERB == 19 || JVERB == 20 )); then
                do_find "$objnum" "$JVERB"
            else
                echo "Action ID: $verb on Object ID: $noun (Not yet implemented)"
            fi
        elif (( verb != -1 )); then
            if (( JVERB == 12 )); then
                do_attack 0 "$VERB_KILL"
            elif (( JVERB == 17 )); then
                ask_what
            elif (( JVERB == 4 )); then
                do_unlock 0
            elif (( JVERB == 6 )); then
                do_lock 0
            elif (( JVERB == 13 )); then
                do_pour 0
            elif (( JVERB == 14 )); then
                do_eat 0
            elif (( JVERB == 15 )); then
                do_drink 0
            elif (( JVERB == 21 )); then
                do_feed 0
            elif (( JVERB == 22 )); then
                do_fill 0
            elif (( JVERB == 16 )); then
                do_rub 0
            elif (( JVERB == 28 )); then
                ask_what
            elif (( JVERB == 27 )); then
                ask_what
            elif (( JVERB == 23 )); then
                do_blast 0
            elif (( JVERB == 29 )); then
                ask_what
            elif (( JVERB == 10 )); then
                ask_what
            elif (( JVERB == 19 )); then
                # Bare FIND/WHERE asks "what?"; bare INVENTORY (verb 20) is
                # handled separately below.
                ask_what
            elif (( JVERB == 20 )); then
                # Bare INVENTORY: loops all carried objects and prints them
                # (or "nothing" if empty).
                do_inventory
            elif (( JVERB == 3 )); then
                # SAY — intransitive, uses WORD1/WORD2 directly.
                do_say
            elif (( JVERB == 26 )); then
                do_brief
            elif (( JVERB == 25 )); then
                # FEE/FIE/FOE/FOO/FUM share one verb number; do_foo
                # re-resolves WORD1 to find out which of the five was
                # actually said.
                do_foo
            elif (( JVERB == 24 )); then
                # SCORE: sets SCORNG=TRUE, calls score() which returns early
                # (populating LAST_SCORE/LAST_MXSCOR), then prints the "you
                # would score X out of Y" line and asks whether to quit.
                SCORNG=$TRUE
                score
                SCORNG=$FALSE
                printf "$(format_case '\n If you were to quit now, you would score %d out of a possible %d.\n')" \
                    "$LAST_SCORE" "$LAST_MXSCOR"
                yes 143 54 54
                if (( YES_RESULT == TRUE )); then
                    GAVEUP=$TRUE
                    score
                    break
                fi
            elif (( JVERB == 30 )); then
                # SUSPEND/PAUSE/SAVE — intransitive only.
                do_suspend
                (( SUSPENDED == TRUE )) && break
            elif (( JVERB == 31 )); then
                # HOURS: report the current non-prime-time schedule.
                mspeak 6
                hours
            else
                echo "$(format_case 'You want to do something, but what?')"
            fi
        elif (( noun != -1 )); then
            echo "$(format_case 'What do you want to do with that?')"
        else
            # Always mixed case regardless of USE_MIXEDCASE — matches
            # test_walkthrough.sh's expected transcript (pre-existing
            # behavior, unrelated to the -m/--mixedcase display flag).
            echo "I don't understand that word."
        fi

        # Death (and BLAST/WAKE's forced endings) can now arrive from a verb
        # as well as from a motion word (do_attack's null move runs the dwarf
        # turn and the dark-pit gate), so the check belongs after the whole
        # dispatch, not inside one arm.
        if (( GAME_OVER == TRUE )); then
            break
        fi

        # handle_death's resurrection branch: the player accepted
        # reincarnation, so re-describe the room they've been dropped at
        # instead of continuing to process the command that got them killed.
        if (( RESURRECTED == TRUE )); then
            RESURRECTED=$FALSE
            print_desc "$LOC"
            arrive "$LOC"
            hint_check
            (( HINT_DUE != -1 )) && hint_offer
        fi
    done
}

# format_case TEXT
#   Convert hardcoded literals to UPPERCASE (unless USE_MIXEDCASE set), protecting printf
#   codes (%d/%3d/%s) and \n escapes. Echoes result for $(format_case "...").
function format_case() {
    local text="$1"

    if (( USE_MIXEDCASE == TRUE )); then
        echo "$text"
        return
    fi

    local protected="$text"
    protected="${protected//\\n/@@NL@@}"
    protected="${protected//%3d/@@P3D@@}"
    protected="${protected//%d/@@PD@@}"
    protected="${protected//%s/@@PS@@}"

    protected=$(echo "$protected" | tr '[:lower:]' '[:upper:]')

    protected="${protected//@@NL@@/\\n}"
    protected="${protected//@@P3D@@/%3d}"
    protected="${protected//@@PD@@/%d}"
    protected="${protected//@@PS@@/%s}"

    echo "$protected"
}

# Display usage/help text and exit with code.
function usage() {
    cat << "EOF"
ADVENTURESH - A pure-Bash port of Colossal Cave Adventure (1977)
Version: 1.0

USAGE:
    adventure.sh [OPTIONS]

OPTIONS:
    -h, --help              Display this help message and exit
    -V, --version           Display version information and exit
    -m, --mixedcase         Play in mixed-case mode (readable text instead of all uppercase)
    --history               Display game history and exit
    --crowther              Play in Crowther-compatible mode (Woods engine with Crowther's
                            21-location, 19-object, 14-verb footprint; no scoring, pirate,
                            or closing sequence)
    --data FILE             Load game data from external file instead of embedded data
    --resume [FILE]         Resume a previously suspended game (default: .adventure_save)

EXAMPLES:
    ./adventure.sh                      # Start a new game (350-point version)
    ./adventure.sh --crowther            # Play in Crowther-compatible mode
    ./adventure.sh --resume              # Resume last saved game
    ./adventure.sh --resume=mysave.txt  # Resume from specific file
    ./adventure.sh --data custom.dat    # Use external data file

EOF
    exit "${1:-0}"
}

# Parse command-line arguments for help/version/history; pass through others to main.
function parse_arguments() {
    # First pass: check if --crowther or --data are present (these disable -m)
    local has_crowther=0 has_data=0
    for arg in "$@"; do
        if [[ "$arg" == "--crowther" ]]; then
            has_crowther=1
        elif [[ "$arg" == "--data" ]]; then
            has_data=1
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -V|--version)
                printf '%s %s by %s\n' "$TITLE" "$VERSION" "$AUTHOR"
                printf '%s\n' "$ABOUT"
                exit 0
                ;;
            -m|--mixedcase)
                # Only honor -m if neither --crowther nor --data are present
                if (( has_crowther == 0 && has_data == 0 )); then
                    USE_MIXEDCASE=$TRUE
                fi
                ;;
            --history)
                cat << "EOF"
ADVENTURESH - Game History

Colossal Cave Adventure was originally written by Will Crowther in 1976-77,
exploring the Bedquilt Cave in Kentucky. Don Woods later expanded it in 1977
into the canonical 350-point version with scoring, treasures, the pirate, and
more complex puzzles.

ADVENTURESH is a pure-Bash port of the Crowther-original and Crowther/Woods
350-point versions, translating the original FORTRAN code to idiomatic Bash.

EOF
                exit 0
                ;;
            --crowther|--data|--resume*)
                # Pass through to main()
                return
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage 2
                ;;
        esac
        shift
    done
}

function main() {
    local data_file="$SCRIPT_PATH"

    # --crowther selects the trimmed Crowther-compat dataset and enables
    # CROWTHER_MODE to gate pirate/closing logic. Must set both.
    # --crowther could be $1 or $2 if -m comes first, so check both positions.
    local -i crowther_pos=0
    for (( i=1; i<=$#; i++ )); do
        if [[ "${!i}" == "--crowther" ]]; then
            crowther_pos=$i
            break
        fi
    done

    if (( crowther_pos > 0 )); then
        local crowther_dat
        crowther_dat="$(cd "$(dirname "$0")" && pwd)/advent-crowther.dat"
        if [[ ! -f "$crowther_dat" ]]; then
            printf 'Error: advent-crowther.dat not found at %s\n' "$crowther_dat" >&2
            exit 1
        fi
        data_file="$crowther_dat"
        CROWTHER_MODE=$TRUE
    fi

    # Handle --data FILE flag to load from an external data file instead of embedded data.
    local -i data_pos=0
    for (( i=1; i<=$#; i++ )); do
        if [[ "${!i}" == "--data" ]]; then
            data_pos=$i
            break
        fi
    done

    if (( data_pos > 0 )); then
        data_file="${@:$((data_pos+1)):1}"
    fi

    # --resume (bare, default SAVE_FILE) or --resume=FILE resumes a game
    # suspended with SUSPEND/PAUSE/SAVE instead of starting fresh.
    if [[ "${1:-}" == --resume* ]]; then
        if [[ "$1" == --resume=* ]]; then
            SAVE_FILE="${1#--resume=}"
        fi
        RESUME_REQUESTED=$TRUE
        shift
    fi

    load_data "$data_file"
    parse_travel_table
    init_objects

    # WIZCOM (wizard-hours) config persists independently of the game
    # dataset/save file — load it (or seed poof()'s defaults) before
    # play_game's start_gate() needs WKDAY/WKEND/HOLID/SHORT/LATNCY.
    load_wizcom

    if (( RESUME_REQUESTED == TRUE )); then
        if [[ ! -f "$SAVE_FILE" ]]; then
            echo "No suspended game found at '$SAVE_FILE'." >&2
            exit 1
        fi
        restore_game "$SAVE_FILE"
        # A resumed game re-runs start_gate() to check whether enough time
        # (LATNCY) has elapsed since the suspend. If not, the gate will
        # refuse or exit. play_game's own pre-loop arrival/prologue is
        # skipped for a resumed game (RESUME_REQUESTED==FALSE only), so the
        # restored state is preserved without re-describing the room.
        start_gate
    fi

    # Verification hooks; a real CLI parser comes later.
    if [[ "${1:-}" == "--dump-travel" ]]; then
        shift
        dump_travel_table "${@:-1}"
        return 0
    fi
    # Movement-dispatch spot-checks: --walk LOC MOTION...
    if [[ "${1:-}" == "--walk" ]]; then
        shift
        walk_travel "$@"
        return 0
    fi
    if [[ "${1:-}" == "--dump-objects" ]]; then
        dump_objects
        return 0
    fi
    # Object text spot-checks: --dump-object-text [OBJ...]
    if [[ "${1:-}" == "--dump-object-text" ]]; then
        shift
        dump_object_text "$@"
        return 0
    fi
    # Vocabulary spot-checks: --dump-vocab WORD...
    if [[ "${1:-}" == "--dump-vocab" ]]; then
        shift
        dump_vocab "$@"
        return 0
    fi
    # Action-verb default spot-checks: --dump-actspk [VERB...]
    if [[ "${1:-}" == "--dump-actspk" ]]; then
        shift
        dump_actspk "$@"
        return 0
    fi
    # COND-bit spot-checks: --dump-cond LOC...
    if [[ "${1:-}" == "--dump-cond" ]]; then
        shift
        dump_cond "$@"
        return 0
    fi
    # Hints spot-checks: --dump-hints [HINT#...]
    if [[ "${1:-}" == "--dump-hints" ]]; then
        shift
        dump_hints "$@"
        return 0
    fi
    # Class messages spot-checks: --dump-ctext [THRESHOLD...]
    if [[ "${1:-}" == "--dump-ctext" ]]; then
        shift
        dump_ctext "$@"
        return 0
    fi
    # Magic messages spot-checks: --dump-magic [ID...]
    if [[ "${1:-}" == "--dump-magic" ]]; then
        shift
        dump_magic "$@"
        return 0
    fi

    play_game
}

if (( ${#BASH_SOURCE[@]} > 1 )); then
    return
fi

parse_arguments "$@"
main "$@"

exit 0
DATA_START
1
1	You are standing at the end of a road before a small brick building.
1	Around you is a forest.  A small stream flows out of the building and
1	down a gully.
2	You have walked up a hill, still in the forest.  The road slopes back
2	down the other side of the hill.  There is a building in the distance.
3	You are inside a building, a well house for a large spring.
4	You are in a valley in the forest beside a stream tumbling along a
4	rocky bed.
5	You are in open forest, with a deep valley to one side.
6	You are in open forest near both a valley and a road.
7	At your feet all the water of the stream splashes into a 2-inch slit
7	in the rock.  Downstream the streambed is bare rock.
8	You are in a 20-foot depression floored with bare dirt.  Set into the
8	dirt is a strong steel grate mounted in concrete.  A dry streambed
8	leads into the depression.
9	You are in a small chamber beneath a 3x3 steel grate to the surface.
9	A low crawl over cobbles leads inward to the west.
10	You are crawling over cobbles in a low passage.  There is a dim light
10	at the east end of the passage.
11	You are in a debris room filled with stuff washed in from the surface.
11	A low wide passage with cobbles becomes plugged with mud and debris
11	here, but an awkward canyon leads upward and west.  A note on the wall
11	says "Magic Word: XYZZY".
12	You are in an awkward sloping east/west canyon.
13	You are in a splendid chamber thirty feet high.  The walls are frozen
13	rivers of orange stone.  An awkward canyon and a good passage exit
13	from east and west sides of the chamber.
14	At your feet is a small pit breathing traces of white mist.  An east
14	passage ends here except for a small crack leading on.
15	You are at one end of a vast hall stretching forward out of sight to
15	the west.  There are openings to either side.  Nearby, a wide stone
15	staircase leads downward.  The hall is filled with wisps of white mist
15	swaying to and fro almost as if alive.	A cold wind blows up the
15	staircase.  There is a passage at the top of a dome behind you.
16	The crack is far too small for you to follow.
17	You are on the east bank of a fissure slicing clear across the hall.
17	The mist is quite thick here, and the fissure is too wide to jump.
18	This is a low room with a crude note on the wall.  The note says,
18	"You won't get it up the steps".
19	You are in the hall of the mountain king, with passages off in all
19	directions.
20	You are at the bottom of the pit with a broken neck.
21	You didn't make it.
22	The dome is unclimbable.
23	You are at the west end of the twopit room.  There is a large hole in
23	the wall above the pit at this end of the room.
24	You are at the bottom of the eastern pit in the twopit room.  There is
24	a small pool of oil in one corner of the pit.
25	You are at the bottom of the western pit in the twopit room.  There is
25	a large hole in the wall about 25 feet above you.
26	You clamber up the plant and scurry through the hole at the top.
27	You are on the west side of the fissure in the hall of mists.
28	You are in a low n/s passage at a hole in the floor.  The hole goes
28	down to an e/w passage.
29	You are in the south side chamber.
30	You are in the west side chamber of the hall of the mountain king.
30	A passage continues west and up here.
31	>$<
32	You can't get by the snake.
33	You are in a large room, with a passage to the south, a passage to the
33	west, and a wall of broken rock to the east.  There is a large "Y2" on
33	a rock in the room's center.
34	You are in a jumble of rock, with cracks everywhere.
35	You're at a low window overlooking a huge pit, which extends up out of
35	sight.	A floor is indistinctly visible over 50 feet below.  Traces of
35	white mist cover the floor of the pit, becoming thicker to the right.
35	Marks in the dust around the window would seem to indicate that
35	someone has been here recently.  Directly across the pit from you and
35	25 feet away there is a similar window looking into a lighted room.  A
35	shadowy figure can be seen there peering back at you.
36	You are in a dirty broken passage.  To the east is a crawl.  To the
36	west is a large passage.  Above you is a hole to another passage.
37	You are on the brink of a small clean climbable pit.  A crawl leads
37	west.
38	You are in the bottom of a small pit with a little stream, which
38	enters and exits through tiny slits.
39	You are in a large room full of dusty rocks.  There is a big hole in
39	the floor.  There are cracks everywhere, and a passage leading east.
40	You have crawled through a very low wide passage parallel to and north
40	of the hall of mists.
41	You are at the west end of hall of mists.  A low wide crawl continues
41	west and another goes north.  To the south is a little passage 6 feet
41	off the floor.
42	You are in a maze of twisty little passages, all alike.
43	You are in a maze of twisty little passages, all alike.
44	You are in a maze of twisty little passages, all alike.
45	You are in a maze of twisty little passages, all alike.
46	Dead end
47	Dead end
48	Dead end
49	You are in a maze of twisty little passages, all alike.
50	You are in a maze of twisty little passages, all alike.
51	You are in a maze of twisty little passages, all alike.
52	You are in a maze of twisty little passages, all alike.
53	You are in a maze of twisty little passages, all alike.
54	Dead end
55	You are in a maze of twisty little passages, all alike.
56	Dead end
57	You are on the brink of a thirty foot pit with a massive orange column
57	down one wall.	You could climb down here but you could not get back
57	up.  The maze continues at this level.
58	Dead end
59	You have crawled through a very low wide passage parallel to and north
59	of the hall of mists.
60	You are at the east end of a very long hall apparently without side
60	chambers.  To the east a low wide crawl slants up.  To the north a
60	round two foot hole slants down.
61	You are at the west end of a very long featureless hall.  The hall
61	joins up with a narrow north/south passage.
62	You are at a crossover of a high n/s passage and a low e/w one.
63	Dead end
64	You are at a complex junction.	A low hands and knees passage from the
64	north joins a higher crawl from the east to make a walking passage
64	going west.  There is also a large room above.	The air is damp here.
65	You are in bedquilt, a long east/west passage with holes everywhere.
65	To explore at random select north, south, up, or down.
66	You are in a room whose walls resemble swiss cheese.  Obvious passages
66	go west, east, ne, and nw.  Part of the room is occupied by a large
66	bedrock block.
67	You are at the east end of the twopit room.  The floor here is
67	littered with thin rock slabs, which make it easy to descend the pits.
67	There is a path here bypassing the pits to connect passages from east
67	and west.  There are holes all over, but the only big one is on the
67	wall directly over the west pit where you can't get to it.
68	You are in a large low circular chamber whose floor is an immense slab
68	fallen from the ceiling (slab room).  East and west there once were
68	large passages, but they are now filled with boulders.	Low small
68	passages go north and south, and the south one quickly bends west
68	around the boulders.
69	You are in a secret n/s canyon above a large room.
70	You are in a secret n/s canyon above a sizable passage.
71	You are in a secret canyon at a junction of three canyons, bearing
71	north, south, and se.  The north one is as tall as the other two
71	combined.
72	You are in a large low room.  Crawls lead north, se, and sw.
73	Dead end crawl.
74	You are in a secret canyon which here runs e/w.  It crosses over a
74	very tight canyon 15 feet below.  If you go down you may not be able
74	to get back up.
75	You are at a wide place in a very tight n/s canyon.
76	The canyon here becomes too tight to go further south.
77	You are in a tall e/w canyon.  A low tight crawl goes 3 feet north and
77	seems to open up.
78	The canyon runs into a mass of boulders -- dead end.
79	The stream flows out through a pair of 1 foot diameter sewer pipes.
79	It would be advisable to use the exit.
80	You are in a maze of twisty little passages, all alike.
81	Dead end
82	Dead end
83	You are in a maze of twisty little passages, all alike.
84	You are in a maze of twisty little passages, all alike.
85	Dead end
86	Dead end
87	You are in a maze of twisty little passages, all alike.
88	You are in a long, narrow corridor stretching out of sight to the
88	west.  At the eastern end is a hole through which you can see a
88	profusion of leaves.
89	There is nothing here to climb.  Use "UP" or "OUT" to leave the pit.
90	You have climbed up the plant and out of the pit.
91	You are at the top of a steep incline above a large room.  You could
91	climb down here, but you would not be able to climb up.  There is a
91	passage leading back to the north.
92	You are in the giant room.  The ceiling here is too high up for your
92	lamp to show it.  Cavernous passages lead east, north, and south.  On
92	the west wall is scrawled the inscription, "FEE FIE FOE FOO" [sic].
93	The passage here is blocked by a recent cave-in.
94	You are at one end of an immense north/south passage.
95	You are in a magnificent cavern with a rushing stream, which cascades
95	over a sparkling waterfall into a roaring whirlpool which disappears
95	through a hole in the floor.  Passages exit to the south and west.
96	You are in the soft room.  The walls are covered with heavy curtains,
96	the floor with a thick pile carpet.  Moss covers the ceiling.
97	This is the oriental room.  Ancient oriental cave drawings cover the
97	walls.	A gently sloping passage leads upward to the north, another
97	passage leads se, and a hands and knees crawl leads west.
98	You are following a wide path around the outer edge of a large cavern.
98	Far below, through a heavy white mist, strange splashing noises can be
98	heard.	The mist rises up through a fissure in the ceiling.  The path
98	exits to the south and west.
99	You are in an alcove.  A small nw path seems to widen after a short
99	distance.  An extremely tight tunnel leads east.  It looks like a very
99	tight squeeze.	An eerie light can be seen at the other end.
100	You're in a small chamber lit by an eerie green light.	An extremely
100	narrow tunnel exits to the west.  A dark corridor leads ne.
101	You're in the dark-room.  A corridor leading south is the only exit.
102	You are in an arched hall.  A coral passage once continued up and east
102	from here, but is now blocked by debris.  The air smells of sea water.
103	You're in a large room carved out of sedimentary rock.	The floor and
103	walls are littered with bits of shells imbedded in the stone.  A
103	shallow passage proceeds downward, and a somewhat steeper one leads
103	up.  A low hands and knees passage enters from the south.
104	You are in a long sloping corridor with ragged sharp walls.
105	You are in a cul-de-sac about eight feet across.
106	You are in an anteroom leading to a large passage to the east.	Small
106	passages go west and up.  The remnants of recent digging are evident.
106	A sign in midair here says "Cave under construction beyond this point.
106	Proceed at own risk.  [Witt Construction Company]"
107	You are in a maze of twisty little passages, all different.
108	You are at Witt's End.	Passages lead off in *all* directions.
109	You are in a north/south canyon about 25 feet across.  The floor is
109	covered by white mist seeping in from the north.  The walls extend
109	upward for well over 100 feet.	Suspended from some unseen point far
109	above you, an enormous two-sided mirror is hanging parallel to and
109	midway between the canyon walls.  (The mirror is obviously provided
109	for the use of the dwarves, who as you know, are extremely vain.)  A
109	small window can be seen in either wall, some fifty feet up.
110	You're at a low window overlooking a huge pit, which extends up out of
110	sight.	A floor is indistinctly visible over 50 feet below.  Traces of
110	white mist cover the floor of the pit, becoming thicker to the left.
110	Marks in the dust around the window would seem to indicate that
110	someone has been here recently.  Directly across the pit from you and
110	25 feet away there is a similar window looking into a lighted room.  A
110	shadowy figure can be seen there peering back at you.
111	A large stalactite extends from the roof and almost reaches the floor
111	below.	You could climb down it, and jump from it to the floor, but
111	having done so you would be unable to reach it to climb back up.
112	You are in a little maze of twisting passages, all different.
113	You are at the edge of a large underground reservoir.  An opaque cloud
113	of white mist fills the room and rises rapidly upward.	The lake is
113	fed by a stream, which tumbles out of a hole in the wall about 10 feet
113	overhead and splashes noisily into the water somewhere within the
113	mist.  The only passage goes back toward the south.
114	Dead end
115	You are at the northeast end of an immense room, even larger than the
115	giant room.  It appears to be a repository for the "Adventure"
115	program.  Massive torches far overhead bathe the room with smoky
115	yellow light.  Scattered about you can be seen a pile of bottles (all
115	of them empty), a nursery of young beanstalks murmuring quietly, a bed
115	of oysters, a bundle of black rods with rusty stars on their ends, and
115	a collection of brass lanterns.  Off to one side a great many dwarves
115	are sleeping on the floor, snoring loudly.  A sign nearby reads: "Do
115	not disturb the dwarves!"  An immense mirror is hanging against one
115	wall, and stretches to the other end of the room, where various other
115	sundry objects can be glimpsed dimly in the distance.
116	You are at the southwest end of the repository.  To one side is a pit
116	full of fierce green snakes.  On the other side is a row of small
116	wicker cages, each of which contains a little sulking bird.  In one
116	corner is a bundle of black rods with rusty marks on their ends.  A
116	large number of velvet pillows are scattered about on the floor.  A
116	vast mirror stretches off to the northeast.  At your feet is a large
116	steel grate, next to which is a sign which reads, "Treasure Vault.
116	Keys in Main Office."
117	You are on one side of a large, deep chasm.  A heavy white mist rising
117	up from below obscures all view of the far side.  A sw path leads away
117	from the chasm into a winding corridor.
118	You are in a long winding corridor sloping out of sight in both
118	directions.
119	You are in a secret canyon which exits to the north and east.
120	You are in a secret canyon which exits to the north and east.
121	You are in a secret canyon which exits to the north and east.
122	You are on the far side of the chasm.  A ne path leads away from the
122	chasm on this side.
123	You're in a long east/west corridor.  A faint rumbling noise can be
123	heard in the distance.
124	The path forks here.  The left fork leads NorthEast.  A dull rumbling
124	seems to get louder in that direction.	The right fork leads SouthEast
124	down a gentle slope.  The main corridor enters from the west.
125	The walls are quite warm here.	From the north can be heard a steady
125	roar, so loud that the entire cave seems to be trembling.  Another
125	passage leads south, and a low crawl goes east.
126	You are on the edge of a breath-taking view.  Far below you is an
126	active volcano, from which great gouts of molten lava come surging
126	out, cascading back down into the depths.  The glowing rock fills the
126	farthest reaches of the cavern with a blood-red glare, giving every-
126	thing an eerie, macabre appearance.  The air is filled with flickering
126	sparks of ash and a heavy smell of brimstone.  The walls are hot to
126	the touch, and the thundering of the volcano drowns out all other
126	sounds.  Embedded in the jagged roof far overhead are myriad twisted
126	formations composed of pure white alabaster, which scatter the murky
126	light into sinister apparitions upon the walls.  To one side is a deep
126	gorge, filled with a bizarre chaos of tortured rock which seems to
126	have been crafted by the devil himself.  An immense river of fire
126	crashes out from the depths of the volcano, burns its way through the
126	gorge, and plummets into a bottomless pit far off to your left.  To
126	the right, an immense geyser of blistering steam erupts continuously
126	from a barren island in the center of a sulfurous lake, which bubbles
126	ominously.  The far right wall is aflame with an incandescence of its
126	own, which lends an additional infernal splendor to the already
126	hellish scene.	A dark, foreboding passage exits to the south.
127	You are in a small chamber filled with large boulders.	The walls are
127	very warm, causing the air in the room to be almost stifling from the
127	heat.  The only exit is a crawl heading west, through which is coming
127	a low rumbling.
128	You are walking along a gently sloping north/south passage lined with
128	oddly shaped limestone formations.
129	You are standing at the entrance to a large, barren room.  A sign
129	posted above the entrance reads:  "CAUTION!  Bear in room!"
130	You are inside a barren room.  The center of the room is completely
130	empty except for some dust.  Marks in the dust lead away toward the
130	far end of the room.  The only exit is the way you came in.
131	You are in a maze of twisting little passages, all different.
132	You are in a little maze of twisty passages, all different.
133	You are in a twisting maze of little passages, all different.
134	You are in a twisting little maze of passages, all different.
135	You are in a twisty little maze of passages, all different.
136	You are in a twisty maze of little passages, all different.
137	You are in a little twisty maze of passages, all different.
138	You are in a maze of little twisting passages, all different.
139	You are in a maze of little twisty passages, all different.
140	Dead end
-1	END
2
1	You're at end of road again.
2	You're at hill in road.
3	You're inside building.
4	You're in valley.
5	You're in forest.
6	You're in forest.
7	You're at slit in streambed.
8	You're outside grate.
9	You're below the grate.
10	You're in cobble crawl.
11	You're in debris room.
13	You're in bird chamber.
14	You're at top of small pit.
15	You're in hall of mists.
17	You're on east bank of fissure.
18	You're in nugget of gold room.
19	You're in hall of mt king
23	You're at west end of twopit room.
24	You're in east pit.
25	You're in west pit.
33	You're at "Y2".
35	You're at window on pit.
36	You're in dirty passage.
39	You're in dusty rock room.
41	You're at west end of hall of mists.
57	You're at brink of pit.
60	You're at east end of long hall.
61	You're at west end of long hall.
64	You're at complex junction.
66	You're in swiss cheese room.
67	You're at east end of twopit room.
68	You're in slab room.
71	You're at junction of three secret canyons.
74	You're in secret e/w canyon above tight canyon.
88	You're in narrow corridor.
91	You're at steep incline above large room.
92	You're in giant room.
95	You're in cavern with waterfall.
96	You're in soft room.
97	You're in oriental room.
98	You're in misty cavern.
99	You're in alcove.
100	You're in plover room.
101	You're in dark-room.
102	You're in arched hall.
103	You're in shell room.
106	You're in anteroom.
108	You're at witt's end.
109	You're in mirror canyon.
110	You're at window on pit.
111	You're at top of stalactite.
113	You're at reservoir.
115	You're at ne end.
116	You're at sw end.
117	You're on sw side of chasm.
118	You're in sloping corridor.
122	You're on ne side of chasm.
123	You're in corridor.
124	You're at fork in path.
125	You're at junction with warm walls.
126	You're at breath-taking view.
127	You're in chamber of boulders.
128	You're in limestone passage.
129	You're in front of barren room.
130	You're in barren room.
-1
3
1	2	2	44	29
1	3	3	12	19	43
1	4	5	13	14	46	30
1	5	6	45	43
1	8	63
2	1	2	12	7	43	45	30
2	5	6	45	46
3	1	3	11	32	44
3	11	62
3	33	65
3	79	5	14
4	1	4	12	45
4	5	6	43	44	29
4	7	5	46	30
4	8	63
5	4	9	43	30
5	50005	6	7	45
5	6	6
5	5	44	46
6	1	2	45
6	4	9	43	44	30
6	5	6	46
7	1	12
7	4	4	45
7	5	6	43	44
7	8	5	15	16	46
7	595	60	14	30
8	5	6	43	44	46
8	1	12
8	7	4	13	45
8	303009	3	19	30
8	593	3
9	303008	11	29
9	593	11
9	10	17	18	19	44
9	14	31
9	11	51
10	9	11	20	21	43
10	11	19	22	44	51
10	14	31
11	303008	63
11	9	64
11	10	17	18	23	24	43
11	12	25	19	29	44
11	3	62
11	14	31
12	303008	63
12	9	64
12	11	30	43	51
12	13	19	29	44
12	14	31
13	303008	63
13	9	64
13	11	51
13	12	25	43
13	14	23	31	44
14	303008	63
14	9	64
14	11	51
14	13	23	43
14	150020	30	31	34
14	15	30
14	16	33	44
15	18	36	46
15	17	7	38	44
15	19	10	30	45
15	150022	29	31	34	35	23	43
15	14	29
15	34	55
16	14	1
17	15	38	43
17	312596	39
17	412021	7
17	412597	41	42	44	69
17	27	41
18	15	38	11	45
19	15	10	29	43
19	311028	45	36
19	311029	46	37
19	311030	44	7
19	32	45
19	35074	49
19	211032	49
19	74	66
20	0	1
21	0	1
22	15	1
23	67	43	42
23	68	44	61
23	25	30	31
23	648	52
24	67	29	11
25	23	29	11
25	724031	56
25	26	56
26	88	1
27	312596	39
27	412021	7
27	412597	41	42	43	69
27	17	41
27	40	45
27	41	44
28	19	38	11	46
28	33	45	55
28	36	30	52
29	19	38	11	45
30	19	38	11	43
30	62	44	29
31	524089	1
31	90	1
32	19	1
33	3	65
33	28	46
33	34	43	53	54
33	35	44
33	159302	71
33	100	71
34	33	30	55
34	15	29
35	33	43	55
35	20	39
36	37	43	17
36	28	29	52
36	39	44
36	65	70
37	36	44	17
37	38	30	31	56
38	37	56	29	11
38	595	60	14	30	4	5
39	36	43	23
39	64	30	52	58
39	65	70
40	41	1
41	42	46	29	23	56
41	27	43
41	59	45
41	60	44	17
42	41	29
42	42	45
42	43	43
42	45	46
42	80	44
43	42	44
43	44	46
43	45	43
44	43	43
44	48	30
44	50	46
44	82	45
45	42	44
45	43	45
45	46	43
45	47	46
45	87	29	30
46	45	44	11
47	45	43	11
48	44	29	11
49	50	43
49	51	44
50	44	43
50	49	44
50	51	30
50	52	46
51	49	44
51	50	29
51	52	43
51	53	46
52	50	44
52	51	43
52	52	46
52	53	29
52	55	45
52	86	30
53	51	44
53	52	45
53	54	46
54	53	44	11
55	52	44
55	55	45
55	56	30
55	57	43
56	55	29	11
57	13	30	56
57	55	44
57	58	46
57	83	45
57	84	43
58	57	43	11
59	27	1
60	41	43	29	17
60	61	44
60	62	45	30	52
61	60	43
61	62	45
61	100107	46
62	60	44
62	63	45
62	30	43
62	61	46
63	62	46	11
64	39	29	56	59
64	65	44	70
64	103	45	74
64	106	43
65	64	43
65	66	44
65	80556	46
65	68	61
65	80556	29
65	50070	29
65	39	29
65	60556	45
65	75072	45
65	71	45
65	80556	30
65	106	30
66	65	47
66	67	44
66	80556	46
66	77	25
66	96	43
66	50556	50
66	97	72
67	66	43
67	23	44	42
67	24	30	31
68	23	46
68	69	29	56
68	65	45
69	68	30	61
69	331120	46
69	119	46
69	109	45
69	113	75
70	71	45
70	65	30	23
70	111	46
71	65	48
71	70	46
71	110	45
72	65	70
72	118	49
72	73	45
72	97	48	72
73	72	46	17	11
74	19	43
74	331120	44
74	121	44
74	75	30
75	76	46
75	77	45
76	75	45
77	75	43
77	78	44
77	66	45	17
78	77	46
79	3	1
80	42	45
80	80	44
80	80	46
80	81	43
81	80	44	11
82	44	46	11
83	57	46
83	84	43
83	85	44
84	57	45
84	83	44
84	114	50
85	83	43	11
86	52	29	11
87	45	29	30
88	25	30	56	43
88	20	39
88	92	44	27
89	25	1
90	23	1
91	95	45	73	23
91	72	30	56
92	88	46
92	93	43
92	94	45
93	92	46	27	11
94	92	46	27	23
94	309095	45	3	73
94	611	45
95	94	46	11
95	92	27
95	91	44
96	66	44	11
97	66	48
97	72	44	17
97	98	29	45	73
98	97	46	72
98	99	44
99	98	50	73
99	301	43	23
99	100	43
100	301	44	23	11
100	99	44
100	159302	71
100	33	71
100	101	47	22
101	100	46	71	11
102	103	30	74	11
103	102	29	38
103	104	30
103	114618	46
103	115619	46
103	64	46
104	103	29	74
104	105	30
105	104	29	11
105	103	74
106	64	29
106	65	44
106	108	43
107	131	46
107	132	49
107	133	47
107	134	48
107	135	29
107	136	50
107	137	43
107	138	44
107	139	45
107	61	30
108	95556	43	45	46	47	48	49	50	29	30
108	106	43
108	626	44
109	69	46
109	113	45	75
110	71	44
110	20	39
111	70	45
111	40050	30	39	56
111	50053	30
111	45	30
112	131	49
112	132	45
112	133	43
112	134	50
112	135	48
112	136	47
112	137	44
112	138	30
112	139	29
112	140	46
113	109	46	11	109
114	84	48
115	116	49
116	115	47
116	593	30
117	118	49
117	233660	41	42	69	47
117	332661	41
117	303	41
117	332021	39
117	596	39
118	72	30
118	117	29
119	69	45	11
119	653	43	7
120	69	45
120	74	43
121	74	43	11
121	653	45	7
122	123	47
122	233660	41	42	69	49
122	303	41
122	596	39
122	124	77
122	126	28
122	129	40
123	122	44
123	124	43	77
123	126	28
123	129	40
124	123	44
124	125	47	36
124	128	48	37	30
124	126	28
124	129	40
125	124	46	77
125	126	45	28
125	127	43	17
126	125	46	23	11
126	124	77
126	610	30	39
127	125	44	11	17
127	124	77
127	126	28
128	124	45	29	77
128	129	46	30	40
128	126	28
129	128	44	29
129	124	77
129	130	43	19	40	3
129	126	28
130	129	44	11
130	124	77
130	126	28
131	107	44
131	132	48
131	133	50
131	134	49
131	135	47
131	136	29
131	137	30
131	138	45
131	139	46
131	112	43
132	107	50
132	131	29
132	133	45
132	134	46
132	135	44
132	136	49
132	137	47
132	138	43
132	139	30
132	112	48
133	107	29
133	131	30
133	132	44
133	134	47
133	135	49
133	136	43
133	137	45
133	138	50
133	139	48
133	112	46
134	107	47
134	131	45
134	132	50
134	133	48
134	135	43
134	136	30
134	137	46
134	138	29
134	139	44
134	112	49
135	107	45
135	131	48
135	132	30
135	133	46
135	134	43
135	136	44
135	137	49
135	138	47
135	139	50
135	112	29
136	107	43
136	131	44
136	132	29
136	133	49
136	134	30
136	135	46
136	137	50
136	138	48
136	139	47
136	112	45
137	107	48
137	131	47
137	132	46
137	133	30
137	134	29
137	135	50
137	136	45
137	138	49
137	139	43
137	112	44
138	107	30
138	131	43
138	132	47
138	133	29
138	134	44
138	135	45
138	136	46
138	137	48
138	139	49
138	112	50
139	107	49
139	131	50
139	132	43
139	133	44
139	134	45
139	135	30
139	136	48
139	137	29
139	138	46
139	112	47
140	112	45	11
-1
4
2	Road
2	hill
3	Enter
4	Upstr
5	Downs
6	Fores
7	Forwa
7	conti
7	onwar
8	Back
8	retur
8	retre
9	Valle
10	Stair
11	Out
11	outsi
11	exit
11	leave
12	Build
12	house
13	Gully
14	Strea
15	Rock
16	Bed
17	Crawl
18	Cobbl
19	Inwar
19	insid
19	in
20	Surfa
21	Null
21	nowhe
22	Dark
23	Passa
23	tunne
24	Low
25	Canyo
26	Awkwa
27	Giant
28	View
29	Upwar
29	up
29	u
29	above
29	ascen
30	D
30	downw
30	down
30	desce
31	Pit
32	Outdo
33	Crack
34	Steps
35	Dome
36	Left
37	Right
38	Hall
39	Jump
40	Barre
41	Over
42	Acros
43	East
43	e
44	West
44	w
45	North
45	n
46	South
46	s
47	Ne
48	Se
49	Sw
50	Nw
51	Debri
52	Hole
53	Wall
54	Broke
55	Y2
56	Climb
57	Look
57	exami
57	touch
57	descr
58	Floor
59	Room
60	Slit
61	Slab
61	slabr
62	Xyzzy
63	Depre
64	Entra
65	Plugh
66	Secre
67	Cave
69	Cross
70	Bedqu
71	Plove
72	Orien
73	Caver
74	Shell
75	Reser
76	Main
76	offic
77	Fork
1001	Keys
1001	key
1002	Lamp
1002	headl
1002	lante
1003	Grate
1004	Cage
1005	Rod
1006	Rod	(Must be next object after "real" rod)
1007	Steps
1008	Bird
1009	Door
1010	Pillo
1010	velve
1011	Snake
1012	Fissu
1013	Table
1014	Clam
1015	Oyste
1016	Magaz
1016	issue
1016	spelu
1016	"spel
1017	Dwarf
1017	dwarv
1018	Knife
1018	knive
1019	Food
1019	ratio
1020	Bottl
1020	jar
1021	Water
1021	h2o
1022	Oil
1023	Mirro
1024	Plant
1024	beans
1025	Plant	(Must be next object after "real" plant)
1026	Stala
1027	Shado
1027	figur
1028	Axe
1029	Drawi
1030	Pirat
1031	Drago
1032	Chasm
1033	Troll
1034	Troll	(Must be next object after "real" troll)
1035	Bear
1036	Messa
1037	Volca
1037	geyse	(Same as volcano)
1038	Machi
1038	vendi
1039	Batte
1040	Carpe
1040	moss
1050	Gold
1050	nugge
1051	Diamo
1052	Silve
1052	bars
1053	Jewel
1054	Coins
1055	Chest
1055	box
1055	treas
1056	Eggs
1056	egg
1056	nest
1057	Tride
1058	Vase
1058	ming
1058	shard
1058	potte
1059	Emera
1060	Plati
1060	pyram
1061	Pearl
1062	Rug
1062	persi
1063	Spice
1064	Chain
2001	Carry
2001	take
2001	keep
2001	catch
2001	steal
2001	captu
2001	get
2001	tote
2002	Drop
2002	relea
2002	free
2002	disca
2002	dump
2003	Say
2003	chant
2003	sing
2003	utter
2003	mumbl
2004	Unloc
2004	open
2005	Nothi
2006	Lock
2006	close
2007	Light
2007	on
2008	Extin
2008	off
2009	Wave
2009	shake
2009	swing
2010	Calm
2010	placa
2010	tame
2011	Walk
2011	run
2011	trave
2011	go
2011	proce
2011	conti
2011	explo
2011	goto
2011	follo
2011	turn
2012	Attac
2012	kill
2012	fight
2012	hit
2012	strik
2013	Pour
2014	Eat
2014	devou
2015	Drink
2016	Rub
2017	Throw
2017	toss
2018	Quit
2019	Find
2019	where
2020	Inven
2021	Feed
2022	Fill
2023	Blast
2023	deton
2023	ignit
2023	blowu
2024	Score
2025	Fee
2025	fie
2025	foe
2025	foo
2025	fum
2026	Brief
2027	Read
2027	perus
2028	Break
2028	shatt
2028	smash
2029	Wake
2029	distu
2030	Suspe
2030	pause
2030	save
2031	Hours
3001	Fee
3002	Fie
3003	Foe
3004	Foo
3005	Fum
3050	Sesam
3050	opens
3050	abra
3050	abrac
3050	shaza
3050	hocus
3050	pocus
3051	Help
3051	?
3064	Tree
3064	trees
3066	Dig
3066	excav
3068	Lost
3069	Mist
3079	Fuck
3139	Stop
3142	Info
3142	infor
3147	Swim
-1
5
1	Set of keys
000	There are some keys on the ground here.
2	Brass lantern
000	There is a shiny brass lamp nearby.
100	There is a lamp shining nearby.
3	*Grate
000	The grate is locked.
100	The grate is open.
4	Wicker cage
000	There is a small wicker cage discarded nearby.
5	Black rod
000	A three foot black rod with a rusty star on an end lies nearby.
6	Black rod
000	A three foot black rod with a rusty mark on an end lies nearby.
7	*Steps
000	Rough stone steps lead down the pit.
100	Rough stone steps lead up the dome.
8	Little bird in cage
000	A cheerful little bird is sitting here singing.
100	There is a little bird in the cage.
9	*Rusty door
000	The way north is barred by a massive, rusty, iron door.
100	The way north leads through a massive, rusty, iron door.
10	Velvet pillow
000	A small velvet pillow lies on the floor.
11	*Snake
000	A huge green fierce snake bars the way!
100	>$<  (Chased away)
12	*Fissure
000	>$<
100	A crystal bridge now spans the fissure.
200	The crystal bridge has vanished!
13	*Stone tablet
000	A massive stone tablet imbedded in the wall reads:
000	"Congratulations on bringing light into the dark-room!"
14	Giant clam  >grunt!<
000	There is an enormous clam here with its shell tightly closed.
15	Giant oyster  >groan!<
000	There is an enormous oyster here with its shell tightly closed.
100	Interesting.  There seems to be something written on the underside of
100	the oyster.
16	"Spelunker Today"
000	There are a few recent issues of "Spelunker Today" magazine here.
19	Tasty food
000	There is food here.
20	Small bottle
000	There is a bottle of water here.
100	There is an empty bottle here.
200	There is a bottle of oil here.
21	Water in the bottle
22	Oil in the bottle
23	*Mirror
000	>$<
24	*Plant
000	There is a tiny little plant in the pit, murmuring "water, water, ..."
100	The plant spurts into furious growth for a few seconds.
200	There is a 12-foot-tall beanstalk stretching up out of the pit,
200	bellowing "Water!! Water!!"
300	The plant grows explosively, almost filling the bottom of the pit.
400	There is a gigantic beanstalk stretching all the way up to the hole.
500	You've over-watered the plant!	It's shriveling up!  It's, it's...
25	*Phony plant (seen in twopit room only when tall enough)
000	>$<
100	The top of a 12-foot-tall beanstalk is poking out of the west pit.
200	There is a huge beanstalk growing out of the west pit up to the hole.
26	*Stalactite
000	>$<
27	*Shadowy figure
000	The shadowy figure seems to be trying to attract your attention.
28	Dwarf's axe
000	There is a little axe here.
100	There is a little axe lying beside the bear.
29	*Cave drawings
000	>$<
30	*Pirate
000	>$<
31	*Dragon
000	A huge green fierce dragon bars the way!
100	Congratulations!  You have just vanquished a dragon with your bare
100	hands!	(Unbelievable, isn't it?)
200	The body of a huge green dead dragon is lying off to one side.
32	*Chasm
000	A rickety wooden bridge extends across the chasm, vanishing into the
000	mist.  A sign posted on the bridge reads, "Stop! Pay troll!"
100	The wreckage of a bridge (and a dead bear) can be seen at the bottom
100	of the chasm.
33	*Troll
000	A burly troll stands by the bridge and insists you throw him a
000	treasure before you may cross.
100	The troll steps out from beneath the bridge and blocks your way.
200	>$<  (Chased away)
34	*Phony troll
000	The troll is nowhere to be seen.
35	>$<  (Bear uses rtext 141)
000	There is a ferocious cave bear eying you from the far end of the room!
100	There is a gentle cave bear sitting placidly in one corner.
200	There is a contented-looking bear wandering about nearby.
300	>$<  (Dead)
36	*Message in second maze
000	There is a message scrawled in the dust in a flowery script, reading:
000	"This is not the maze where the pirate leaves his treasure chest."
37	*Volcano and/or geyser
000	>$<
38	*Vending machine
000	There is a massive vending machine here.  The instructions on it read:
000	"Drop coins here to receive fresh batteries."
39	Batteries
000	There are fresh batteries here.
100	Some worn-out batteries have been discarded nearby.
40	*Carpet and/or moss
000	>$<
50	Large gold nugget
000	There is a large sparkling nugget of gold here!
51	Several diamonds
000	There are diamonds here!
52	Bars of silver
000	There are bars of silver here!
53	Precious jewelry
000	There is precious jewelry here!
54	Rare coins
000	There are many coins here!
55	Treasure chest
000	The pirate's treasure chest is here!
56	Golden eggs
000	There is a large nest here, full of golden eggs!
100	The nest of golden eggs has vanished!
200	Done!
57	Jeweled trident
000	There is a jewel-encrusted trident here!
58	Ming vase
000	There is a delicate, precious, ming vase here!
100	The vase is now resting, delicately, on a velvet pillow.
200	The floor is littered with worthless shards of pottery.
300	The ming vase drops with a delicate crash.
59	Egg-sized emerald
000	There is an emerald here the size of a plover's egg!
60	Platinum pyramid
000	There is a platinum pyramid here, 8 inches on a side!
61	Glistening pearl
000	Off to one side lies a glistening pearl!
62	Persian rug
000	There is a persian rug spread out on the floor!
100	The dragon is sprawled out on a persian rug!!
63	Rare spices
000	There are rare spices here!
64	Golden chain
000	There is a golden chain lying in a heap on the floor!
100	The bear is locked to the wall with a golden chain!
200	There is a golden chain locked to the wall!
-1
6
1	Somewhere nearby is colossal cave, where others have found fortunes in
1	treasure and gold, though it is rumored that some who enter are never
1	seen again.  Magic is said to work in the cave.  I will be your eyes
1	and hands.  Direct me with commands of 1 or 2 words.  I should warn
1	you that I look at only the first five letters of each word, so you'll
1	have to enter "NORTHEAST" as "NE" to distinguish it from "NORTH".
1	(Should you get stuck, type "HELP" for some general hints.  For infor-
1	mation on how to end your adventure, etc., Type "INFO".)
1				      - - -
1	This program was originally developed by willie crowther.  Most of the
1	features of the current program were added by don woods (don @ su-ai).
1	Contact don if you have any questions, comments, etc.
2	A little dwarf with a big knife blocks your way.
3	A little dwarf just walked around a corner, saw you, threw a little
3	axe at you which missed, cursed, and ran away.
4	There is a threatening little dwarf in the room with you!
5	One sharp nasty knife is thrown at you!
6	None of them hit you!
7	One of them gets you!
8	A hollow voice says "plugh".
9	There is no way to go that direction.
10	I am unsure how you are facing.  Use compass points or nearby objects.
11	I don't know in from out here.	Use compass points or name something
11	in the general direction you want to go.
12	I don't know how to apply that word here.
13	I don't understand that!
14	I'm game.  Would you care to explain how?
15	Sorry, but I am not allowed to give more detail.  I will repeat the
15	long description of your location.
16	It is now pitch dark.  If you proceed you will likely fall into a pit.
17	If you prefer, simply type w rather than west.
18	Are you trying to catch the bird?
19	The bird is frightened right now and you cannot catch it no matter
19	what you try.  Perhaps you might try later.
20	Are you trying to somehow deal with the snake?
21	You can't kill the snake, or drive it away, or avoid it, or anything
21	like that.  There is a way to get by, but you don't have the necessary
21	resources right now.
22	Do you really want to quit now?
23	You fell into a pit and broke every bone in your body!
24	You are already carrying it!
25	You can't be serious!
26	The bird was unafraid when you entered, but as you approach it becomes
26	disturbed and you cannot catch it.
27	You can catch the bird, but you cannot carry it.
28	There is nothing here with a lock!
29	You aren't carrying it!
30	The little bird attacks the green snake, and in an astounding flurry
30	drives the snake away.
31	You have no keys!
32	It has no lock.
33	I don't know how to lock or unlock such a thing.
34	It was already locked.
35	The grate is now locked.
36	The grate is now unlocked.
37	It was already unlocked.
38	You have no source of light.
39	Your lamp is now on.
40	Your lamp is now off.
41	There is no way to get past the bear to unlock the chain, which is
41	probably just as well.
42	Nothing happens.
43	Where?
44	There is nothing here to attack.
45	The little bird is now dead.  Its body disappears.
46	Attacking the snake both doesn't work and is very dangerous.
47	You killed a little dwarf.
48	You attack a little dwarf, but he dodges out of the way.
49	With what?  Your bare hands?
50	Good try, but that is an old worn-out magic word.
51	I know of places, actions, and things.	Most of my vocabulary
51	describes places and is used to move you there.  To move, try words
51	like FOREST, BUILDING, DOWNSTREAM, ENTER, EAST, WEST, NORTH, SOUTH,
51	UP, or DOWN.  I know about a few special objects, like a black rod
51	hidden in the cave.  These objects can be manipulated using some of
51	the action words that I know.  Usually you will need to give both the
51	object and action words (in either order), but sometimes I can infer
51	the object from the verb alone.  Some objects also imply verbs; in
51	particular, "INVENTORY" implies "TAKE INVENTORY", which causes me to
51	give you a list of what you're carrying.  The objects have side
51	effects; for instance, the rod scares the bird.  Usually people having
51	trouble moving just need to try a few more words.  Usually people
51	trying unsuccessfully to manipulate an object are attempting something
51	beyond their (or my!) Capabilities and should try a completely
51	different tack.  To speed the game you can sometimes move long
51	distances with a single word.  For example, "BUILDING" usually gets
51	you to the building from anywhere above ground except when lost in the
51	forest.  Also, note that cave passages turn a lot, and that leaving a
51	room to the north does not guarantee entering the next from the south.
51	Good luck!
52	It misses!
53	It gets you!
54	Ok
55	You can't unlock the keys.
56	You have crawled around in some little holes and wound up back in the
56	main passage.
57	I don't know where the cave is, but hereabouts no stream can run on
57	the surface for long.  I would try the stream.
58	I need more detailed instructions to do that.
59	I can only tell you what you see as you move about and manipulate
59	things.  I cannot tell you where remote things are.
60	I don't know that word.
61	What?
62	Are you trying to get into the cave?
63	The grate is very solid and has a hardened steel lock.	You cannot
63	enter without a key, and there are no keys nearby.  I would recommend
63	looking elsewhere for the keys.
64	The trees of the forest are large hardwood oak and maple, with an
64	occasional grove of pine or spruce.  There is quite a bit of under-
64	growth, largely birch and ash saplings plus nondescript bushes of
64	various sorts.	This time of year visibility is quite restricted by
64	all the leaves, but travel is quite easy if you detour around the
64	spruce and berry bushes.
65	Welcome to Adventure!!	Would you like instructions?
66	Ddigging without a shovel is quite impractical.  Even with a shovel
66	progress is unlikely.
67	Blasting requires dynamite.
68	I'm as confused as you are.
69	Mist is a white vapor, usually water, seen from time to time in
69	caverns.  It can be found anywhere but is frequently a sign of a deep
69	pit leading down to water.
70	Your feet are now wet.
71	I think I just lost my appetite.
72	Thank you, it was delicious!
73	You have taken a drink from the stream.  The water tastes strongly of
73	minerals, but is not unpleasant.  It is extremely cold.
74	The bottle of water is now empty.
75	Rubbing the electric lamp is not particularly rewarding.  Anyway,
75	nothing exciting happens.
76	Peculiar.  Nothing unexpected happens.
77	Your bottle is empty and the ground is wet.
78	You can't pour that.
79	Watch it!
80	Which way?
81	Oh dear, you seem to have gotten yourself killed.  I might be able to
81	help you out, but I've never really done this before.  Do you want me
81	to try to reincarnate you?
82	All right.  But don't blame me if something goes wr......
82			    --- Poof!! ---
82	You are engulfed in a cloud of orange smoke.  Coughing and gasping,
82	you emerge from the smoke and find....
83	You clumsy oaf, you've done it again!  I don't know how long I can
83	keep this up.  Do you want me to try reincarnating you again?
84	Okay, now where did I put my orange smoke?....	>Poof!<
84	Everything disappears in a dense cloud of orange smoke.
85	Now you've really done it!  I'm out of orange smoke!  You don't expect
85	me to do a decent reincarnation without any orange smoke, do you?
86	Okay, if you're so smart, do it yourself!  I'm leaving!
90	>>> Messages 81 thru 90 are reserved for "obituaries". <<<
91	Sorry, but I no longer seem to remember how it was you got here.
92	You can't carry anything more.	You'll have to drop something first.
93	You can't go through a locked steel grate!
94	I believe what you want is right here with you.
95	You don't fit through a two-inch slit!
96	I respectfully suggest you go across the bridge instead of jumping.
97	There is no way across the fissure.
98	You're not carrying anything.
99	You are currently holding the following:
100	It's not hungry (it's merely pinin' for the fjords).  Besides, you
100	have no bird seed.
101	The snake has now devoured your bird.
102	There's nothing here it wants to eat (except perhaps you).
103	You fool, dwarves eat only coal!  Now you've made him *really* mad!!
104	You have nothing in which to carry it.
105	Your bottle is already full.
106	There is nothing here with which to fill the bottle.
107	Your bottle is now full of water.
108	Your bottle is now full of oil.
109	You can't fill that.
110	Don't be ridiculous!
111	The door is extremely rusty and refuses to open.
112	The plant indignantly shakes the oil off its leaves and asks, "Water?"
113	The hinges are quite thoroughly rusted now and won't budge.
114	The oil has freed up the hinges so that the door will now move,
114	although it requires some effort.
115	The plant has exceptionally deep roots and cannot be pulled free.
116	The dwarves' knives vanish as they strike the walls of the cave.
117	Something you're carrying won't fit through the tunnel with you.
117	You'd best take inventory and drop something.
118	You can't fit this five-foot clam through that little passage!
119	You can't fit this five-foot oyster through that little passage!
120	I advise you to put down the clam before opening it.  >Strain!<
121	I advise you to put down the oyster before opening it.	>Wrench!<
122	You don't have anything strong enough to open the clam.
123	You don't have anything strong enough to open the oyster.
124	A glistening pearl falls out of the clam and rolls away.  Goodness,
124	this must really be an oyster.	(I never was very good at identifying
124	bivalves.)  Whatever it is, it has now snapped shut again.
125	The oyster creaks open, revealing nothing but oyster inside.  It
125	promptly snaps shut again.
126	You have crawled around in some little holes and found your way
126	blocked by a recent cave-in.  You are now back in the main passage.
127	There are faint rustling noises from the darkness behind you.
128	Out from the shadows behind you pounces a bearded pirate!  "Har, har,"
128	he chortles, "I'll just take all this booty and hide it away with me
128	chest deep in the maze!"  He snatches your treasure and vanishes into
128	the gloom.
129	A sepulchral voice reverberating through the cave, says, "Cave closing
129	soon.  All adventurers exit immediately through main office."
130	A mysterious recorded voice groans into life and announces:
130	   "This exit is closed.  Please leave via main office."
131	It looks as though you're dead.  Well, seeing as how it's so close to
131	closing time anyway, I think we'll just call it a day.
132	The sepulchral voice entones, "The cave is now closed."  As the echoes
132	fade, there is a blinding flash of light (and a small puff of orange
132	smoke). . . .	 As your eyes refocus, you look around and find...
133	There is a loud explosion, and a twenty-foot hole appears in the far
133	wall, burying the dwarves in the rubble.  You march through the hole
133	and find yourself in the main office, where a cheering band of
133	friendly elves carry the conquering adventurer off into the sunset.
134	There is a loud explosion, and a twenty-foot hole appears in the far
134	wall, burying the snakes in the rubble.  A river of molten lava pours
134	in through the hole, destroying everything in its path, including you!
135	There is a loud explosion, and you are suddenly splashed across the
135	walls of the room.
136	The resulting ruckus has awakened the dwarves.	There are now several
136	threatening little dwarves in the room with you!  Most of them throw
136	knives at you!	All of them get you!
137	Oh, leave the poor unhappy bird alone.
138	I daresay whatever you want is around here somewhere.
139	I don't know the word "STOP".  Use "QUIT" if you want to give up.
140	You can't get there from here.
141	You are being followed by a very large, tame bear.
142	If you want to end your adventure early, say "QUIT".  To suspend your
142	adventure such that you can continue later, say "SUSPEND" (or "PAUSE"
142	or "SAVE").  To see what hours the cave is normally open, say "HOURS".
142	To see how well you're doing, say "SCORE".  To get full credit for a
142	treasure, you must have left it safely in the building, though you get
142	partial credit just for locating it.  You lose points for getting
142	killed, or for quitting, though the former costs you more.  There are
142	also points based on how much (if any) of the cave you've managed to
142	explore; in particular, there is a large bonus just for getting in (to
142	distinguish the beginners from the rest of the pack), and there are
142	other ways to determine whether you've been through some of the more
142	harrowing sections.  If you think you've found all the treasures, just
142	keep exploring for a while.  If nothing interesting happens, you
142	haven't found them all yet.  If something interesting *does* happen,
142	it means you're getting a bonus and have an opportunity to garner many
142	more points in the master's section.  I may occasionally offer hints
142	if you seem to be having trouble.  If I do, I'll warn you in advance
142	how much it will affect your score to accept the hints.  Finally, to
142	save paper, you may specify "BRIEF", which tells me never to repeat
142	the full description of a place unless you explicitly ask me to.
143	Do you indeed wish to quit now?
144	There is nothing here with which to fill the vase.
145	The sudden change in temperature has delicately shattered the vase.
146	It is beyond your power to do that.
147	I don't know how.
148	It is too far up for you to reach.
149	You killed a little dwarf.  The body vanishes in a cloud of greasy
149	black smoke.
150	The shell is very strong and is impervious to attack.
151	What's the matter, can't you read?  Now you'd best start over.
152	The axe bounces harmlessly off the dragon's thick scales.
153	The dragon looks rather nasty.	You'd best not try to get by.
154	The little bird attacks the green dragon, and in an astounding flurry
154	gets burnt to a cinder.  The ashes blow away.
155	On what?
156	Okay, from now on I'll only describe a place in full the first time
156	you come to it.  To get the full description, say "LOOK".
157	Trolls are close relatives with the rocks and have skin as tough as
157	that of a rhinoceros.  The troll fends off your blows effortlessly.
158	The troll deftly catches the axe, examines it carefully, and tosses it
158	back, declaring, "Good workmanship, but it's not valuable enough."
159	The troll catches your treasure and scurries away out of sight.
160	The troll refuses to let you cross.
161	There is no longer any way across the chasm.
162	Just as you reach the other side, the bridge buckles beneath the
162	weight of the bear, which was still following you around.  You
162	scrabble desperately for support, but as the bridge collapses you
162	stumble back and fall into the chasm.
163	The bear lumbers toward the troll, who lets out a startled shriek and
163	scurries away.	The bear soon gives up the pursuit and wanders back.
164	The axe misses and lands near the bear where you can't get at it.
165	With what?  Your bare hands?  Against *his* bear hands??
166	The bear is confused; he only wants to be your friend.
167	For crying out loud, the poor thing is already dead!
168	The bear eagerly wolfs down your food, after which he seems to calm
168	down considerably and even becomes rather friendly.
169	The bear is still chained to the wall.
170	The chain is still locked.
171	The chain is now unlocked.
172	The chain is now locked.
173	There is nothing here to which the chain can be locked.
174	There is nothing here to eat.
175	Do you want the hint?
176	Do you need help getting out of the maze?
177	You can make the passages look less alike by dropping things.
178	Are you trying to explore beyond the plover room?
179	There is a way to explore that region without having to worry about
179	falling into a pit.  None of the objects available is immediately
179	useful in discovering the secret.
180	Do you need help getting out of here?
181	Don't go west.
182	Gluttony is not one of the troll's vices.  Avarice, however, is.
183	Your lamp is getting dim.  You'd best start wrapping this up, unless
183	you can find some fresh batteries.  I seem to recall there's a vending
183	machine in the maze.  Bring some coins with you.
184	Your lamp has run out of power.
185	There's not much point in wandering around out here, and you can't
185	explore the cave without a lamp.  So let's just call it a day.
186	There are faint rustling noises from the darkness behind you.  As you
186	turn toward them, the beam of your lamp falls across a bearded pirate.
186	He is carrying a large chest.  "Shiver me timbers!" He cries, "I've
186	been spotted!  I'd best hie meself off to the maze to hide me chest!"
186	With that, he vanishes into the gloom.
187	Your lamp is getting dim.  You'd best go back for those batteries.
188	Your lamp is getting dim.  I'm taking the liberty of replacing the
188	batteries.
189	Your lamp is getting dim, and you're out of spare batteries.  You'd
189	best start wrapping this up.
190	I'm afraid the magazine is written in dwarvish.
191	"This is not the maze where the pirate leaves his treasure chest."
192	Hmmm, this looks like a clue, which means it'll cost you 10 points to
192	read it.  Should I go ahead and read it anyway?
193	It says, "There is something strange about this place, such that one
193	of the words I've always known now has a new effect."
194	It says the same thing it did before.
195	I'm afraid I don't understand.
196	"Congratulations on bringing light into the dark-room!"
197	You strike the mirror a resounding blow, whereupon it shatters into a
197	myriad tiny fragments.
198	You have taken the vase and hurled it delicately to the ground.
199	You prod the nearest dwarf, who wakes up grumpily, takes one look at
199	you, curses, and grabs for his axe.
200	Is this acceptable?
201	There's no point in suspending a demonstration game.
-1
7
1	3
2	3
3	8	9
4	10
5	11
6	0
7	14	15
8	13
9	94	-1
10	96
11	19	-1
12	17	27
13	101	-1
14	103
15	0
16	106
17	0	-1
18	0
19	3
20	3
21	0
22	0
23	109	-1
24	25	-1
25	23	67
26	111	-1
27	35	110
28	0
29	97	-1
30	0	-1
31	119	121
32	117	122
33	117	122
34	0	0
35	130	-1
36	0	-1
37	126	-1
38	140	-1
39	0
40	96	-1
50	18
51	27
52	28
53	29
54	30
55	0
56	92
57	95
58	97
59	100
60	101
61	0
62	119	121
63	127
64	130	-1
-1
8
1	24
2	29
3	0
4	33
5	0
6	33
7	38
8	38
9	42
10	14
11	43
12	110
13	29
14	110
15	73
16	75
17	29
18	13
19	59
20	59
21	174
22	109
23	67
24	13
25	147
26	155
27	195
28	146
29	110
30	13
31	13
-1
9
0	1	2	3	4	5	6	7	8	9	10
0	100	115	116	126
2	1	3	4	7	38	95	113	24
1	24
3	46	47	48	54	56	58	82	85	86
3	122	123	124	125	126	127	128	129	130
4	8
5	13
6	19
7	42	43	44	45	46	47	48	49	50	51
7	52	53	54	55	56	80	81	82	86	87
8	99	100	101
9	108
-1
10
35	You are obviously a rank amateur.  Better luck next time.
100	Your score qualifies you as a novice class adventurer.
130	You have achieved the rating: "Experienced Adventurer".
200	You may now consider yourself a "Seasoned Adventurer".
250	You have reached "Junior Master" status.
300	Your score puts you in master adventurer class c.
330	Your score puts you in master adventurer class b.
349	Your score puts you in master adventurer class a.
9999	All of adventuredom gives tribute to you, adventurer grandmaster!
-1
11
2	9999	10	0	0
3	9999	5	0	0
4	4	2	62	63
5	5	2	18	19
6	8	2	20	21
7	75	4	176	177
8	25	5	178	179
9	20	3	180	181
-1
12
1	A large cloud of green smoke appears in front of you.  It clears away
1	to reveal a tall wizard, clothed in grey.  He fixes you with a steely
1	glare and declares, "This adventure has lasted too long."  With that
1	he makes a single pass over you with his hands, and everything around
1	you fades away into a grey nothingness.
2	Even wizards have to wait longer than that!
3	I'm terribly sorry, but colossal cave is closed.  Our hours are:
4	Only wizards are permitted within the cave right now.
5	We do allow visitors to make short explorations during our off hours.
5	Would you like to do that?
6	Colossal cave is open to regular adventurers at the following hours:
7	Very well.
8	Only a wizard may continue an adventure this soon.
9	I suggest you resume your adventure at a later time.
10	Do you wish to see the hours?
11	Do you wish to change the hours?
12	New magic word (null to leave unchanged):
13	New magic number (null to leave unchanged):
14	Do you wish to change the message of the day?
15	Okay.  You can save this version now.
16	Are you a wizard?
17	Prove it!  Say the magic word!
18	That is not what I thought it was.  Do you know what I thought it was?
19	Oh dear, you really *are* a wizard!  Sorry to have bothered you . . .
20	Foo, you are nothing but a charlatan!
21	New hours specified by defining "Prime Time".  Give only the hour
21	(e.G. 14, not 14:00 or 2pm).  Enter a negative number after last pair.
22	New hours for colossal cave:
23	Limit lines to 70 chars.  End with null line.
24	Line too long, retype:
25	Not enough room for another line.  Ending message here.
26	Do you wish to (re)schedule the next holiday?
27	To begin how many days from today?
28	To last how many days (zero if no holiday)?
29	To be called what (up to 20 characters)?
30	Too small!  Assuming minimum value (45 minutes).
31	Break out of this and save your core-image.
32	Be sure to save your core-image...
-1
0
