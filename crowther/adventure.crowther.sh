#!/usr/bin/env bash
# A pure Bash port of Colossal Cave Adventure (1977) the original version
# written by Will Crowther in 1976

set -u

declare -r TRUE=0
declare -r FALSE=1

declare -r TRAVEL_SCALE=1024

declare -r TRAVEL_ANY=1

declare -r TRAVEL_MAX_KEYWORDS=10

# --- Global State Arrays ---
declare -a LLINE
declare -a IOBJ ICHAIN IPLACE IFIXED COND PROP ABB
declare -a LTEXT STEXT KEY DEFAULT TRAVEL
declare -a TK KTAB ATAB BTEXT
declare -a RTEXT

for i in {1..300}; do
    IOBJ[$i]=0; ICHAIN[$i]=0; IPLACE[$i]=0; IFIXED[$i]=0; COND[$i]=0; PROP[$i]=0; ABB[$i]=0
    LTEXT[$i]=0; STEXT[$i]=0; KEY[$i]=0; DEFAULT[$i]=0; TRAVEL[$i]=0
    if (( i <= 100 )); then RTEXT[$i]=0; fi
    if (( i <= 200 )); then BTEXT[$i]=0; fi
done

declare -r -i KEYS=1
declare -r -i LAMP=2
declare -r -i GRATE=3
declare -r -i ROD=5
declare -r -i BIRD=7
declare -r -i NUGGET=10
declare -r -i SNAKE=11
declare -r -i FISSUR=12
declare -r -i FOOD=19
declare -r -i WATER=20
declare -r -i AXE=21

declare -r -a JSPKT=(0 24 29 0 31 0 31 38 38 42 42 43 46 77 71 73 75)

# ---------------------------------------------------------------------------
#  Object placement
# ---------------------------------------------------------------------------

declare -i IDWARF=0
declare -i IFIRST=1
declare -i IWEST=0
declare -i ILONG=1

# init_objects
# Initialize object placement and game state; must be called directly, not in $(...).
function init_objects() {
    local -i i ktem

    local -a iplt=(0 3 3 8 10 11 14 13 9 15 18 19 17 27 28 29 30 0 0 3 3)
    local -a ifixt=(0 0 0 1 0 0 1 0 1 1 0 1 1 0 0 0 0 0 0 0 0)

    for (( i = 1; i <= 100; i++ )); do
        IPLACE[i]=${iplt[i]:-0}
        IFIXED[i]=${ifixt[i]:-0}
        ICHAIN[i]=0
    done

    for (( i = 1; i <= 300; i++ )); do IOBJ[i]=0; done

    for (( i = 1; i <= 10; i++ )); do COND[i]=1; done
    for i in 16 20 21 22 23 24 25 26 31 32 79; do COND[i]=2; done

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

    IDWARF=0
    IFIRST=1
    IWEST=0
    ILONG=1
    IDETAL=0

    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        DLOC[i]=0
        ODLOC[i]=0
        DSEEN[i]=0
    done
}

# dump_objects
# Debug aid for verifying init_objects.
function dump_objects() {
    local -i room obj

    for (( room = 1; room <= 100; room++ )); do
        (( ${IOBJ[room]:-0} == 0 )) && continue
        printf 'room %3d:' "$room"
        obj=${IOBJ[room]}
        while (( obj != 0 )); do
            printf ' obj=%-3d%s' "$obj" "$( (( ${IFIXED[obj]:-0} != 0 )) && echo '(fixed)' )"
            obj=${ICHAIN[obj]:-0}
        done
        printf '\n'
    done

    local -i i unplaced=0
    for (( i = 1; i <= AXE; i++ )); do
        (( ${IPLACE[i]:-0} == 0 )) || continue
        (( unplaced == 0 )) && printf 'unplaced:'
        printf ' obj=%d' "$i"
        unplaced=1
    done
    (( unplaced == 1 )) && printf '\n'
}

# --- Parser and Loader ---

declare -a RAW_TEXT
declare -a RAW_SHORT
declare -a RAW_TRAVEL=()
declare -a VOCAB_ID=()
declare -a VOCAB_WORD=()
declare -a OBJ_TEXT
declare -a RAW_MSG

function load_data() {
    echo "Loading game data..."
    local section=-1
    local id text
    local in_data=0
    local vocab_idx=0

    while IFS= read -r line; do
        if (( in_data == 0 )); then
            [[ "$line" == "DATA_START" ]] && in_data=1
            continue
        fi

        if [[ "$line" == "-1"* ]]; then
            continue
        fi

        if [[ "$line" == "0" ]]; then
            break
        fi

        if [[ "$line" =~ ^[1-6]$ ]]; then
            section="$line"
            continue
        fi
        
        if (( section == 1 )); then
            read -r id text <<< "$line"
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                RAW_TEXT[$id]="${RAW_TEXT[$id]:-}${text}\n"
            fi
        elif (( section == 2 )); then
            read -r id text <<< "$line"
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                RAW_SHORT[$id]="${RAW_SHORT[$id]:-}${text}\n"
            fi
        elif (( section == 3 )); then
            RAW_TRAVEL+=("$line")
        elif (( section == 4 )); then
            read -r id text <<< "$line"
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                VOCAB_ID[$vocab_idx]=$id
                VOCAB_WORD[$vocab_idx]=$text
                ((vocab_idx++))
            fi
        elif (( section == 5 )); then
            read -r id text <<< "$line"
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                OBJ_TEXT[$id]="${OBJ_TEXT[$id]:-}${text}\n"
            fi
        elif (( section == 6 )); then
            read -r id text <<< "$line"
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                RAW_MSG[$id]="${RAW_MSG[$id]:-}${text}\n"
            fi
        fi
    done < "$0"
    echo "Data loaded."
}

# ---------------------------------------------------------------------------
#  Travel table
# ---------------------------------------------------------------------------

declare -a TRAVEL_SRC TRAVEL_DEST TRAVEL_KEY TRAVEL_LAST
declare -i TRAVEL_COUNT=0

# parse_travel_table
# Parse travel table from data; must be called directly, not in $(...).
function parse_travel_table() {
    local line src dest kw
    local -a fields
    local -i idx=1 n=0

    for line in "${RAW_TRAVEL[@]}"; do
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 3 )) || continue

        src=${fields[0]}
        dest=${fields[1]}

        if (( ${KEY[$src]:-0} == 0 )); then
            KEY[$src]=$idx
        else
            TRAVEL[$((idx - 1))]=$(( -TRAVEL[idx - 1] ))
        fi

        for (( n = 2; n < ${#fields[@]} && n - 2 < TRAVEL_MAX_KEYWORDS; n++ )); do
            kw=${fields[$n]}
            (( kw == 0 )) && break

            TRAVEL[$idx]=$(( dest * TRAVEL_SCALE + kw ))
            TRAVEL_SRC[$idx]=$src
            (( idx++ ))
        done

        TRAVEL[$((idx - 1))]=$(( -TRAVEL[idx - 1] ))
    done

    TRAVEL_COUNT=$(( idx - 1 ))

    for (( n = 1; n <= TRAVEL_COUNT; n++ )); do
        local packed=${TRAVEL[$n]}
        if (( packed < 0 )); then
            TRAVEL_LAST[$n]=$TRUE
            packed=$(( -packed ))
        else
            TRAVEL_LAST[$n]=$FALSE
        fi
        TRAVEL_DEST[$n]=$(( packed / TRAVEL_SCALE ))
        TRAVEL_KEY[$n]=$(( packed % TRAVEL_SCALE ))
    done
}

# dump_travel_table ROOM...
# Debug aid for verifying the travel table.
function dump_travel_table() {
    local room i

    for room in "$@"; do
        i=${KEY[$room]:-0}
        if (( i == 0 )); then
            printf 'room %3d: no travel entries\n' "$room"
            continue
        fi
        printf 'room %3d: KEY=%d\n' "$room" "$i"
        while true; do
            printf '  [%3d] dest=%-4s motion=%-4s packed=%-7s%s\n' \
                "$i" "${TRAVEL_DEST[$i]}" "${TRAVEL_KEY[$i]}" "${TRAVEL[$i]}" \
                "$( (( TRAVEL_KEY[i] == TRAVEL_ANY )) && echo ' (any motion)')"
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
# Print message from data section 6.
function speak() {
    echo -e "${RAW_MSG[$1]:-}"
}

# ran_gt PERCENT
# Return true if random draw exceeds threshold.
function ran_gt() {
    (( RANDOM % 100 >= $1 ))
}

# ---------------------------------------------------------------------------
#  Movement
# ---------------------------------------------------------------------------

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
declare -r MOT_SOUTH=46
declare -r MOT_XYZZY=48
declare -r MOT_LOOK=57
declare -r MOT_CAVE=67
declare -r MOT_TURN=68

declare -r COND_DEST_BASE=300

declare -r COND_FORCED=2

declare -r MOT_NULL=21

declare -r -i DARK_PIT_PCT=25

declare -r MAX_FORCED_MOVES=20

declare -i LOC=1
declare -i LOLD=1

declare -i IDETAL=0

declare -i JVERB=0

declare -i IDARK=0

declare -i GAME_OVER=$FALSE

declare -i MOVE_RESULT=$FALSE

declare -i NEXT_LOC=1

# refuse_motion MOTION_ID
# Print refusal message for invalid motion.
function refuse_motion() {
    local -i k=$1
    local -i jspk=12

    (( k >= MOT_EAST && k <= MOT_SOUTH )) && jspk=9
    (( k == MOT_UP || k == MOT_DOWN )) && jspk=9
    (( k == MOT_FORWARD || k == MOT_BACK || k == MOT_LEFT \
       || k == MOT_RIGHT || k == MOT_TURN )) && jspk=10
    (( k == MOT_OUT || k == MOT_IN )) && jspk=11
    (( JVERB == 1 )) && jspk=59
    (( k == MOT_XYZZY )) && jspk=42
    (( k == MOT_CRAWL )) && jspk=80

    speak "$jspk"
}

# travel_choose MOTION_ID
# Pick destination from current room; must be called directly, not in $(...).
function travel_choose() {
    local -i k=$1
    local -i kk temp

    kk=${KEY[$LOC]:-0}

    if (( kk == 0 )); then
        speak 13
        NEXT_LOC=$LOC
        (( IFIRST == 0 )) && speak 14
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
        temp=$LOLD
        LOLD=$LOC
        NEXT_LOC=$temp
        return
    fi

    LOLD=$LOC

    while true; do
        if (( TRAVEL_KEY[kk] == TRAVEL_ANY || TRAVEL_KEY[kk] == k )); then
            NEXT_LOC=${TRAVEL_DEST[$kk]}
            return
        fi
        if (( TRAVEL_LAST[kk] == TRUE )); then
            refuse_motion "$k"
            NEXT_LOC=$LOC
            return
        fi
        (( kk++ ))
    done
}

# resolve_cond_dest DEST
# Resolve conditional destination to a real room; must be called directly, not in $(...).
function resolve_cond_dest() {
    local -i dest=$1

    case $dest in
        300)
            NEXT_LOC=6
            ran_gt 50 && NEXT_LOC=5
            ;;
        301)
            NEXT_LOC=23
            (( PROP[GRATE] != 0 )) && NEXT_LOC=9
            ;;
        302)
            NEXT_LOC=9
            (( PROP[GRATE] != 0 )) && NEXT_LOC=8
            ;;
        303)
            NEXT_LOC=20
            (( IPLACE[NUGGET] != -1 )) && NEXT_LOC=15
            ;;
        304)
            NEXT_LOC=22
            (( IPLACE[NUGGET] != -1 )) && NEXT_LOC=14
            ;;
        305)
            echo "GAME IS OVER"
            GAME_OVER=$TRUE
            return $FALSE
            ;;
        306)
            NEXT_LOC=27
            (( PROP[FISSUR] == 0 )) && NEXT_LOC=31
            ;;
        307|308|309)
            NEXT_LOC=$(( dest - 279 ))
            (( PROP[SNAKE] == 0 )) && NEXT_LOC=32
            ;;
        310)
            NEXT_LOC=8
            (( PROP[GRATE] == 0 )) && NEXT_LOC=9
            ;;
        311)
            NEXT_LOC=68
            ran_gt 20 && { NEXT_LOC=65; speak 56; }
            ;;
        312)
            if ran_gt 20; then
                NEXT_LOC=65
                speak 56
            else
                NEXT_LOC=39
                ran_gt 50 && NEXT_LOC=70
            fi
            ;;
        313)
            NEXT_LOC=66
            if ran_gt 40; then
                speak 56
            else
                NEXT_LOC=71
                ran_gt 25 && NEXT_LOC=72
            fi
            ;;
        314)
            NEXT_LOC=66
            if ran_gt 20; then
                speak 56
            else
                NEXT_LOC=77
            fi
            ;;
        *)
            NEXT_LOC=$LOC
            ;;
    esac

    return $TRUE
}

# attempt_motion MOTION_ID
# Execute travel: choose destination, resolve conditionals, describe result.
# Must be called directly, not in $(...).
function attempt_motion() {
    local -i k=$1
    local -i start=$LOC
    local -i steps=0

    if (( IDARK != 0 )) && ! ran_gt "$DARK_PIT_PCT"; then
        speak 23
        echo "GAME IS OVER"
        GAME_OVER=$TRUE
        MOVE_RESULT=$FALSE
        return
    fi

    while (( steps++ < MAX_FORCED_MOVES )); do
        travel_choose "$k"

        if (( NEXT_LOC >= COND_DEST_BASE )); then
            if ! resolve_cond_dest "$NEXT_LOC"; then
                MOVE_RESULT=$FALSE
                return
            fi
        fi

        dwarf_blocks "$NEXT_LOC" && NEXT_LOC=$LOC

        LOC=$NEXT_LOC

        if ! dwarf_turn; then
            MOVE_RESULT=$FALSE
            return
        fi

        print_desc "$LOC"

        if (( COND[LOC] != COND_FORCED )); then
            arrive "$LOC"
            MOVE_RESULT=$(( LOC == start ? FALSE : TRUE ))
            return
        fi
    done

    MOVE_RESULT=$(( LOC == start ? FALSE : TRUE ))
}

# arrive ROOM
# Finalize arrival: bump visit count, determine if room is dark.
# Must be called directly, not in $(...).
function arrive() {
    local -i j=$1

    (( j == 33 )) && ! ran_gt 25 && speak 8

    LOC=$j

    ABB[$j]=$(( (ABB[j] + 1) % 5 ))

    IDARK=0
    if (( COND[j] % 2 == 0 )); then
        if (( IPLACE[LAMP] != j && IPLACE[LAMP] != -1 )) || (( PROP[LAMP] == 0 )); then
            IDARK=1
            speak 16
        fi
    fi
}

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

# parse_command COMMAND
#   Parses a two-word player command into vocabulary IDs. Returns a space-separated
#   pair "ID1 ID2" (-1 if a word is unknown/absent). Echoes the result for capture
#   via $(...), safe to call in a subshell.
function parse_command() {
    local cmd=$1
    local w1="" w2=""
    read -r w1 w2 <<< "$cmd"

    local id1=-1
    local id2=-1

    [[ -n "$w1" ]] && id1=$(get_vocab_id "$w1")
    [[ -n "$w2" ]] && id2=$(get_vocab_id "$w2")

    echo "$id1 $id2"
}

# ---------------------------------------------------------------------------
#  Dwarves
# ---------------------------------------------------------------------------

declare -r -i MAX_DWARVES=3

declare -a DLOC ODLOC DSEEN

declare -r -a DTRAV=(0 36 28 19 30 62 60 41 27 17 15 19 28 36 300 300)

declare -r -i DWARF_HALL=15

declare -r -i DWARF_WAKE_PCT=5
declare -r -i DWARF_KNIFE_PCT=10

declare -r -i DWARF_AXE_PCT=40

declare -r -i DWARF_CLOCK_IN=8
declare -r -i DWARF_CLOCK_OUT=23

declare -r -i DWARF_FOLLOW_ABOVE=14

# dwarf_blocks DEST
# Check if a dwarf blocks movement to DEST.
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

# dwarf_turn
# Run dwarf AI; must be called directly, not in $(...).
function dwarf_turn() {
    local -i i clock idx
    local -i dtot=0 attack=0 stick=0

    if (( IDWARF == 0 )); then
        (( LOC == DWARF_HALL )) && IDWARF=1
        return $TRUE
    fi

    if (( IDWARF == 1 )); then
        ran_gt $DWARF_WAKE_PCT && return $TRUE
        IDWARF=2
        for (( i = 1; i <= MAX_DWARVES; i++ )); do
            DLOC[i]=0
            ODLOC[i]=0
            DSEEN[i]=0
        done
        speak 3
        ICHAIN[AXE]=${IOBJ[LOC]}
        IOBJ[LOC]=$AXE
        IPLACE[AXE]=$LOC
        return $TRUE
    fi

    (( IDWARF++ ))
    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        clock=$(( 2 * i + IDWARF ))
        (( clock < DWARF_CLOCK_IN )) && continue
        (( clock > DWARF_CLOCK_OUT && DSEEN[i] == 0 )) && continue

        ODLOC[i]=${DLOC[i]}

        if (( DSEEN[i] == 0 || LOC <= DWARF_FOLLOW_ABOVE )); then
            idx=$(( clock - DWARF_CLOCK_IN ))
            DLOC[i]=${DTRAV[idx]:-0}
            DSEEN[i]=0
            (( DLOC[i] != LOC && ODLOC[i] != LOC )) && continue
        fi

        DSEEN[i]=1
        DLOC[i]=$LOC
        (( dtot++ ))
        (( ODLOC[i] != DLOC[i] )) && continue
        (( attack++ ))
        ran_gt $DWARF_KNIFE_PCT || (( stick++ ))
    done

    (( dtot == 0 )) && return $TRUE

    if (( dtot == 1 )); then
        speak 4
    else
        printf ' THERE ARE %2d THREATENING LITTLE DWARVES IN THE ROOM WITH YOU.\n\n' "$dtot"
    fi

    (( attack == 0 )) && return $TRUE

    if (( attack == 1 )); then
        speak 5
        speak $(( 52 + stick ))
        (( stick == 0 )) && return $TRUE
    else
        printf ' %2d OF THEM THROW KNIVES AT YOU!\n\n' "$attack"
        if (( stick == 0 )); then
            speak 7
            return $TRUE
        fi
        if (( stick == 1 )); then
            speak 6
        else
            printf ' %2d OF THEM GET YOU.\n\n' "$stick"
        fi
    fi

    echo "GAME IS OVER"
    GAME_OVER=$TRUE
    return $FALSE
}

# ---------------------------------------------------------------------------
#  Object interaction (verbs)
# ---------------------------------------------------------------------------

# object_here OBJ
# Check if object is in current room or carried.
function object_here() {
    local -i obj=$1
    (( IPLACE[obj] == LOC || IPLACE[obj] == -1 ))
}

# do_take OBJ
# Take an object; must be called directly, not in $(...).
function do_take() {
    local -i obj=$1
    local -i itemp

    if (( obj == 18 )); then
        speak 54
        return
    fi

    if (( IPLACE[obj] != LOC )); then
        speak "${JSPKT[1]}"
        return
    fi

    if (( IFIXED[obj] != 0 )); then
        speak 25
        return
    fi

    if (( obj == BIRD )); then
        if (( IPLACE[ROD] == -1 )); then
            speak 26   # carrying the rod scares the bird off
            return
        fi
        if (( IPLACE[4] != -1 && IPLACE[4] != LOC )); then
            speak 27   # cage (object 4) not accessible to catch it with
            return
        fi
    fi

    IPLACE[obj]=-1

    if (( IOBJ[LOC] == obj )); then
        IOBJ[LOC]=${ICHAIN[obj]}
    else
        itemp=${IOBJ[LOC]}
        while (( ICHAIN[itemp] != obj )); do
            itemp=${ICHAIN[itemp]}
        done
        ICHAIN[itemp]=${ICHAIN[obj]}
    fi

    speak 54
}

# do_drop OBJ
# Drop an object; must be called directly, not in $(...).
function do_drop() {
    local -i obj=$1

    if (( obj == 18 )); then
        speak 54
        return
    fi

    if (( IPLACE[obj] != -1 )); then
        speak "${JSPKT[2]}"
        return
    fi

    if (( obj == BIRD && LOC == 19 && PROP[SNAKE] == 0 )); then
        speak 30
        PROP[SNAKE]=1
    else
        speak 54
    fi

    ICHAIN[obj]=${IOBJ[LOC]}
    IOBJ[LOC]=$obj
    IPLACE[obj]=$LOC
}

# do_lock OBJ
# Lock an object; must be called directly, not in $(...).
function do_lock() {
    local -i obj=$1

    if (( IPLACE[KEYS] != -1 && IPLACE[KEYS] != LOC )); then
        speak 31
        return
    fi

    if (( obj == 4 )); then
        speak 32
        return
    fi

    if (( obj == KEYS )); then
        speak 55
        return
    fi

    if (( obj != GRATE )); then
        speak 33
        return
    fi

    if (( PROP[GRATE] == 0 )); then
        speak 34
        return
    fi

    speak 35
    PROP[GRATE]=0
    PROP[8]=0
}

# do_unlock OBJ
# Unlock an object; must be called directly, not in $(...).
function do_unlock() {
    local -i obj=$1

    if (( IPLACE[KEYS] != -1 && IPLACE[KEYS] != LOC )); then
        speak 31
        return
    fi

    if (( obj == 4 )); then
        speak 32
        return
    fi

    if (( obj == KEYS )); then
        speak 55
        return
    fi

    if (( obj != GRATE )); then
        speak 33
        return
    fi

    if (( PROP[GRATE] != 0 )); then
        speak 36
        return
    fi

    speak 37
    PROP[GRATE]=1
    PROP[8]=1
}

# do_light OBJ
# Light the lamp; must be called directly, not in $(...).
function do_light() {
    local -i obj=$1

    if (( IPLACE[LAMP] != LOC && IPLACE[LAMP] != -1 )); then
        speak 31
        return
    fi

    PROP[LAMP]=1
    IDARK=0
    speak 39
}

# do_extinguish OBJ
# Extinguish the lamp; must be called directly, not in $(...).
function do_extinguish() {
    local -i obj=$1

    if (( IPLACE[LAMP] != LOC && IPLACE[LAMP] != -1 )); then
        speak 31
        return
    fi

    PROP[LAMP]=0
    speak 40
}

# do_strike OBJ
# Strike an object; must be called directly, not in $(...).
function do_strike() {
    local -i obj=$1

    if (( obj != FISSUR )); then
        speak 31
        return
    fi

    PROP[FISSUR]=1
}

# do_attack OBJ [VERB_WORD]
# Attack object or dwarf; must be called directly, not in $(...).
function do_attack() {
    local -i obj=$1
    local word=${2:-ATTACK}
    local -i itemp i iid=0

    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        if (( DSEEN[i] != 0 )); then
            iid=$i
            break
        fi
    done

    if (( iid != 0 )); then
        if ran_gt "$DWARF_AXE_PCT"; then
            speak 48
        else
            DSEEN[iid]=0
            ODLOC[iid]=0
            DLOC[iid]=0
            speak 47
        fi

        attempt_motion "$MOT_NULL"
        return
    fi

    if (( obj == 0 )); then
        printf '  %-5s WHAT?\n\n' "${word:0:5}"
        return
    fi

    if (( obj == SNAKE )); then
        speak 46
        return
    fi

    if (( obj != BIRD )); then
        speak 44
        return
    fi

    speak 45
    IPLACE[obj]=300

    if (( IOBJ[LOC] == obj )); then
        IOBJ[LOC]=${ICHAIN[obj]}
    else
        itemp=${IOBJ[LOC]}
        while (( ICHAIN[itemp] != obj )); do
            itemp=${ICHAIN[itemp]}
        done
        ICHAIN[itemp]=${ICHAIN[obj]}
    fi
}

# --- Main Engine ---

# get_object_text
# Return text for an object based on its PROP state.
function get_object_text() {
    local -i obj=$1
    local -i text_id=0

    if (( PROP[obj] == 0 )); then
        if [[ -n "${OBJ_TEXT[obj+200]:-}" ]]; then
            text_id=$((obj + 200))
        elif [[ -n "${OBJ_TEXT[obj]:-}" ]]; then
            text_id=$obj
        fi
    else
        if [[ -n "${OBJ_TEXT[obj+100]:-}" ]]; then
            text_id=$((obj + 100))
        elif [[ -n "${OBJ_TEXT[obj]:-}" ]]; then
            text_id=$obj
        fi
    fi

    [[ $text_id -gt 0 ]] && echo -e "${OBJ_TEXT[$text_id]:-}"
}

function print_desc() {
    local -i room=$1

    if [[ ${ABB[$room]:-0} == 0 || -z "${RAW_SHORT[$room]:-}" ]]; then
        echo -e "${RAW_TEXT[$room]:-}"
    else
        echo -e "${RAW_SHORT[$room]:-}"
    fi

    local -i obj=${IOBJ[room]:-0}
    while (( obj != 0 )); do
        get_object_text "$obj"
        obj=${ICHAIN[obj]:-0}
    done
}

function play_game() {
    print_desc "$LOC"
    arrive "$LOC"

    while true; do
        read -p "> " cmd
        cmd=$(echo "$cmd" | tr '[:lower:]' '[:upper:]')

        if [[ "$cmd" == "QUIT" || "$cmd" == "EXIT" ]]; then
            echo "Quitting game."
            break
        fi

        if [[ -n "$cmd" ]]; then
            local parsed
            parsed=$(parse_command "$cmd")
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

            if (( msg != -1 )); then
                echo "Special Action ID: $msg (Not yet implemented)"
            elif (( motion != -1 )); then
                attempt_motion "$motion"
            elif (( verb != -1 && noun != -1 )); then
                local -i objnum=$(( noun - 1000 ))
                if (( JVERB == 1 || JVERB == 2 )); then
                    if object_here "$objnum"; then
                        if (( JVERB == 1 )); then
                            do_take "$objnum"
                        else
                            do_drop "$objnum"
                        fi
                    else
                        echo "I SEE NO SUCH THING HERE."
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
                elif (( JVERB == 12 )); then
                    do_attack "$objnum"
                else
                    echo "Action ID: $verb on Object ID: $noun (Not yet implemented)"
                fi
            elif (( verb != -1 )); then
                if (( JVERB == 12 )); then
                    do_attack 0 "${cmd%% *}"
                else
                    echo "You want to do something, but what?"
                fi
            elif (( noun != -1 )); then
                echo "What do you want to do with that?"
            else
                echo "I don't understand that word."
            fi

            (( GAME_OVER == TRUE )) && break
        fi
    done
}

function main() {
    load_data
    parse_travel_table
    init_objects

    if [[ "${1:-}" == "--dump-travel" ]]; then
        shift
        dump_travel_table "${@:-1}"
        return 0
    fi
    if [[ "${1:-}" == "--dump-objects" ]]; then
        dump_objects
        return 0
    fi

    play_game
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

exit 0
DATA_START
1
1	 YOU ARE STANDING AT THE END OF A ROAD BEFORE A SMALL BRICK
1	 BUILDING . AROUND YOU IS A FOREST. A SMALL
1	 STREAM FLOWS OUT OF THE BUILDING AND DOWN A GULLY.
2	 YOU HAVE WALKED UP A HILL, STILL IN THE FOREST
2	 THE ROAD NOW SLOPES BACK DOWN THE OTHER SIDE OF THE HILL.
2	 THERE IS A BUILDING IN THE DISTANCE.
3	 YOU ARE INSIDE A BUILDING, A WELL HOUSE FOR A LARGE SPRING.
4	 YOU ARE IN A VALLEY IN THE FOREST BESIDE A STREAM TUMBLING
4	 ALONG A ROCKY BED.
5	 YOU ARE IN OPEN FOREST, WITH A DEEP VALLEY TO ONE SIDE.
6	 YOU ARE IN OPEN FOREST NEAR BOTH A VALLEY AND A ROAD.
7	 AT YOUR FEET ALL THE WATER OF THE STREAM SPLASHES INTO A
7	 2 INCH SLIT IN THE ROCK. DOWNSTREAM THE STREAMBED IS BARE ROCK.
8	 YOU ARE IN A 20 FOOT DEPRESSION FLOORED WITH BARE DIRT. SET INTO
8	 THE DIRT IS A STRONG STEEL GRATE MOUNTED IN CONCRETE. A DRY
8	 STREAMBED LEADS INTO THE DEPRESSION.
9	 YOU ARE IN A SMALL CHAMBER BENEATH A 3X3 STEEL GRATE TO THE
9	 SURFACE. A LOW CRAWL OVER COBBLES LEADS INWARD TO THE WEST.
10	 YOU ARE CRAWLING OVER COBBLES IN A LOW PASSAGE. THERE IS A
10	 DIM LIGHT AT THE EAST END OF THE PASSAGE.
11	 YOU ARE IN A DEBRIS ROOM, FILLED WITH STUFF WASHED IN FROM
11	 THE SURFACE. A LOW WIDE PASSAGE WITH COBBLES BECOMES
11	 PLUGGED WITH MUD AND DEBRIS HERE,BUT AN AWKWARD CANYON
11	 LEADS UPWARD AND WEST.
11	 A NOTE ON THE WALL SAYS 'MAGIC WORD XYZZY'.
12	 YOU ARE IN AN AWKWARD SLOPING EAST/WEST CANYON.
13	 YOU ARE IN A SPLENDID CHAMBER THIRTY FEET HIGH. THE WALLS
13	 ARE FROZEN RIVERS OF ORANGE STONE. AN AWKWARD CANYON AND A
13	 GOOD PASSAGE EXIT FROM EAST AND WEST SIDES OF THE CHAMBER.
14	 AT YOUR FEET IS A SMALL PIT BREATHING TRACES OF WHITE MIST. AN
14	 EAST PASSAGE ENDS HERE EXCEPT FOR A SMALL CRACK LEADING ON.
15	 YOU ARE AT ONE END OF A VAST HALL STRETCHING FORWARD OUT OF
15	 SIGHT TO THE WEST. THERE ARE OPENINGS TO EITHER SIDE. NEARBY, A WIDE
15	 STONE STAIRCASE LEADS DOWNWARD. THE HALL IS FILLED WITH
15	 WISPS OF WHITE MIST SWAYING TO AND FRO ALMOST AS IF ALIVE.
15	 A COLD WIND BLOWS UP THE STAIRCASE. THERE IS A PASSAGE
15	 AT THE TOP OF A DOME BEHIND YOU.
16	 THE CRACK IS FAR TOO SMALL FOR YOU TO FOLLOW.
17	 YOU ARE ON THE EAST BANK OF A FISSURE SLICING CLEAR ACROSS
17	 THE HALL. THE MIST IS QUITE THICK HERE, AND THE FISSURE IS
17	 TOO WIDE TO JUMP.
18	 THIS IS A LOW ROOM WITH A CRUDE NOTE ON THE WALL.
18	 IT SAYS 'YOU WON'T GET IT UP THE STEPS'.
19	 YOU ARE IN THE HALL OF THE MOUNTAIN KING, WITH PASSAGES
19	 OFF IN ALL DIRECTIONS.
20	 YOU ARE AT THE BOTTOM OF THE PIT WITH A BROKEN NECK.
21	 YOU DIDN'T MAKE IT
22	 THE DOME IS UNCLIMBABLE
23	 YOU CAN'T GO IN THROUGH A LOCKED STEEL GRATE!
24	 YOU DON'T FIT DOWN A TWO INCH HOLE!
25	 YOU CAN'T GO THROUGH A LOCKED STEEL GRATE.
27	 YOU ARE ON THE WEST SIDE OF THE FISSURE IN THE HALL OF MISTS.
28	 YOU ARE IN A LOW N/S PASSAGE AT A HOLE IN THE FLOOR.
28	 THE HOLE GOES DOWN TO AN E/W PASSAGE.
29	 YOU ARE IN THE SOUTH SIDE CHAMBER.
30	 YOU ARE IN THE WEST SIDE CHAMBER OF HALL OF MT KING.
30	 A PASSAGE CONTINUES WEST AND UP HERE.

31	 THERE IS NO WAY ACROSS THE FISSURE.
32	 YOU CAN'T GET BY THE SNAKE
33	 YOU ARE IN A LARGE ROOM, WITH A PASSAGE TO THE SOUTH,
33	 A PASSAGE TO THE WEST, AND A WALL OF BROKEN ROCK TO
33	 THE EAST. THERE IS A LARGE 'Y2' ON A ROCK IN ROOMS CENTER.
34	 YOU ARE IN A JUMBLE OF ROCK, WITH CRACKS EVERYWHERE.
35	 YOU ARE AT A WINDOW ON A HUGE PIT, WHICH GOES UP AND
35	 DOWN OUT OF SIGHT. A FLOOR IS INDISTINCTLY VISIBLE
35	 OVER 50 FEET BELOW. DIRECTLY OPPOSITE YOU AND 25 FEET AWAY
35	 THERE IS A SIMILAR WINDOW.
36	 YOU ARE IN A DIRTY BROKEN PASSAGE. TO THE EAST IS A CRAWL.
36	 TO THE WEST IS A LARGE PASSAGE. ABOVE YOU IS A HOLE TO
36	 ANOTHER PASSAGE.
37	 YOU ARE ON THE BRINK OF A SMALL CLEAN CLIMBABLE PIT.
37	 A CRAWL LEADS WEST.
38	 YOU ARE IN THE BOTTOM OF A SMALL PIT WITH A LITTLE
38	 STREAM, WHICH ENTERS AND EXITS THROUGH TINY SLITS.
39	 YOU ARE IN A LARGE ROOM FULL OF DUSTY ROCKS. THERE IS A
39	 BIG HOLE IN THE FLOOR. THERE ARE CRACKS EVERYWHERE, AND
39	 A PASSAGE LEADING EAST.
40	 YOU HAVE CRAWLED THROUGH A VERY LOW WIDE PASSAGE PARALLEL
40	 TO AND NORTH OF THE HALL OF MISTS.
41	 YOU ARE AT THE WEST END OF HALL OF MISTS. A LOW WIDE CRAWL
41	 CONTINUES WEST AND ANOTHER GOES NORTH. TO THE SOUTH IS A
41	 LITTLE PASSAGE 6 FEET OFF THE FLOOR.
42	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
43	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
44	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
45	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
46	 DEAD END
47	 DEAD END
48	 DEAD END
49	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
50	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
51	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
52	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
53	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
54	 DEAD END
55	 YOU ARE IN A MAZE OF TWISTY LITTLE PASSAGES, ALL ALIKE.
56	 DEAD END
57	 YOU ARE ON THE BRINK OF A THIRTY FOOT PIT WITH A MASSIVE
57	 ORANGE COLUMN DOWN ONE WALL. YOU COULD CLIMB DOWN HERE
57	 BUT YOU COULD NOT GET BACK UP. THE MAZE CONTINUES AT THIS
57	 LEVEL.
58	 DEAD END
59	 YOU HAVE CRAWLED THROUGH A VERY LOW WIDE PASSAGE PARALLEL
59	 TO AND NORTH OF THE HALL OF MISTS.
60	 YOU ARE AT THE EAST END OF A VERY LONG HALL APPARENTLY
60	 WITHOUT SIDE CHAMBERS. TO THE EAST A LOW WIDE CRAWL SLANTS
60	 UP. TO THE NORTH A ROUND TWO FOOT HOLE SLANTS DOWN.
61	 YOU ARE AT THE WEST END OF A VERY LONG FEATURELESS HALL.
62	 YOU ARE AT A CROSSOVER OF A HIGH N/S PASSAGE AND A LOW E/W ONE.
63	 DEAD END
64	 YOU ARE AT A COMPLEX JUNCTION. A LOW HANDS AND KNEES
64	 PASSAGE FROM THE NORTH JOINS A HIGHER CRAWL
64	 FROM THE EAST TO MAKE  A WALKING PASSAGE GOING WEST
64	 THERE IS ALSO A LARGE ROOM ABOVE. THE AIR IS DAMP HERE.
64	 A SIGN IN MIDAIR HERE SAYS 'CAVE UNDER CONSTRUCTION BEYOND
64	 THIS POINT. PROCEED AT OWN RISK.'
65	 YOU ARE IN BEDQUILT, A LONG EAST/WEST PASSAGE WITH HOLES EVERYWHERE.
65	 TO EXPLORE AT RANDOM SELECT NORTH, SOUTH, UP, OR DOWN.
66	 YOU ARE IN A ROOM WHOSE WALLS RESEMBLE SWISS CHEESE.
66	 OBVIOUS PASSAGES GO WEST,EAST,NE, AND
66	 NW. PART OF THE ROOM IS OCCUPIED BY A LARGE BEDROCK BLOCK.
67	 YOU ARE IN THE TWOPIT ROOM. THE FLOOR
67	 HERE IS LITTERED WITH THIN ROCK SLABS, WHICH MAKE IT
67	 EASY TO DESCEND THE PITS. THERE IS A PATH HERE BYPASSING
67	 THE PITS TO CONNECT PASSAGES FROM EAST AND WEST.THERE
67	 ARE HOLES ALL OVER, BUT THE ONLY BIG ONE IS ON THE WALL
67	 DIRECTLY OVER THE EAST PIT WHERE YOU CAN'T GET TO IT.
68	 YOU ARE IN A LARGE LOW CIRCULAR CHAMBER WHOSE FLOOR IS AN
68	 IMMENSE SLAB FALLEN FROM THE CEILING(SLAB ROOM). EAST AND
68	 WEST THERE ONCE WERE LARGE PASSAGES, BUT THEY ARE NOW FILLED
68	 WITH BOULDERS. LOW SMALL PASSAGES GO NORTH AND SOUTH, AND THE
68	 SOUTH ONE QUICKLY BENDS WEST AROUND THE BOULDERS.
69	 YOU ARE IN A SECRET NS CANYON ABOVE A LARGE ROOM.
70	 YOU ARE IN A SECRET N/S CANYON ABOVE A SIZABLE PASSAGE.
71	 YOU ARE IN SECRET CANYON AT A JUNCTION OF THREE CANYONS,
71	 BEARING NORTH, SOUTH, AND SE. THE NORTH ONE IS AS TALL
71	 AS THE OTHER TWO COMBINED.
72	 YOU ARE IN A LARGE LOW ROOM. CRAWLS LEAD N, SE, AND SW.
73	 DEAD END CRAWL.
74	 YOU ARE IN SECRET CANYON WHICH HERE RUNS E/W. IT CROSSES OVER
74	 A VERY TIGHT CANYON 15 FEET BELOW. IF YOU GO DOWN YOU MAY
74	 NOT BE ABLE TO GET BACK UP
75	 YOU ARE AT A WIDE PLACE IN A VERY TIGHT N/S CANYON.
76	 THE CANYON HERE BECOMES TO TIGHT TO GO FURTHER SOUTH.
77	 YOU ARE IN A TALL E/W CANYON. A LOW TIGHT CRAWL GOES 3 FEET
77	 NORTH AND SEEMS TO OPEN UP.
78	 THE CANYON RUNS INTO A MASS OF BOULDERS - DEAD END.
79	 THE STREAM FLOWS OUT THROUGH A PAIR OF 1 FOOT DIAMETER SEWER
79	 PIPES. IT WOULD BE ADVISABLE TO USE THE DOOR.
-1	END
2
1	 YOU'RE AT END OF ROAD AGAIN.
2	 YOU'RE AT HILL IN ROAD.
3	 YOU'RE INSIDE BUILDING.
4	 YOU'RE IN VALLEY
5	 YOU'RE IN FOREST
6	 YOU'RE IN FOREST
7	 YOU'RE AT SLIT IN STREAMBED
8	 YOU'RE OUTSIDE GRATE
9	 YOU'RE BELOW THE GRATE
10	 YOU'RE IN COBBLE CRAWL
11	 YOU'RE IN DEBRIS ROOM.
13	 YOU'RE IN BIRD CHAMBER.
14	 YOU'RE AT TOP OF SMALL PIT.
15	 YOU'RE IN HALL OF MISTS.
17	 YOU'RE ON EAST BANK OF FISSURE.
18	 YOU'RE IN NUGGET OF GOLD ROOM.
19	 YOU'RE IN HALL OF MT KING.
33	 YOU'RE AT Y2
35	 YOU'RE AT WINDOW ON PIT
36	 YOU'RE IN DIRTY PASSAGE
39	 YOU'RE N DUSTY ROCK ROOM.
41	 YOU'RE AT WEST END OF HALL OF MISTS.
57	 YOU'RE AT BRINK OF PIT.
60	 YOU'RE AT EAST END OF LONG HALL.
66	 YOU'RE IN SWISS CHEESE ROOM
67	 YOU'RE IN TWOPIT ROOM
68	 YOU'RE IN SLAB ROOM
-1
3
1	2	2	44
1	3	3	12	19	43
1	4	4	5	13	14	46	30
1	5	6	45	43
1	8	49
2	1	8	2	12	7	43	45	30
2	5	6	45	46
3	1	3	11	32	44
3	11	48
3	33	65
3	79	5	14
4	1	4	45
4	5	6	43	44	29
4	7	5	46	30
4	8	49
5	4	9	43	30
5	300	6	7	8	45
5	5	44	46
6	1	2	45
6	4	9	43	44	30
6	5	6	46
7	1	12
7	4	4	45
7	5	6	43	44
7	8	5	15	16	46	30
7	24	47	14	30
8	5	6	43	44	46
8	1	12
8	7	4	13	45
8	301	3	5	19	30
9	302	11	12
9	10	17	18	19	44
9	14	31
9	11	51
10	9	11	20	21	43
10	11	19	22	44	51
10	14	31
11	310	49
11	10	17	18	23	24	43
11	12	25	305	19	29	44
11	3	48
11	14	31
12	310	49
12	11	30	43	51
12	13	19	29	44
12	14	31
13	310	49
13	11	51
13	12	25	305	43
13	14	23	31	44
14	310	49
14	11	51
14	13	23	43
14	303	30	31	34
14	16	33	44
15	18	36	46
15	17	7	38	44
15	19	10	30	45
15	304	29	31	34	35	23	43
15	34	55
15	62	69
16	14	1
17	15	8	38	43
17	305	7
17	306	40	41	42	44	19	39
18	15	38	11	8	45
19	15	10	29	43
19	307	45	36
19	308	46	37
19	309	44	7
19	74	66
20	26	1
21	26	1
22	15	1
23	8	1
24	7	1
25	9	1
27	17	8	11	38
27	40	45
27	41	44
28	19	38	11	46
28	33	45
28	36	30	52
29	19	38	11	45
30	19	38	11	43
30	62	44	29
31	17	1
32	19	1
33	3	65
33	28	46
33	34	43	53	54
33	35	44
34	33	30
34	15	29
35	33	43	55
36	37	43	17
36	28	29	52
36	39	44
37	36	44	17
37	38	30	31	56
38	37	56	29
39	36	43
39	64	30	52	58
39	65	70
40	41	1
41	42	46	29	23	56
41	27	43
41	59	45
41	60	44	17
42	41	44
42	43	43
42	44	46
43	42	44
43	44	46
43	45	43
44	42	45
44	43	43
44	48	30
44	50	46
45	43	45
45	46	43
45	47	46
46	45	44	11
47	45	45	11
48	44	29	11
49	50	30	43
49	51	44
50	44	43
50	49	44	29
50	52	46
51	49	44
51	52	43
51	53	46
52	50	45
52	51	44
52	53	29
52	55	43
53	51	44
53	52	45
53	54	46
54	53	43	11
55	52	44
55	56	30
55	57	43
56	55	29	11
57	55	44
57	58	46
57	13	30	56
58	57	44	11
59	27	1
60	41	43	29
60	61	44
60	62	45	30
61	60	43	11
62	60	44
62	63	45
62	30	43
62	15	46
63	62	46	11
64	39	29	56	59
64	65	44
65	64	43
65	66	44
65	68	61
65	311	46
65	312	29
66	313	45
66	65	60
66	67	44
66	77	25
66	314	46
67	66	43
67	72	60
68	66	46
68	69	29
69	68	30
69	74	46
70	71	45
71	39	29
71	65	62
71	70	46
72	67	63
72	73	45
73	72	46
74	19	43
74	69	44
74	75	30
75	76	46
75	77	45
76	75	45
77	75	43
77	78	44
77	66	45
78	77	46
79	3	1
-1
4
2	ROAD
3	ENTER
3	DOOR
3	GATE
4	UPSTR
5	DOWNS
6	FORES
7	FORWA
7	CONTI
7	ONWAR
8	BACK
8	RETUR
8	RETRE
9	VALLE
10	STAIR
11	OUT
11	OUTSI
11	EXIT
11	LEAVE
12	BUILD
12	BLD
12	HOUSE
13	GULLY
14	STREA
15	ROCK
16	BED
17	CRAWL
18	COBBL
19	INWAR
19	INSID
19	IN
20	SURFA
21	NULL
21	NOWHE
22	DARK
23	PASSA
24	LOW
25	CANYO
26	AWKWA
29	UPWAR
29	UP
29	U
29	ABOVE
30	D
30	DOWNW
30	DOWN
31	PIT
32	OUTDO
33	CRACK
34	STEPS
35	DOME
36	LEFT
37	RIGHT
38	HALL
39	JUMP
40	MAGIC
41	OVER
42	ACROS
43	EAST
43	E
44	WEST
44	W
45	NORTH
45	N
46	SOUTH
46	S
47	SLIT
48	XYZZY
49	DEPRE
50	ENTRA
51	DEBRI
52	HOLE
53	WALL
54	BROKE
55	Y2
56	CLIMB
57	LOOK
57	EXAMI
57	TOUCH
57	LOOKA
58	FLOOR
59	ROOM
60	NE
61	SLAB
61	SLABR
62	SE
63	SW
64	NW
65	PLUGH
66	SECRE
67	CAVE
68	TURN
69	CROSS
70	BEDQU
1001	KEYS
1001	KEY
1002	LAMP
1002	HEADL
1003	GRATE
1004	CAGE
1005	ROD
1006	STEPS
1007	BIRD
1010	NUGGE
1010	GOLD
1011	SNAKE
1012	FISSU
1013	DIAMO
1014	SILVE
1014	BARS
1015	JEWEL
1016	COINS
1017	DWARV
1017	DWARF
1018	KNIFE
1018	KNIVE
1018	ROCK
1018	WEAPO
1018	BOULD
1019	FOOD
1019	RATIO
1020	WATER
1020	BOTTL
1021	AXE
1022	KNIFE
1023	CHEST
1023	BOX
1023	TREAS
2001	TAKE
2001	CARRY
2001	KEEP
2001	PICKU
2001	PICK
2001	WEAR
2001	CATCH
2001	STEAL
2001	CAPTU
2001	FIND
2001	WHERE
2001	GET
2002	RELEA
2002	FREE
2002	DISCA
2002	DROP
2002	DUMP
2003	DUMMY
2004	UNLOC
2004	OPEN
2004	LIFT
2005	NOTHI
2005	HOLD
2006	LOCK
2006	CLOSE
2007	LIGHT
2007	ON
2008	EXTIN
2008	OFF
2009	STRIK
2010	CALM
2010	WAVE
2010	SHAKE
2010	SING
2010	CLEAV
2011	WALK
2011	RUN
2011	TRAVE
2011	GO
2011	PROCE
2011	CONTI
2011	EXPLO
2011	GOTO
2011	FOLLO
2012	ATTAC
2012	KILL
2012	STAB
2012	FIGHT
2012	HIT
2013	POUR
2014	EAT
2015	DRINK
2016	RUB
3050	OPENS
3051	HELP
3051	?
3051	WHAT
3064	TREE
3066	DIG
3066	EXCIV
3067	BLAST
3068	LOST
3069	MIST
3049	THROW
3079	FUCK
-1
5
201	 THERE ARE SOME KEYS ON THE GROUND HERE.
202	 THERE IS A SHINY BRASS LAMP NEARBY.
3	 THE GRATE IS LOCKED
103	 THE GRATE IS OPEN.
204	 THERE IS A SMALL WICKER CAGE DISCARDED NEARBY.
205	 A THREE FOOT BLACK ROD WITH A RUSTY STAR ON AN END LIES NEARBY
206	 ROUGH STONE STEPS LEAD DOWN THE PIT.
7	 A CHEERFUL LITTLE BIRD IS SITTING HERE SINGING.
107	 THERE IS A LITTLE BIRD IN THE CAGE.
8	 THE GRATE IS LOCKED
108	 THE GRATE IS OPEN.
209	 ROUGH STONE STEPS LEAD UP THE DOME.
210	 THERE IS A LARGE SPARKLING NUGGET OF GOLD HERE!
11	 A HUGE GREEN FIERCE SNAKE BARS THE WAY!
112	 A CRYSTAL BRIDGE NOW SPANS THE FISSURE.
213	 THERE ARE DIAMONDS HERE!
214	 THERE ARE BARS OF SILVER HERE!
215	 THERE IS PRECIOUS JEWELRY HERE!
216	 THERE ARE MANY COINS HERE!
19	 THERE IS FOOD HERE.
20	 THERE IS A BOTTLE OF WATER HERE.
120	 THERE IS AN EMPTY BOTTLE HERE.
221	 THERE IS A LITTLE AXE HERE
-1
6
1	 SOMEWHERE NEARBY IS COLOSSAL CAVE, WHERE OTHERS HAVE FOUND
1	 FORTUNES IN TREASURE AND GOLD, THOUGH IT IS RUMORED
1	 THAT SOME WHO ENTER ARE NEVER SEEN AGAIN. MAGIC IS SAID
1	 TO WORK IN THE CAVE.  I WILL BE YOUR EYES AND HANDS. DIRECT
1	 ME WITH COMMANDS OF 1 OR 2 WORDS.
1	 (ERRORS, SUGGESTIONS, COMPLAINTS TO CROWTHER)
1	 (IF STUCK TYPE HELP FOR SOME HINTS)
2	 A LITTLE DWARF WITH A BIG KNIFE BLOCKS YOUR WAY.
3	 A LITTLE DWARF JUST WALKED AROUND A CORNER,SAW YOU, THREW
3	 A LITTLE AXE AT YOU WHICH MISSED, CURSED, AND RAN AWAY.
4	 THERE IS A THREATENING LITTLE DWARF IN THE ROOM WITH YOU!
5	 ONE SHARP NASTY KNIFE IS THROWN AT YOU!
6	 HE GETS YOU!
7	 NONE OF THEM HIT YOU!
8	 A HOLLOW VOICE SAYS 'PLUGH'
9	 THERE IS NO WAY TO GO THAT DIRECTION.
10	 I AM UNSURE HOW YOU ARE FACING. USE COMPASS POINTS OR
10	 NEARBY OBJECTS.
11	 I DON'T KNOW IN FROM OUT HERE. USE COMPASS POINTS OR NAME
11	 SOMETHING IN THE GENERAL DIRECTION YOU WANT TO GO.
12	 I DON'T KNOW HOW TO APPLY THAT WORD HERE.
13	 I DON'T UNDERSTAND THAT!
14	 I ALWAYS UNDERSTAND COMPASS DIRECTIONS, OR YOU CAN NAME
14	 A NEARBY THING TO HEAD THAT WAY.
15	 SORRY, BUT I AM NOT ALLOWED TO GIVE MORE DETAIL. I WILL
15	 REPEAT THE LONG DESCRIPTION OF YOUR LOCATION.
16	 IT IS NOW PITCH BLACK. IF YOU PROCEED YOU WILL LIKELY
16	 FALL INTO A PIT.
17	 IF YOU PREFER, SIMPLY TYPE W RATHER THAN WEST.
18	 ARE YOU TRYING TO CATCH THE BIRD?
19	 THE BIRD IS FRIGHTENED RIGHT NOW AND YOU CANNOT CATCH IT
19	 NO MATTER WHAT YOU TRY. PERHAPS YOU MIGHT TRY LATER.
20	 ARE YOU TRYING TO ATTACK OR AVOID THE SNAKE?
21	 YOU CAN'T KILL THE SNAKE, OR DRIVE IT AWAY, OR AVOID IT,
21	 OR ANYTHING LIKE THAT. THERE IS A WAY TO GET BY, BUT YOU
21	 DON'T HAVE THE NECESSARY RESOURCES RIGHT NOW.
22	 MY WORD FOR HITTING SOMETHING WITH THE ROD IS 'STRIKE'.
23	 YOU FELL INTO A PIT AND BROKE EVERY BONE IN YOUR BODY!
24	 YOU ARE ALREADY CARRYING IT!
25	 YOU CAN'T BE SERIOUS!
26	 THE BIRD WAS UNAFRAID WHEN YOU ENTERED, BUT AS YOU APPROACH
26	 IT BECOMES DISTURBED AND YOU CANNOT CATCH IT.
27	 YOU CAN CATCH THE BIRD, BUT YOU CANNOT CARRY IT.
28	 THERE IS NOTHING HERE WITH A LOCK!
29	 YOU AREN'T CARRYING IT!
30	 THE LITTLE BIRD ATTACKS THE GREEN SNAKE, AND IN AN
30	 ASTOUNDING FLURRY DRIVES THE SNAKE AWAY.
31	 YOU HAVE NO KEYS!
32	 IT HAS NO LOCK.
33	 I DON'T KNOW HOW TO LOCK OR UNLOCK SUCH A THING.
34	 THE GRATE WAS ALREADY LOCKED.
35	 THE GRATE IS NOW LOCKED.
36	 THE GRATE WAS ALREADY UNLOCKED.
37	 THE GRATE IS NOW UNLOCKED.
38	 YOU HAVE NO SOURCE OF LIGHT.
39	 YOUR LAMP IS NOW ON.
40	 YOUR LAMP IS NOW OFF.
41	 STRIKE WHAT?
42	 NOTHING HAPPENS.
43	 WHERE?
44	 THERE IS NOTHING HERE TO ATTACK.
45	 THE LITTLE BIRD IS NOW DEAD. ITS BODY DISAPPEARS.
46	 ATTACKING THE SNAKE BOTH DOESN'T WORK AND IS VERY DANGEROUS.
47	 YOU KILLED A LITTLE DWARF.
48	 YOU ATTACK A LITTLE DWARF, BUT HE DODGES OUT OF THE WAY.
49	 I HAVE TROUBLE WITH THE WORD 'THROW' BECAUSE YOU CAN THROW
49	 A THING OR THROW AT A THING. PLEASE USE DROP OR ATTACK INSTEAD.
50	 GOOD TRY, BUT THAT IS AN OLD WORN-OUT MAGIC WORD.
51	 I KNOW OF PLACES, ACTIONS, AND THINGS. MOST OF MY VOCABULARY
51	 DESCRIBES PLACES AND IS USED TO MOVE YOU THERE. TO MOVE TRY
51	 WORDS LIKE FOREST, BUILDING, DOWNSTREAM, ENTER, EAST, WEST
51	 NORTH, SOUTH, UP, OR DOWN.  I KNOW ABOUT A FEW SPECIAL OBJECTS,
51	 LIKE A BLACK ROD HIDDEN IN THE CAVE. THESE OBJECTS CAN BE
51	 MANIPULATED USING ONE OF THE ACTION WORDS THAT I KNOW. USUALLY 
51	 YOU WILL NEED TO GIVE BOTH THE OBJECT AND ACTION WORDS
51	 (IN EITHER ORDER), BUT SOMETIMES I CAN INFER THE OBJECT FROM
51	 THE VERB ALONE. THE OBJECTS HAVE SIDE EFFECTS - FOR
51	 INSTANCE, THE ROD SCARES THE BIRD.
51	 USUALLY PEOPLE HAVING TROUBLE MOVING JUST NEED TO TRY A FEW
51	 MORE WORDS. USUALLY PEOPLE TRYING TO MANIPULATE AN
51	 OBJECT ARE ATTEMPTING SOMETHING BEYOND THEIR (OR MY!)
51	 CAPABILITIES AND SHOULD TRY A COMPLETELY DIFFERENT TACK.
51	 TO SPEED THE GAME YOU CAN SOMETIMES MOVE LONG DISTANCES
51	 WITH A SINGLE WORD. FOR EXAMPLE, 'BUILDING' USUALLY GETS
51	 YOU TO THE BUILDING FROM ANYWHERE ABOVE GROUND EXCEPT WHEN
51	 LOST IN THE FOREST. ALSO, NOTE THAT CAVE PASSAGES TURN A
51	 LOT, AND THAT LEAVING A ROOM TO THE NORTH DOES NOT GUARANTEE
51	 ENTERING THE NEXT FROM THE SOUTH. GOOD LUCK!
52	 IT MISSES!
53	 IT GETS YOU!
54	 OK
55	 YOU CAN'T UNLOCK THE KEYS.
56	 YOU HAVE CRAWLED AROUND IN SOME LITTLE HOLES AND WOUND UP
56	 BACK IN THE MAIN PASSAGE.
57	 I DON'T KNOW WHERE THE CAVE IS, BUT HEREABOUTS NO STREAM
57	 CAN RUN ON THE SURFACE FOR LONG. I WOULD TRY THE STREAM.
58	 I NEED MORE DETAILED INSTRUCTIONS TO DO THAT.
59	 I CAN ONLY TELL YOU WHAT YOU SEE AS YOU MOVE ABOUT
59	 AND MANIPULATE THINGS. I CANNOT TELL YOU WHERE REMOTE THINGS
59	 ARE.
60	 I DON'T KNOW THAT WORD.
61	 WHAT?
62	 ARE YOU TRYING TO GET INTO THE CAVE?
63	 THE GRATE IS VERY SOLID AND HAS A HARDENED STEEL LOCK. YOU
63	 CANNOT ENTER WITHOUT A KEY, AND THERE ARE NO KEYS NEARBY.
63	 I WOULD RECOMMEND LOOKING ELSEWHERE FOR THE KEYS.
64	 THE TREES OF THE FOREST ARE LARGE HARDWOOD OAK AND MAPLE,
64	 WITH AN OCCASIONAL GROVE OF PINE OR SPRUCE. THERE IS QUITE
64	 A BIT OF UNDERGROWTH, LARGELY BIRCH AND ASH SAPLINGS PLUS
64	 NONDESCRITPT BUSHES OF VARIOUS SORTS. THIS TIME OF YEAR
64	 VISIBILITY IS QUITE RESTRICTED BY ALL THE LEAVES, BUT TRAVEL
64	 IS QUITE EASY IF YOU DETOUR AROUND THE SPRUCE AND BERRY BUSHES.
65	 WELCOME TO ADVENTURE!!  WOULD YOU LIKE INSTRUCTIONS?
66	 DIGGING WITHOUT A SHOVEL IS QUITE IMPRACTICAL: EVEN WITH A
66	 SHOVEL PROGRESS IS UNLIKELY.
67	 BLASTING REQUIRES DYNAMITE.
68	 I'M AS CONFUSED AS YOU ARE.
69	 MIST IS A WHITE VAPOR, USUALLY WATER, SEEN FROM TIME TO TIME
69	 IN CAVERNS. IT CAN BE FOUND ANYWHERE BUT IS FREQUENTLY A SIGN
69	 OF A DEEP PIT LEADING DOWN TO WATER.
70	 YOUR FEET ARE NOW WET.
71	 THERE IS NOTHING HERE TO EAT.
72	 EATEN!
73	 THERE IS NO DRINKABLE WATER HERE.
74	 THE BOTTLE OF WATER IS NOW EMPTY.
75	 RUBBING THE ELECTRIC LAMP IS NOT PARTICULARLY REWARDING.
75	 ANYWAY, NOTHING EXCITING HAPPENS.
76	 PECULIAR.  NOTHING UNEXPECTED HAPPENS.
77	 YOUR BOTTLE IS EMPTY AND THE GROUND IS WET.
78	 YOU CAN'T POUR THAT.
79	 WATCH IT!
80	 WHICH WAY?
-1
0
