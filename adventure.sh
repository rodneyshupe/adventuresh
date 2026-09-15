#!/usr/bin/env bash

# ADVENTURESH
# A pure Bash port of Colossal Cave Adventure (1977)

set -u

# Boolean convention: 0 is success/true, matching Bash's own exit-status truthiness.
declare -r TRUE=0
declare -r FALSE=1

# Fortran packs each travel entry as DEST*1024 + KEYWORD, so 1024 is both the
# destination multiplier and the modulus that recovers the motion keyword.
declare -r TRAVEL_SCALE=1024

# Motion keyword 1 in a travel entry is a wildcard: it matches any motion word
# the player typed (see the MOD(LL,1024).EQ.1 test at 77-03-31_adventure.f:261).
declare -r TRAVEL_ANY=1

# TK in the Fortran READ at 1014 is a 10-element slice, so at most 10 motion
# keywords per data line are ever consumed.
declare -r TRAVEL_MAX_KEYWORDS=10

# --- Global State Arrays ---
declare -a LLINE
declare -a IOBJ ICHAIN IPLACE IFIXED COND PROP ABB
declare -a LTEXT STEXT KEY DEFAULT TRAVEL
declare -a TK KTAB ATAB BTEXT
declare -a RTEXT

# Initialize arrays to 0 (Bash doesn't strictly need this for empty, but for safety with math)
for i in {1..300}; do
    IOBJ[$i]=0; ICHAIN[$i]=0; IPLACE[$i]=0; IFIXED[$i]=0; COND[$i]=0; PROP[$i]=0; ABB[$i]=0
    LTEXT[$i]=0; STEXT[$i]=0; KEY[$i]=0; DEFAULT[$i]=0; TRAVEL[$i]=0
    if (( i <= 100 )); then RTEXT[$i]=0; fi
    if (( i <= 200 )); then BTEXT[$i]=0; fi
done

# Object identity constants (77-03-31_adventure.f:16-25): bare object numbers
# used throughout the engine wherever COND/PROP/IPLACE is checked for one of
# these specific objects.
declare -r -i KEYS=1
declare -r -i LAMP=2
declare -r -i GRATE=3
declare -r -i ROD=5
declare -r -i BIRD=7
declare -r -i NUGGET=10
declare -r -i SNAKE=11
declare -r -i FISSUR=12   # PROP(12) != 0 once the crystal bridge spans the fissure
declare -r -i FOOD=19
declare -r -i WATER=20
declare -r -i AXE=21

# 77-03-31_adventure.f:26-27 — SPEAK() message IDs indexed by JVERB, the
# generic complaint for a verb that fell through to its "can't do that"
# fallback (label 5200, f:396) without a more specific message of its own.
# do_take/do_drop use JSPKT[1]/JSPKT[2]; refuse_motion's own JSPK ladder
# (Movement, f:272-281) inlines its message numbers instead of indexing this
# table for the verbs it covers.
declare -r -a JSPKT=(0 24 29 0 31 0 31 38 38 42 42 43 46 77 71 73 75)

# ---------------------------------------------------------------------------
#  Object placement
# ---------------------------------------------------------------------------

# Fortran scalars reset by the same init block as init_objects: the dwarf clock
# (IDWARF, driven by dwarf_turn in Dwarves below), a compass-facing hint
# (IWEST) and a long-description-forced toggle (ILONG) — the latter two not yet
# consumed by anything — plus IFIRST, set once and never cleared in this
# revision, so the message-14 check in travel_choose it guards is dead code
# (kept for traceability, per that function's own comment).
declare -i IDWARF=0
declare -i IFIRST=1
declare -i IWEST=0
declare -i ILONG=1

# init_objects
#   Fortran labels 1100-1107 (77-03-31_adventure.f:114-154): seeds object
#   placement (IPLACE) and fixedness (IFIXED) from the IPLT/IFIXT DATA
#   tables, sets the COND flags for lit rooms (1) and forced-move pseudo-rooms
#   (2, see COND_FORCED in Movement), then builds the IOBJ/ICHAIN linked
#   list — IOBJ[room] is the first object in that room, ICHAIN[obj] chains to
#   the next object sharing the room. Finishes with the scalar game-state
#   resets the same Fortran block ends on. Objects 1-20 get a starting room;
#   object 21 (AXE) has no IPLT/IFIXT entry and starts unplaced (IPLACE=0)
#   since the Fortran only places it once a dwarf throws it (f:183-185).
#   Mutates IPLACE/IFIXED/ICHAIN/IOBJ/COND and IDWARF/IFIRST/IWEST/ILONG/
#   IDETAL — must be called directly, not in $(...).
function init_objects() {
    local -i i ktem

    # 77-03-31_adventure.f:28-30
    local -a iplt=(0 3 3 8 10 11 14 13 9 15 18 19 17 27 28 29 30 0 0 3 3)
    local -a ifixt=(0 0 0 1 0 0 1 0 1 1 0 1 1 0 0 0 0 0 0 0 0)

    for (( i = 1; i <= 100; i++ )); do
        IPLACE[i]=${iplt[i]:-0}
        IFIXED[i]=${ifixt[i]:-0}
        ICHAIN[i]=0
    done

    # IOBJ is indexed by room, not by object, so the loop above doesn't reach
    # it. The Fortran gets it zeroed for free from static storage and so never
    # clears it; here a second call would otherwise chain objects onto the
    # previous run's lists and loop forever building them.
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

    # The Fortran gets DLOC/ODLOC/DSEEN zeroed for free from static storage
    # (they are only assigned once IDWARF reaches 2, f:178-181); under set -u
    # they have to be seeded explicitly or dwarf_turn's first read is unbound.
    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        DLOC[i]=0
        ODLOC[i]=0
        DSEEN[i]=0
    done
}

# dump_objects
#   Debug aid for verifying init_objects: prints every room that starts with
#   at least one object (walking IOBJ/ICHAIN), then lists which of this
#   revision's known objects (1-AXE) start unplaced or fixed in place.
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
        
        # Check for section ends (-1)
        if [[ "$line" == "-1"* ]]; then
            continue
        fi

        # A bare section number of 0 marks the end of the data (the Fortran
        # loader's "READ section number, 0 means done" at label 1002).
        if [[ "$line" == "0" ]]; then
            break
        fi

        # Check for new sections (single digits 1-6)
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
            # Fortran's RTEXT: the numbered messages SPEAK(N) prints.
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

# Decoded parallel arrays, all sharing the 1-based index that KEY[] points at.
# TRAVEL[] itself holds the raw packed Fortran value (signed); the rest are the
# unpacked form so later movement code never has to redo the arithmetic.
declare -a TRAVEL_SRC TRAVEL_DEST TRAVEL_KEY TRAVEL_LAST
declare -i TRAVEL_COUNT=0

# parse_travel_table
#   Reads RAW_TRAVEL[] (section 3 lines, "<src>\t<dest>\t<kw>..." tab separated)
#   and fills, via globals: TRAVEL[i] (packed, negative on the final entry for a
#   source room), KEY[room] (index of that room's first entry, 0 if none),
#   TRAVEL_SRC/TRAVEL_DEST/TRAVEL_KEY/TRAVEL_LAST[i] (decoded), TRAVEL_COUNT.
#   Must be called directly, not in $(...) — a subshell would discard every one
#   of those assignments.
function parse_travel_table() {
    local line src dest kw
    local -a fields
    local -i idx=1 n=0

    for line in "${RAW_TRAVEL[@]}"; do
        # Word splitting on the default IFS handles the tabs; the -1 section
        # terminator never reaches RAW_TRAVEL (load_data drops it).
        read -r -a fields <<< "$line"
        (( ${#fields[@]} >= 3 )) || continue

        src=${fields[0]}
        dest=${fields[1]}

        if (( ${KEY[$src]:-0} == 0 )); then
            KEY[$src]=$idx
        else
            # Un-flag the previous line's last entry: the "last for this source"
            # marker belongs on the final line of a contiguous run of lines for
            # the same source room, and the toggling below is exactly how the
            # Fortran arrives at that (77-03-31_adventure.f:88 and :95).
            TRAVEL[$((idx - 1))]=$(( -TRAVEL[idx - 1] ))
        fi

        for (( n = 2; n < ${#fields[@]} && n - 2 < TRAVEL_MAX_KEYWORDS; n++ )); do
            kw=${fields[$n]}
            (( kw == 0 )) && break   # Fortran stops the TK loop on the first 0

            TRAVEL[$idx]=$(( dest * TRAVEL_SCALE + kw ))
            TRAVEL_SRC[$idx]=$src
            (( idx++ ))
        done

        # Provisionally the last entry for this source; undone above if another
        # line for the same source follows.
        TRAVEL[$((idx - 1))]=$(( -TRAVEL[idx - 1] ))
    done

    TRAVEL_COUNT=$(( idx - 1 ))

    # Second pass: the sign is only final once every line has been seen.
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
#   Debug aid for verifying the parse: prints each named room's travel entries
#   in table order. Destinations of 300+ are the computed/conditional cases
#   dispatched at 77-03-31_adventure.f:286-317, not real room numbers.
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
#   Fortran's CALL SPEAK(N): prints message N from data section 6. Each stored
#   message already ends in a newline, so echo's own adds the blank separator
#   line the Fortran FORMAT(/) produced.
function speak() {
    echo -e "${RAW_MSG[$1]:-}"
}

# ran_gt PERCENT
#   Stands in for Fortran's RAN(QZ).GT.<fraction> tests: true (exit 0) when a
#   fresh uniform draw exceeds PERCENT/100. RANDOM%100 is a coarse but even
#   0-99 draw, which is all these 0.2/0.25/0.4/0.5 thresholds need.
function ran_gt() {
    (( RANDOM % 100 >= $1 ))
}

# ---------------------------------------------------------------------------
#  Movement
# ---------------------------------------------------------------------------

# Motion word IDs the travel dispatch singles out by name (data section 4).
# Named here because 77-03-31_adventure.f:255-281 tests them as bare numbers.
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
declare -r MOT_SOUTH=46     # EAST..SOUTH (43-46) are contiguous compass points
declare -r MOT_XYZZY=48
declare -r MOT_LOOK=57
declare -r MOT_CAVE=67
declare -r MOT_TURN=68

# Destinations at or above this are not rooms but cases in the computed GOTO
# at 77-03-31_adventure.f:288, resolved by resolve_cond_dest.
declare -r COND_DEST_BASE=300

# COND[room] values (set in the init block above, per f:108 and f:119-135):
# odd means the room is lit, 2 means "don't ask a question" — i.e. a forced
# move: describe the room, then immediately travel onward from it.
declare -r COND_FORCED=2

# Motion word 21 (NULL/NOWHE): matches no travel entry anywhere in the table, so
# "travelling" with it only burns a turn. The Fortran uses it that way at f:632
# to make an axe swing at a dwarf cost a move (and so give the dwarves another
# turn) without moving the player.
declare -r MOT_NULL=21

# Chance a move made in the dark ends in a pit (f:474). The Fortran's test is
# RAN(QZ).GT.0.25 to survive, so this is the death side of the draw.
declare -r -i DARK_PIT_PCT=25

# A forced move can chain (pseudo-room -> real room), but the unfinished death
# rooms of this revision chain into room 26, which has no travel entries and so
# loops forever in the Fortran. Cap the chain rather than hang.
declare -r MAX_FORCED_MOVES=20

# Player's current room (Fortran's LOC) and the room travelled from, which
# BACK swaps with (LOLD, f:258 and f:266-268).
declare -i LOC=1
declare -i LOLD=1

# Fortran's IDETAL: how many times LOOK has been used, so the apology in
# message 15 is only printed for the first three.
declare -i IDETAL=0

# Fortran's JVERB: the action verb of the current command (vocabulary ID minus
# 2000), 0 if none. Only JVERB==1 (TAKE/FIND) affects travel, via message 59.
declare -i JVERB=0

# Fortran's IDARK: set by arrive() when the room the player settled in is unlit
# and the lamp isn't here and burning. attempt_motion's label-5014 gate is the
# only thing that acts on it — moving in the dark can drop you down a pit.
declare -i IDARK=0

# Set once the player reaches the game-over destination (305). Chunk 6 replaces
# this with the real endgame; for now play_game just stops.
declare -i GAME_OVER=$FALSE

# Set by attempt_motion: $TRUE if the player ended up somewhere new, $FALSE if
# the move was refused or bounced straight back. Not yet consumed — reserved for
# later chunks (e.g., object/verb logic that may depend on successful motion).
declare -i MOVE_RESULT=$FALSE

# Set by travel_choose / resolve_cond_dest: the room (or, from travel_choose,
# the possibly-conditional destination) chosen for the current step.
declare -i NEXT_LOC=1

# refuse_motion MOTION_ID
#   The JSPK ladder at 77-03-31_adventure.f:272-281, reached when no travel
#   entry for the current room matches the motion word. Later assignments win,
#   so the order of these tests is load-bearing.
function refuse_motion() {
    local -i k=$1
    local -i jspk=12    # "I DON'T KNOW HOW TO APPLY THAT WORD HERE."

    # Compass points, up and down: the direction simply isn't available here.
    (( k >= MOT_EAST && k <= MOT_SOUTH )) && jspk=9
    (( k == MOT_UP || k == MOT_DOWN )) && jspk=9
    # Relative directions: the game doesn't track which way the player faces.
    (( k == MOT_FORWARD || k == MOT_BACK || k == MOT_LEFT \
       || k == MOT_RIGHT || k == MOT_TURN )) && jspk=10
    (( k == MOT_OUT || k == MOT_IN )) && jspk=11
    (( JVERB == 1 )) && jspk=59     # TAKE/FIND <direction>
    (( k == MOT_XYZZY )) && jspk=42 # a magic word that does nothing here
    (( k == MOT_CRAWL )) && jspk=80 # "WHICH WAY?"

    speak "$jspk"
}

# travel_choose MOTION_ID
#   Labels 8-19 of 77-03-31_adventure.f:253-285: pick the destination the
#   motion word leads to from the current $LOC, printing a refusal and choosing
#   $LOC itself when it leads nowhere. The result (which may be a >=300
#   conditional case) is returned in the global NEXT_LOC; LOLD and IDETAL/ABB
#   are side effects, so this must be called directly, not in $(...).
function travel_choose() {
    local -i k=$1
    local -i kk temp

    kk=${KEY[$LOC]:-0}

    # Label 19: the room has no travel entries at all.
    if (( kk == 0 )); then
        speak 13
        NEXT_LOC=$LOC
        # IFIRST is set to 1 during init and never cleared in this revision,
        # so message 14 is dead code here too — kept for traceability.
        (( IFIRST == 0 )) && speak 14
        return
    fi

    # Label 32: LOOK re-describes the current room by clearing its visited
    # count, which is what forces the long text at f:238.
    if (( k == MOT_LOOK )); then
        (( IDETAL < 3 )) && speak 15
        (( IDETAL++ ))
        ABB[$LOC]=0
        NEXT_LOC=$LOC
        return
    fi

    # Label 40: CAVE gets a hint rather than a move, worded by whether the
    # player is still above ground (rooms 1-7).
    if (( k == MOT_CAVE )); then
        if (( LOC < 8 )); then speak 57; else speak 58; fi
        NEXT_LOC=$LOC
        return
    fi

    # Label 12: BACK swaps the current room with the last one travelled from.
    if (( k == MOT_BACK )); then
        temp=$LOLD
        LOLD=$LOC
        NEXT_LOC=$temp
        return
    fi

    LOLD=$LOC

    # Label 9: walk this room's travel entries looking for the motion word or
    # the TRAVEL_ANY wildcard, stopping after the entry flagged last.
    while true; do
        if (( TRAVEL_KEY[kk] == TRAVEL_ANY || TRAVEL_KEY[kk] == k )); then
            NEXT_LOC=${TRAVEL_DEST[$kk]}    # label 10
            return
        fi
        if (( TRAVEL_LAST[kk] == TRUE )); then
            refuse_motion "$k"              # label 11
            NEXT_LOC=$LOC
            return
        fi
        (( kk++ ))
    done
}

# resolve_cond_dest DEST
#   The computed GOTO at 77-03-31_adventure.f:286-346: turns a conditional
#   destination (300-314) into a real room by consulting object state, and in
#   the multi-exit cases a random draw. Answers in the global NEXT_LOC and may
#   SPEAK, so it must be called directly, not in $(...). Returns non-zero only
#   for the game-over case, which has no room to go to.
function resolve_cond_dest() {
    local -i dest=$1

    case $dest in
        300)    # f:291 — lost in the forest: mostly room 6, sometimes room 5.
            NEXT_LOC=6
            ran_gt 50 && NEXT_LOC=5
            ;;
        301)    # f:294 — into the grate from above; 23 refuses if it's locked.
            NEXT_LOC=23
            (( PROP[GRATE] != 0 )) && NEXT_LOC=9
            ;;
        302)    # f:297 — out through the grate from below. Note the refusal
            # case is room 9 (stay put, silently) and not the "YOU CAN'T GO
            # THROUGH A LOCKED STEEL GRATE" room 25, which this revision of the
            # Fortran leaves unreachable. Ported as written.
            NEXT_LOC=9
            (( PROP[GRATE] != 0 )) && NEXT_LOC=8
            ;;
        303)    # f:300 — down the small pit. IPLACE == -1 means carried, and
            # climbing down with the nugget is fatal (room 20, broken neck).
            NEXT_LOC=20
            (( IPLACE[NUGGET] != -1 )) && NEXT_LOC=15
            ;;
        304)    # f:303 — up the dome out of the Hall of Mists; unclimbable
            # (room 22) while carrying the nugget.
            NEXT_LOC=22
            (( IPLACE[NUGGET] != -1 )) && NEXT_LOC=14
            ;;
        305)    # f:318 — label 31 is a bare PAUSE 'GAME IS OVER' that restarts
            # the program. Stubbed until chunk 6 has a real endgame.
            echo "GAME IS OVER"
            GAME_OVER=$TRUE
            return $FALSE
            ;;
        306)    # f:306 — across the fissure, which needs the crystal bridge.
            NEXT_LOC=27
            (( PROP[FISSUR] == 0 )) && NEXT_LOC=31
            ;;
        307|308|309)
            # f:309, f:312, f:315 — the three side chambers off the Hall of the
            # Mountain King, all barred while the snake is still in the way.
            NEXT_LOC=$(( dest - 279 ))      # 307->28, 308->29, 309->30
            (( PROP[SNAKE] == 0 )) && NEXT_LOC=32
            ;;
        310)    # f:325 — heading for the depression: out to it if the grate is
            # open, otherwise no further than the chamber below it.
            NEXT_LOC=8
            (( PROP[GRATE] == 0 )) && NEXT_LOC=9
            ;;
        311)    # f:328 — Bedquilt south: usually just wander back (label 35).
            NEXT_LOC=68
            ran_gt 20 && { NEXT_LOC=65; speak 56; }
            ;;
        312)    # f:334 — Bedquilt up: same wandering, else one of two rooms.
            if ran_gt 20; then
                NEXT_LOC=65
                speak 56
            else
                NEXT_LOC=39
                ran_gt 50 && NEXT_LOC=70
            fi
            ;;
        313)    # f:338 — Swiss cheese room north.
            NEXT_LOC=66
            if ran_gt 40; then
                speak 56
            else
                NEXT_LOC=71
                ran_gt 25 && NEXT_LOC=72
            fi
            ;;
        314)    # f:343 — Swiss cheese room south. The Fortran's computed GOTO
            # lists only 14 targets, so 314 falls through it and leaves L=314,
            # a room that does not exist; label 39 is the handler it should
            # have named and is otherwise unreachable. Wired up here so the
            # exit works instead of stranding the player in a void room.
            NEXT_LOC=66
            if ran_gt 20; then
                speak 56
            else
                NEXT_LOC=77
            fi
            ;;
        *)      # Not a case the Fortran knows either; treat as no movement.
            NEXT_LOC=$LOC
            ;;
    esac

    return $TRUE
}

# attempt_motion MOTION_ID
#   The whole travel loop of 77-03-31_adventure.f:246-350: choose a
#   destination, resolve any conditional case, describe where the player lands,
#   and — for a COND_FORCED room such as "YOU CAN'T GO IN THROUGH A LOCKED
#   STEEL GRATE!" — immediately travel on from it with the same motion word.
#   Updates LOC and sets MOVE_RESULT, so it must be called directly, not in
#   $(...): a subshell would discard both.
function attempt_motion() {
    local -i k=$1
    local -i start=$LOC
    local -i steps=0

    # Label 5014 (f:472-477), which every motion word reaches from the parser's
    # computed GOTO at f:417: blundering about in the dark has a DARK_PIT_PCT
    # chance per move of ending in a pit. Deliberately outside the loop below —
    # a forced move re-enters the Fortran at label 8, past this gate, so the
    # chain of pseudo-rooms only ever costs the player one draw.
    if (( IDARK != 0 )) && ! ran_gt "$DARK_PIT_PCT"; then
        speak 23
        # f:476's PAUSE 'GAME IS OVER', stubbed as in resolve_cond_dest's 305.
        echo "GAME IS OVER"
        GAME_OVER=$TRUE
        MOVE_RESULT=$FALSE
        return
    fi

    while (( steps++ < MAX_FORCED_MOVES )); do
        travel_choose "$k"                              # labels 8-19

        if (( NEXT_LOC >= COND_DEST_BASE )); then       # label 21
            if ! resolve_cond_dest "$NEXT_LOC"; then
                MOVE_RESULT=$FALSE
                return
            fi
        fi

        # Label 2 (f:162-170): a dwarf standing in the doorway turns the move
        # back before it happens; the dwarf turn itself then runs from wherever
        # the player actually ended up, ahead of the description as in f:171.
        dwarf_blocks "$NEXT_LOC" && NEXT_LOC=$LOC

        LOC=$NEXT_LOC                                   # labels 2/74

        if ! dwarf_turn; then                           # f:171-231
            MOVE_RESULT=$FALSE
            return
        fi

        print_desc "$LOC"                               # label 71

        if (( COND[LOC] != COND_FORCED )); then         # label 7
            arrive "$LOC"
            MOVE_RESULT=$(( LOC == start ? FALSE : TRUE ))
            return
        fi
    done

    MOVE_RESULT=$(( LOC == start ? FALSE : TRUE ))
}

# arrive ROOM
#   Label 2000 of 77-03-31_adventure.f:357-366: the end of a move, once the
#   player has actually settled somewhere. Bumps the visit count and would
#   decide whether the room is dark. Mutates ABB/LOC — call it directly.
function arrive() {
    local -i j=$1

    # A hollow voice occasionally gives away PLUGH at Y2 (f:247).
    (( j == 33 )) && ! ran_gt 25 && speak 8

    LOC=$j

    # ABB counts visits modulo 5, so the long description comes back round
    # every fifth time rather than never again (f:359).
    ABB[$j]=$(( (ABB[j] + 1) % 5 ))

    # 77-03-31_adventure.f:361-365 — an even COND means the room is unlit.
    # If the room is unlit, check if the lamp is present and lit; if not, set
    # IDARK and warn about pits. Rooms 1-10 have odd COND (lit); others vary.
    IDARK=0
    if (( COND[j] % 2 == 0 )); then
        # Room is potentially dark
        if (( IPLACE[LAMP] != j && IPLACE[LAMP] != -1 )) || (( PROP[LAMP] == 0 )); then
            # Lamp not here or not lit
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

# The Fortran DIMENSIONs DLOC/ODLOC/DSEEN at 10, but every loop over them runs
# 1..3 (f:162, f:178, f:192) — this revision only ever has three dwarves.
declare -r -i MAX_DWARVES=3

# Per-dwarf state, indexed 1..MAX_DWARVES and seeded by init_objects:
# where the dwarf is now, where it was last turn (what dwarf_blocks tests),
# and whether it has spotted the player and is shadowing them.
declare -a DLOC ODLOC DSEEN

# 77-03-31_adventure.f:31-32 — the fixed itinerary a dwarf walks, read by the
# per-dwarf clock below. Element 0 is a placeholder so the rest keep Fortran's
# 1-based indexing; it is also the value the Fortran itself reads when the
# clock hits exactly 8 (see dwarf_turn). The two trailing 300s are not rooms,
# so a dwarf that reaches the end of the itinerary has effectively wandered off.
declare -r -a DTRAV=(0 36 28 19 30 62 60 41 27 17 15 19 28 36 300 300)

# Room 15 (Hall of Mists) is where the Fortran arms the dwarf clock (f:173):
# nothing can happen until the player first gets below the surface.
declare -r -i DWARF_HALL=15

# Per-turn chance the first dwarf shows up once armed (f:176), and the chance
# each thrown knife finds its mark (f:205).
declare -r -i DWARF_WAKE_PCT=5
declare -r -i DWARF_KNIFE_PCT=10

# Chance a thrown axe kills the dwarf it was aimed at (f:625). The Fortran's
# test is RAN(QZ).GT.0.4 to *miss*, so this is the kill side of the draw.
declare -r -i DWARF_AXE_PCT=40

# Dwarf I is in play while 2*I+IDWARF — a per-dwarf clock that staggers the
# three of them, since IDWARF ticks once per move — lies in this window
# (f:193-194): below the low bound it has not entered yet, above the high bound
# it has left, unless it is already shadowing the player.
declare -r -i DWARF_CLOCK_IN=8
declare -r -i DWARF_CLOCK_OUT=23

# A dwarf that has seen the player keeps pace with them only in the cave proper
# (f:196); at or above this room the player has outrun it and it goes back to
# walking its itinerary.
declare -r -i DWARF_FOLLOW_ABOVE=14

# dwarf_blocks DEST
#   Labels 2-73 of 77-03-31_adventure.f:162-170: a dwarf that has seen the
#   player bars the way back into the room it came from. Returns $TRUE (and
#   speaks message 2) when the move to DEST is blocked, $FALSE otherwise.
#   ODLOC, not DLOC, is the test: a shadowing dwarf's DLOC is the player's own
#   room, so its previous room is the one it is standing in the doorway of.
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
#   The dwarf block at 77-03-31_adventure.f:171-231, run once per move attempt
#   (successful or refused) just after LOC settles and before the room is
#   described, exactly where the Fortran has it. Three stages, by IDWARF:
#     0 — dormant; arms (IDWARF=1) the first time the player stands in room 15.
#     1 — armed; each move gets a DWARF_WAKE_PCT draw for the scripted first
#         encounter (message 3), which leaves the axe on the floor and starts
#         the clock at 2.
#     2+ — the real AI: tick the clock, walk each in-play dwarf one step along
#         DTRAV, and have any that lands on (or just left) the player's room
#         start shadowing them. A dwarf that neither moved nor was left behind
#         — ODLOC == DLOC, i.e. it is standing where it already stood with the
#         player — throws a knife, each with a DWARF_KNIFE_PCT chance to hit.
#   Mutates IDWARF/DLOC/ODLOC/DSEEN and (on the first encounter) the AXE's
#   IPLACE/IOBJ/ICHAIN, so it must be called directly, not in $(...). Returns
#   non-zero only when a knife kills the player, matching resolve_cond_dest's
#   convention for the cases that end the move early.
function dwarf_turn() {
    local -i i clock idx
    local -i dtot=0 attack=0 stick=0

    if (( IDWARF == 0 )); then                          # f:172-174
        (( LOC == DWARF_HALL )) && IDWARF=1
        return $TRUE
    fi

    if (( IDWARF == 1 )); then                          # f:175-187
        ran_gt $DWARF_WAKE_PCT && return $TRUE
        IDWARF=2
        for (( i = 1; i <= MAX_DWARVES; i++ )); do
            DLOC[i]=0
            ODLOC[i]=0
            DSEEN[i]=0
        done
        speak 3
        # The axe exists only from here on: init_objects leaves it unplaced
        # because this is the one spot that ever gives it a room (f:183-185).
        ICHAIN[AXE]=${IOBJ[LOC]}
        IOBJ[LOC]=$AXE
        IPLACE[AXE]=$LOC
        return $TRUE
    fi

    (( IDWARF++ ))                                      # f:188, label 63
    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        clock=$(( 2 * i + IDWARF ))
        (( clock < DWARF_CLOCK_IN )) && continue
        (( clock > DWARF_CLOCK_OUT && DSEEN[i] == 0 )) && continue

        ODLOC[i]=${DLOC[i]}

        # A dwarf already shadowing the player stays glued to them (label 65)
        # as long as they are deep enough; everyone else takes the next step of
        # the itinerary. The Fortran indexes DTRAV from 1, so a clock of exactly
        # DWARF_CLOCK_IN reads DTRAV(0) — off the front of the array, which in
        # the Fortran's storage layout is the never-written ODLOC(10), i.e. 0.
        # DTRAV[0] is that same 0 here, and 0 is simply "nowhere": the dwarf
        # sits out this turn rather than appearing in a room.
        if (( DSEEN[i] == 0 || LOC <= DWARF_FOLLOW_ABOVE )); then
            idx=$(( clock - DWARF_CLOCK_IN ))
            DLOC[i]=${DTRAV[idx]:-0}
            DSEEN[i]=0
            # Not in the player's room, and not in the one they just left:
            # this dwarf is somewhere else entirely and stays unseen.
            (( DLOC[i] != LOC && ODLOC[i] != LOC )) && continue
        fi

        DSEEN[i]=1                                      # label 65
        DLOC[i]=$LOC
        (( dtot++ ))
        # Only a dwarf that was already here last turn gets to throw.
        (( ODLOC[i] != DLOC[i] )) && continue
        (( attack++ ))
        ran_gt $DWARF_KNIFE_PCT || (( stick++ ))
    done

    (( dtot == 0 )) && return $TRUE                     # f:207

    if (( dtot == 1 )); then
        speak 4
    else
        # f:209-212. The Fortran TYPEs this one inline rather than via SPEAK,
        # I2-formatted, so it is spelled out here instead of living in the data.
        printf ' THERE ARE %2d THREATENING LITTLE DWARVES IN THE ROOM WITH YOU.\n\n' "$dtot"
    fi

    (( attack == 0 )) && return $TRUE                   # f:214, label 77

    if (( attack == 1 )); then                          # f:218-221, label 79
        speak 5
        speak $(( 52 + stick ))     # 52 "IT MISSES!" / 53 "IT GETS YOU!"
        (( stick == 0 )) && return $TRUE
    else
        printf ' %2d OF THEM THROW KNIVES AT YOU!\n\n' "$attack"
        if (( stick == 0 )); then                       # f:223, label 69
            speak 7
            return $TRUE
        fi
        if (( stick == 1 )); then                       # f:224, label 82
            speak 6
        else
            printf ' %2d OF THEM GET YOU.\n\n' "$stick"
        fi
    fi

    # Label 83 is a bare PAUSE 'GAMES OVER' that drops straight back into the
    # room description — death isn't implemented in this revision. Stubbed the
    # same way resolve_cond_dest stubs destination 305, until Chunk 6 has a
    # real endgame (and resurrection) to hand the player to.
    echo "GAME IS OVER"
    GAME_OVER=$TRUE
    return $FALSE
}

# ---------------------------------------------------------------------------
#  Object interaction (verbs)
# ---------------------------------------------------------------------------

# object_here OBJ
#   Fortran's label-5000 pre-check (77-03-31_adventure.f:481-493, simplified):
#   true when OBJ is physically in the current room or already carried — the
#   only two states from which TAKE/DROP make sense. The grate's extra
#   "visible from a few nearby rooms" exception at f:484-497 is not
#   replicated: no verb acts on a distant grate yet, so it has no payoff.
function object_here() {
    local -i obj=$1
    (( IPLACE[obj] == LOC || IPLACE[obj] == -1 ))
}

# do_take OBJ
#   Fortran labels 9000-9008 (77-03-31_adventure.f:512-533), reached via
#   JVERB==1 (TAKE/CARRY/GET/...). Object 18 (the dwarves' knife) isn't a real
#   placeable object and always succeeds as a no-op. Fixed scenery is refused
#   outright; the bird refuses if the rod (which scares it) is carried, or if
#   no cage (object 4) is carried or in this room to catch it with. Otherwise
#   the object is marked carried (IPLACE=-1) and unlinked from LOC's
#   IOBJ/ICHAIN chain. Mutates IPLACE/IOBJ/ICHAIN — must be called directly,
#   not in $(...).
function do_take() {
    local -i obj=$1
    local -i itemp

    if (( obj == 18 )); then
        speak 54
        return
    fi

    # f:513 — reachable here only if object_here confirmed the object is in
    # this room or already carried; JSPKT[1]=24 ("YOU ARE ALREADY CARRYING
    # IT!") is exactly the latter case, the only way IPLACE can differ from
    # LOC at this point.
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
#   Fortran labels 5066-5160 (77-03-31_adventure.f:546-557), reached via
#   JVERB==2 (DROP/RELEASE/DISCARD/...). Object 18 is the same no-op as in
#   do_take. Dropping the bird in the Hall of the Mountain King (room 19)
#   while the snake is still there drives the snake off (message 30, sets
#   PROP[SNAKE]); any other drop just says "OK" (54). Either way the object
#   is chained into LOC and IPLACE set to LOC. Mutates IPLACE/IOBJ/ICHAIN/
#   PROP — must be called directly, not in $(...).
function do_drop() {
    local -i obj=$1

    if (( obj == 18 )); then
        speak 54
        return
    fi

    # f:547 — reachable here only if object_here confirmed presence/carry;
    # JSPKT[2]=29 ("YOU AREN'T CARRYING IT!") is exactly the not-carried case,
    # the only way IPLACE can differ from -1 at this point.
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
#   Fortran label 5031 (77-03-31_adventure.f:559-585), JVERB==6 (LOCK),
#   reached via verb+noun dispatch. Requires keys to be present (in room or
#   carried). Locking the cage gives message 32; locking the keys gives 55;
#   locking non-grate objects gives 33. Only the grate can truly be locked:
#   if already locked, message 34; else PROP(GRATE)=1, PROP(8)=1, message 35.
#   Mutates PROP — must be called directly, not in $(...).
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

    if (( PROP[GRATE] != 0 )); then
        speak 34
        return
    fi

    speak 35
    PROP[GRATE]=1
    PROP[8]=1
}

# do_unlock OBJ
#   Fortran label 5031 (77-03-31_adventure.f:559-585), JVERB==4 (UNLOCK),
#   reached via verb+noun dispatch. Requires keys to be present (in room or
#   carried). Same object restrictions as do_lock: only the grate can truly
#   be unlocked. If already unlocked, message 36; else PROP(GRATE)=0,
#   PROP(8)=0, message 37.
#   Mutates PROP — must be called directly, not in $(...).
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

    if (( PROP[GRATE] == 0 )); then
        speak 36
        return
    fi

    speak 37
    PROP[GRATE]=0
    PROP[8]=0
}

# do_light OBJ
#   Fortran label 9404 (77-03-31_adventure.f:589-595), JVERB==7 (LIGHT),
#   reached via verb+noun dispatch. Requires the lamp to be present (in room
#   or carried). Sets PROP(LAMP)=1, IDARK=0, message 39. Generic refusal
#   message 31 if lamp not present.
#   Mutates PROP/IDARK — must be called directly, not in $(...).
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
#   Fortran label 9406 (77-03-31_adventure.f:597-602), JVERB==8
#   (EXTINGUISH/DARK), reached via verb+noun dispatch. Requires the lamp to
#   be present (in room or carried). Sets PROP(LAMP)=0, message 40. Generic
#   refusal message 31 if lamp not present.
#   Mutates PROP — must be called directly, not in $(...).
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
#   Fortran label 5081 (77-03-31_adventure.f:604-608), JVERB==9 (STRIKE),
#   reached via verb+noun dispatch. Only object 12 (FISSUR, the crystal
#   bridge) can be struck. Sets PROP(FISSUR)=1 to span the fissure; any other
#   object gets the generic refusal (message 31 by convention, although the
#   Fortran goes to label 5200 which uses JSPKT[9-2000]=38).
#   Mutates PROP — must be called directly, not in $(...).
function do_strike() {
    local -i obj=$1

    if (( obj != FISSUR )); then
        speak 31
        return
    fi

    PROP[FISSUR]=1
}

# do_attack OBJ [VERB_WORD]
#   Fortran label 5300 (77-03-31_adventure.f:610-620), JVERB==12 (ATTACK/
#   KILL/STAB/FIGHT/HIT), reached via verb+noun dispatch. The snake can never
#   be attacked (message 46, "BOTH DOESN'T WORK AND IS VERY DANGEROUS" —
#   JSPKT[12], the generic refusal for this verb). Attacking the bird kills
#   it (message 45) and removes it from LOC's IOBJ/ICHAIN chain — same
#   unlink logic as do_take — with IPLACE set to 300 (f:619's "gone"
#   sentinel, not -1/carried or a real room) so it can never be taken or
#   described again. Any other object gets "nothing here to attack" (44).
#
#   Ahead of all of that (f:612-615) comes the axe throw: if any dwarf is
#   shadowing the player, the swing goes at the first such dwarf and whatever
#   noun the player named is ignored entirely. OBJ may therefore be 0, which is
#   how the Fortran reaches this label for a bare "ATTACK" (f:455-456, label
#   2036); with no dwarf to hit, that falls through to label 5062's
#   "<VERB> WHAT?", which is what VERB_WORD (default ATTACK) is for.
#
#   Mutates IPLACE/IOBJ/ICHAIN and, in the dwarf branch, DSEEN/ODLOC/DLOC plus
#   everything attempt_motion touches — must be called directly, not in $(...).
function do_attack() {
    local -i obj=$1
    local word=${2:-ATTACK}
    local -i itemp i iid=0

    # f:612-615 — the DO 5313 scan. The Fortran copies the loop index into IID
    # on every pass, so IID ends up naming the first dwarf with DSEEN set; 0
    # here stands for the loop running out without finding one.
    for (( i = 1; i <= MAX_DWARVES; i++ )); do
        if (( DSEEN[i] != 0 )); then
            iid=$i
            break
        fi
    done

    if (( iid != 0 )); then
        if ran_gt "$DWARF_AXE_PCT"; then             # f:631, label 5309
            speak 48
        else                                         # f:625-630, label 5307
            DSEEN[iid]=0
            ODLOC[iid]=0
            DLOC[iid]=0
            speak 47
        fi

        # Label 5311 (f:632-633): hit or miss, the throw costs a move, and the
        # Fortran spends it on MOT_NULL — a motion word no travel entry matches,
        # so the player stays put. The only point is to run the dwarves' turn
        # again (and to pass through label 5014's dark-pit gate on the way).
        # Faithful side effect: since nothing matches, travel_choose's refusal
        # ladder speaks message 12 after the kill/dodge line. It reads oddly,
        # but both this revision and 77-03-11 are written that way.
        attempt_motion "$MOT_NULL"
        return
    fi

    if (( obj == 0 )); then                          # f:616 -> label 5062
        # f:466's FORMAT('  ',A5,' WHAT?',/) — the verb padded to Fortran's
        # five-character word width.
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
#   Return text for a given object, accounting for its PROP state.
#   Fortran label-2003 (77-03-31_adventure.f:368-381): ILK = I if PROP(I)==0,
#   else I+100. Looks up BTEXT[ILK]; if nonzero, prints object description.
#   In Bash, OBJ_TEXT is indexed by the text ID from the data (e.g. 1, 3, 103,
#   201, etc.). For most objects, PROP=0 text uses ID=I+200 (e.g. object 1 →
#   201), and PROP≠0 uses ID=I+100 (e.g. object 3 with PROP≠0 → 103). Others
#   like object 3 use bare IDs (3, 103). Try computed ID + fallbacks in order.
function get_object_text() {
    local -i obj=$1
    local -i text_id=0

    # Determine text ID based on PROP state
    if (( PROP[obj] == 0 )); then
        # No property set: try object ID + 200, then bare object ID
        if [[ -n "${OBJ_TEXT[obj+200]:-}" ]]; then
            text_id=$((obj + 200))
        elif [[ -n "${OBJ_TEXT[obj]:-}" ]]; then
            text_id=$obj
        fi
    else
        # Property set: try object ID + 100, then bare object ID
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

    # Fortran's logic (lines 237-238): if ABB(L)=0 (unvisited) or STEXT(L)=0 (no short text),
    # use long text; otherwise use short text.
    # In this Bash version, RAW_TEXT and RAW_SHORT are indexed by room ID directly.
    if [[ ${ABB[$room]:-0} == 0 || -z "${RAW_SHORT[$room]:-}" ]]; then
        # First visit or no short text: show long description
        echo -e "${RAW_TEXT[$room]:-}"
    else
        # Subsequent visits: show short description
        echo -e "${RAW_SHORT[$room]:-}"
    fi

    # Fortran label-2003: walk IOBJ/ICHAIN to print objects in this room (77-03-31_adventure.f:368-382).
    local -i obj=${IOBJ[room]:-0}
    while (( obj != 0 )); do
        get_object_text "$obj"
        obj=${ICHAIN[obj]:-0}
    done

    # ABB is bumped by arrive(), not here: the Fortran only counts the visit
    # once the player has settled (f:359), so the pass-through descriptions of
    # forced rooms keep showing their long text.
}

function play_game() {
    # Fortran labels 1-2: start in room 1 and run the arrival path over it once.
    print_desc "$LOC"
    arrive "$LOC"

    while true; do
        read -p "> " cmd
        cmd=$(echo "$cmd" | tr '[:lower:]' '[:upper:]')
        
        if [[ "$cmd" == "QUIT" || "$cmd" == "EXIT" ]]; then
            echo "Quitting game."
            break
        fi
        
        # Parse vocabulary into IDs and categorize by range (77-03-31_adventure.f:425):
        # < 1000 → motion word, 1000-1999 → noun/object, 2000-2999 → verb/action,
        # 3000-3999 → special message
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

            # Fortran's JVERB (f:419), which refuse_motion consults so that
            # e.g. "FIND WEST" gets message 59 rather than a travel refusal.
            JVERB=0
            (( verb != -1 )) && JVERB=$(( verb - 2000 ))

            # Chunk 3 (movement) is complete; remaining branches are deferred to
            # later chunks: Chunk 4 (object/inventory, verb+noun), Chunk 5
            # (special mechanics), and Chunk 6 (scoring/endgame, special messages).
            if (( msg != -1 )); then
                # Chunk 6: special action/message. Stub for now.
                echo "Special Action ID: $msg (Not yet implemented)"
            elif (( motion != -1 )); then
                # Chunk 3: movement dispatch (fully implemented).
                attempt_motion "$motion"
            elif (( verb != -1 && noun != -1 )); then
                # Chunk 4.2 & 4.3: TAKE/DROP and LOCK/UNLOCK/LIGHT/EXTINGUISH/STRIKE are wired;
                # every other verb+noun combination is deferred to later chunks.
                local -i objnum=$(( noun - 1000 ))
                if (( JVERB == 1 || JVERB == 2 )); then
                    # TAKE/DROP require object to be present before dispatch
                    if object_here "$objnum"; then
                        if (( JVERB == 1 )); then
                            do_take "$objnum"
                        else
                            do_drop "$objnum"
                        fi
                    else
                        # f:489 — Fortran interpolates the noun's own text
                        # here ("I SEE NO <WORD> HERE."); no reverse
                        # vocabulary lookup exists yet, so this is generic.
                        echo "I SEE NO SUCH THING HERE."
                    fi
                elif (( JVERB == 4 )); then
                    # UNLOCK
                    do_unlock "$objnum"
                elif (( JVERB == 6 )); then
                    # LOCK
                    do_lock "$objnum"
                elif (( JVERB == 7 )); then
                    # LIGHT (object arg ignored; only the lamp)
                    do_light "$objnum"
                elif (( JVERB == 8 )); then
                    # EXTINGUISH/DARK (object arg ignored; only the lamp)
                    do_extinguish "$objnum"
                elif (( JVERB == 9 )); then
                    # STRIKE (only object 12/FISSUR)
                    do_strike "$objnum"
                elif (( JVERB == 12 )); then
                    # ATTACK/KILL/STAB/FIGHT/HIT: dwarf first (Chunk 5.5), then
                    # the snake/bird cases (Chunk 5.2).
                    do_attack "$objnum"
                else
                    echo "Action ID: $verb on Object ID: $noun (Not yet implemented)"
                fi
            elif (( verb != -1 )); then
                if (( JVERB == 12 )); then
                    # Label 2036 (f:455-456) routes a bare ATTACK to 5300 too:
                    # with no noun there is still a dwarf to look for, and only
                    # if none is there does it ask "ATTACK WHAT?".
                    do_attack 0 "${cmd%% *}"
                else
                    # Chunk 5: verb alone (magic words, status queries, etc.).
                    echo "You want to do something, but what?"
                fi
            elif (( noun != -1 )); then
                # Chunk 4: noun alone (context-dependent action).
                echo "What do you want to do with that?"
            else
                echo "I don't understand that word."
            fi

            # Death can now arrive from a verb as well as from a motion word
            # (do_attack's null move runs the dwarf turn and the dark-pit gate),
            # so the check belongs after the whole dispatch, not inside one arm.
            (( GAME_OVER == TRUE )) && break
        fi
    done
}

function main() {
    load_data
    parse_travel_table
    init_objects

    # Verification hooks; a real CLI parser comes later.
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
