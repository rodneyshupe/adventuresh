#!/usr/bin/env bash
#
# test_walkthrough.sh — end-to-end playthrough test for adventure.sh
#
# As of Chunk 0.8 (IMPLEMENTATION_PLAN.md), adventure.sh's embedded data is
# the real Crowther/Woods 350-point advent.dat, not the frozen 77-03-31
# Crowther-original this file used to target (see ADVENT.Crowther.sh for
# that engine, and CLAUDE.md for the two-stage porting history). This drives
# the actual game with a hand-verified command sequence and checks the
# transcript for the messages each step should produce. It exercises
# movement, inventory (TAKE/DROP), the lamp, the XYZZY/PLUGH magic words,
# LOCK/UNLOCK on the grate, and the cage/bird/snake puzzle in the Hall of
# the Mountain King — all present, if not always worded identically, in the
# 350-point revision too. It does not yet exercise anything from Chunks 1+
# (predicates, real DROP/CARRY, puzzles, dwarves/pirate, hints, scoring,
# closing sequence) since none of that is wired up yet.
#
# RANDOM is seeded so dwarf spawns (5%/move once armed) and the dark-pit
# gate can't introduce flaky output; every room visited here is inherently
# lit or lit by the lamp, so the pit gate never fires regardless of seed.
#
# Chunk 12.8 added ADVENTURE_FAKE_DATIME (Chunk 11.1) to every scenario's
# invocation (see FAKE_DATIME below) instead of leaving each run to real
# wall-clock time: start_gate() (Chunk 12.5) genuinely refuses/shortens play
# outside a wizard-configured "open" window, and the POOF defaults close
# regular play on weekdays 8:00-18:00 (Chunk 12's own verified finding).
# Before this, every non-wizard scenario here was silently at the mercy of
# whatever time of day/week the suite happened to run — this pins each one
# to a known day-class instead.
set -u

declare -r GAME=./adventure.sh
declare -r SEED=7
declare -i failures=0

# A Saturday (weekday field 6): POOF's WKEND default is "open all day", so
# this is unrestricted regardless of hour, keeping the pre-wizard-mode
# scenarios below exercising exactly what they always did.
declare -r OPEN_DATIME="19003 600 6"

# A Thursday at 10am (weekday field 4): inside POOF's WKDAY default closed
# window (8:00-18:00), so start_gate() (Chunk 12.5) refuses ordinary play.
declare -r CLOSED_DATIME="19000 600 4"

# Any moment works for MAGIC MODE itself (advent.for:877's hook isn't
# hours-gated), but start_gate() still runs first — pin a weekend so it
# never intervenes before MAGIC MODE is even reached. Distinct day-count
# from OPEN_DATIME only so the wizard cipher challenge below (computed by
# hand for this exact D/T) doesn't double as a coincidence check against
# the other scenarios' time.
declare -r MAGIC_DATIME="20000 600 6"
declare -r MAGIC_DATIME_2="20001 600 6"

# Cleanup file for cleanup_wizcom below.
declare -r WIZCOM_FILE=adventure.wizcom

# cleanup_wizcom
#   Removes any adventure.wizcom left in the working directory. Called
#   before the suite starts (in case a prior interrupted run left one
#   behind) and after it ends, so this file's presence never leaks between
#   separate invocations of this script or into a developer's manual
#   `./adventure.sh` session in the same directory.
function cleanup_wizcom() {
    rm -f "$WIZCOM_FILE"
}

# run_scenario NAME GAME_ARGS COMMANDS FAKE_DATIME EXPECTED...
#   Feeds COMMANDS (newline-separated) to a fresh game process (invoked with
#   GAME_ARGS, e.g. "--crowther"; pass "" for the default 350-point game,
#   and ADVENTURE_FAKE_DATIME=FAKE_DATIME so wizard-mode's hours gate
#   (Chunk 12.5) behaves deterministically rather than depending on real
#   wall-clock time) and checks that every string in EXPECTED appears
#   somewhere in the transcript, in order. Prints PASS/FAIL per expected
#   string and tallies into $failures. Chunk 7.4 added the real "Would you
#   like instructions?" startup prompt (advent.for:622) ahead of the first
#   room description; on an open-hours FAKE_DATIME that's the first prompt
#   a scenario sees, so COMMANDS must supply its own leading "n" — this
#   function no longer prepends one, since a closed-hours FAKE_DATIME has
#   its own, different prompts to answer first (Chunk 12.5's wizard/
#   short-demo offer).
#   Sets LAST_TRANSCRIPT (Chunk 10.7) so a caller can follow up with
#   check_absent for a "must NOT appear" assertion — run_scenario itself only
#   checks in-order presence, never absence.
function run_scenario() {
    local name=$1 game_args=$2 commands=$3 fake_datime=$4
    shift 4
    local -a expected=("$@")

    echo "== $name =="
    local transcript
    transcript=$(printf '%s' "$commands" | RANDOM=$SEED ADVENTURE_FAKE_DATIME="$fake_datime" "$GAME" $game_args 2>&1)
    LAST_TRANSCRIPT=$transcript

    local search_from="$transcript"
    local want
    for want in "${expected[@]}"; do
        if [[ "$search_from" == *"$want"* ]]; then
            echo "  PASS: $want"
            search_from="${search_from#*"$want"}"
        else
            echo "  FAIL: expected to find (in order): $want"
            failures+=1
        fi
    done
}

# check_absent DESC NEEDLE
#   Fails (and tallies into $failures) if NEEDLE appears anywhere in
#   $LAST_TRANSCRIPT, the transcript from the most recent run_scenario call.
function check_absent() {
    local desc=$1 needle=$2
    if [[ "$LAST_TRANSCRIPT" == *"$needle"* ]]; then
        echo "  FAIL: $desc (should not contain: $needle)"
        failures+=1
    else
        echo "  PASS: $desc"
    fi
}

cleanup_wizcom

run_scenario "Lock/unlock regression (do_lock/do_unlock)" "" \
"n
east
take keys
west
depression
lock grate
down
unlock grate
down
quit
" "$OPEN_DATIME" \
"YOU ARE STANDING AT THE END OF A ROAD" \
"YOU ARE INSIDE A BUILDING" \
"OK" \
"YOU'RE AT END OF ROAD AGAIN." \
"20-FOOT DEPRESSION" \
"THE GRATE IS LOCKED" \
"IT WAS ALREADY LOCKED." \
"YOU CAN'T GO THROUGH A LOCKED STEEL GRATE!" \
"THE GRATE IS NOW UNLOCKED." \
"SMALL CHAMBER BENEATH A 3X3 STEEL GRATE" \
"THE GRATE IS OPEN." \
"Quitting game."

run_scenario "Full playthrough (movement, inventory, magic words, bird/snake)" "" \
"n
east
take keys
take keys
take lamp
light lamp
xyzzy
take rod
drop rod
xyzzy
plugh
plugh
west
depression
unlock grate
down
west
take cage
pit
east
take bird
west
down
down
drop bird
quit
" "$OPEN_DATIME" \
"YOU ARE STANDING AT THE END OF A ROAD" \
"YOU ARE INSIDE A BUILDING" \
"OK" \
"YOU ARE ALREADY CARRYING IT!" \
"OK" \
"YOUR LAMP IS NOW ON." \
"YOU ARE IN A DEBRIS ROOM" \
"OK" \
"YOU'RE INSIDE BUILDING." \
"YOU ARE IN A LARGE ROOM" \
"YOU'RE INSIDE BUILDING." \
"YOU'RE AT END OF ROAD AGAIN." \
"20-FOOT DEPRESSION" \
"THE GRATE IS NOW UNLOCKED." \
"SMALL CHAMBER BENEATH A 3X3 STEEL GRATE" \
"CRAWLING OVER COBBLES" \
"SMALL WICKER CAGE" \
"OK" \
"SMALL PIT BREATHING TRACES OF WHITE MIST" \
"SPLENDID CHAMBER THIRTY FEET HIGH" \
"CHEERFUL LITTLE BIRD" \
"OK" \
"VAST HALL STRETCHING FORWARD" \
"HALL OF THE MOUNTAIN KING" \
"HUGE GREEN FIERCE SNAKE BARS THE WAY!" \
"THE LITTLE BIRD ATTACKS THE GREEN SNAKE" \
"DRIVES THE SNAKE AWAY." \
"Quitting game."

# Chunk 10.7: exercises --crowther (10.3's alternate-dataset flag) and 10.6's
# verb restrictions. Movement/take reuse the Lock/unlock scenario's opening
# (same Crowther-era rooms, present in advent-crowther.dat). SCORE/INVENTORY/
# BRIEF/SUSPEND/TOSS/FEED/FILL are typed bare (no object) so the response is
# unambiguously "I don't understand" rather than the generic "what do you
# want to do with that?" a two-word command with a recognized object/unknown
# verb also produces (pre-existing engine behavior, per 10.6's findings in
# IMPLEMENTATION_PLAN.md) — that would still prove
# the verb *word* is gone, but less directly. FIND and THROW are 10.6's kept
# verbs. QUIT's absent score line is checked separately below via
# check_absent, since run_scenario only asserts in-order presence.
run_scenario "Crowther mode: verb restrictions (Chunk 10.6) & clean quit" "--crowther" \
"n
east
take keys
west
score
inventory
brief
suspend
toss
feed
fill
find lamp
throw keys
quit
yes
" "$OPEN_DATIME" \
"Crowther-compatible mode" \
"YOU ARE STANDING AT THE END OF A ROAD" \
"YOU ARE INSIDE A BUILDING" \
"OK" \
"YOU'RE AT END OF ROAD AGAIN." \
"I don't understand that word." \
"I don't understand that word." \
"I don't understand that word." \
"I don't understand that word." \
"I don't understand that word." \
"I don't understand that word." \
"I don't understand that word." \
"I CAN ONLY TELL YOU WHAT YOU SEE" \
"OK" \
"DO YOU REALLY WANT TO QUIT NOW?" \
"OK" \
"Quitting game."
check_absent "QUIT prints no score in Crowther mode" "You scored"

# Chunk 12.8: wizard mode / cave hours coverage. The four scenarios below
# exercise, in turn, (1) the default out-of-the-box experience staying
# unrestricted, (2) a simulated closed-hours refusal when both the wizard
# claim and the short-demo offer are declined, (3) the same closed-hours
# gate but accepting the short demo through to real play, and (4)/(5) the
# "MAGIC MODE" wizard-configuration flow (Chunk 12.4), including the real
# challenge/response cipher (wizard()'s post-12.5 addendum) and an hours
# edit via NEWHRS (Chunk 12.3), followed by a fresh process proving the
# edited hours and a wizard-set MOTD (Chunk 12.7) both persisted to disk
# (Chunk 12.1(b)'s dotfile) and are honored on the next run.

run_scenario "Wizard mode: default hours are unrestricted (POOF defaults)" "" \
"n
quit
yes
" "$OPEN_DATIME" \
"WELCOME TO ADVENTURE!!" \
"YOU ARE STANDING AT THE END OF A ROAD" \
"DO YOU REALLY WANT TO QUIT NOW?" \
"OK" \
"Quitting game."
check_absent "no closed-hours notice during POOF-default open hours" "COLOSSAL CAVE IS CLOSED"
check_absent "wizard() never asked during POOF-default open hours" "ARE YOU A WIZARD?"

run_scenario "Wizard mode: closed-hours refusal (decline wizard claim & short demo)" "" \
"n
n
" "$CLOSED_DATIME" \
"COLOSSAL CAVE IS CLOSED" \
"ONLY WIZARDS ARE PERMITTED WITHIN THE CAVE RIGHT NOW." \
"ARE YOU A WIZARD?" \
"WOULD YOU LIKE TO DO THAT?" \
"VERY WELL."
check_absent "declining both wizard claim and demo never starts a game" "WELCOME TO ADVENTURE!!"

run_scenario "Wizard mode: closed-hours short-demo accepted" "" \
"n
y
n
east
quit
yes
" "$CLOSED_DATIME" \
"COLOSSAL CAVE IS CLOSED" \
"WOULD YOU LIKE TO DO THAT?" \
"WELCOME TO ADVENTURE!!" \
"YOU ARE STANDING AT THE END OF A ROAD" \
"YOU ARE INSIDE A BUILDING" \
"DO YOU REALLY WANT TO QUIT NOW?" \
"Quitting game."

# advent.for:877's literal first-command hook. MAGIC_WORD/MAGNM start at
# POOF's defaults (DWARF/11111) since no adventure.wizcom exists yet
# (cleanup_wizcom above). The "XJLHE"/"OCEET" pair is precomputed by hand
# from wizard()'s own algorithm (advent.for:2600-2622) for MAGIC_DATIME's
# fixed D=20000/T=600 — see COMPLETED_NOTES.md#121's addendum for the
# algorithm this reproduces. Blank lines answer maint()'s raw `read -r`
# prompts (short-game length, magic number, latency) to leave them
# unchanged; the magic-word prompt is answered with the same word again
# instead of a blank line, since it's read via getin(), which (unlike a raw
# `read`) silently skips a blank line rather than accepting it as "leave
# unchanged" (see getin()'s own definition) — re-typing DWARF is a no-op
# edit, not a real change. Ends by editing all three day-classes to "open
# all day" via NEWHRS and setting a MOTD, then confirms both via the bare
# HOURS verb before quitting.
run_scenario "Wizard mode: MAGIC MODE entry, wizard cipher, and NEWHRS edit" "" \
"n
MAGIC MODE
y
DWARF
n
OCEET
n
y
-1
-1
-1
n

DWARF


y
Greetings from the wizard!

hours
quit
yes
" "$MAGIC_DATIME" \
"ARE YOU A WIZARD?" \
"PROVE IT!  SAY THE MAGIC WORD!" \
"XJLHE" \
"OH DEAR, YOU REALLY *ARE* A WIZARD!" \
"NEW HOURS SPECIFIED BY DEFINING \"PRIME TIME\"" \
"Mon - Fri:  Open all day" \
"Sat - Sun:  Open all day" \
"Holidays:   Open all day" \
"OKAY.  YOU CAN SAVE THIS VERSION NOW." \
"COLOSSAL CAVE IS OPEN TO REGULAR ADVENTURERS AT THE FOLLOWING HOURS:" \
"Quitting game."

run_scenario "Wizard mode: edited hours and MOTD persist across a fresh process" "" \
"n
quit
yes
" "$MAGIC_DATIME_2" \
"Greetings from the wizard!" \
"WELCOME TO ADVENTURE!!" \
"DO YOU REALLY WANT TO QUIT NOW?" \
"OK" \
"Quitting game."

cleanup_wizcom

echo
if (( failures == 0 )); then
    echo "All checks passed."
    exit 0
else
    echo "$failures check(s) failed."
    exit 1
fi
