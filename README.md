# ADVENTURESH

A pure Bash port of **Colossal Cave Adventure**, the classic 1977 interactive fiction game originally written in Fortran by Will Crowther and expanded by Don Woods.

This port runs in any modern terminal using **pure Bash**. No external tools are required beyond a standard POSIX-ish shell environment. The game data is fully embedded within the script itself.

## A little history

Colossal Cave Adventure is the grandfather of all interactive fiction and text adventure games. It began as a score-less simulation Will Crowther wrote in 1976-1977, based on his own real-life caving trips through the Bedquilt Cave area of Kentucky's Flint Ridge system. In 1977 Don Woods expanded it into the game most people mean by "Adventure" today — the **350-point** version, adding scoring, treasures, the pirate, hints, a proper endgame, and most of the rooms and puzzles later ports are known for. Virtually every Adventure port since — in any language, on any machine — traces back to one of these two Fortran-IV programs, both written for timesharing PDP-10s.

I first encountered a version of this in the early 1980s on a DEC PDP-11 but only had a printed version of the source code and data file. I meticulously hand-typed it into that system and spent countless hours exploring the cave and trying to find all the treasures. It was a magical experience that I have never forgotten.

It inspired me to write my own text adventure in pascal but unfortunatly that code base has been lost to time.

This project aims to recreate the magic of the original Will Crowther Fortran version using only Bash. It is an exercise in pushing the shell to its limits, converting Fortran's `GOTO`-heavy state machine and integer arrays into Bash flat indexed arrays and `while` loops.

## Why Bash?

You might ask: why would anyone port a 1977 Fortran adventure game to Bash? The answer is the same reason someone would climb a mountain — because it's there. Adventure was originally a triumph of squeezing a rich simulation into tiny memory on a minicomputer. Porting it to Bash is a different kind of constraint: the shell has no business managing game state, parsing complex command strings, or maintaining nested scope. Bash has no real data structures for this, no proper stack, no way to handle the Fortran data files except to parse them raw. And yet, here we are.

Half the joy of this project is seeing how far the shell can be stretched. The game runs entirely within bash integer arrays, parses the Fortran data files natively at startup, and maintains the full 350-point game state using nothing but string manipulation and indexed arrays. The challenge is real, and the victory is genuine: a game that many people have spent hours playing, now running on your laptop's native `/bin/bash`. 

## Requirements

- `bash` 3.2 or newer (the macOS system shell works perfectly)
- A terminal

## Running it

Make the script executable and run it directly:

```bash
chmod +x adventure.sh
./adventure.sh
```

Or run it explicitly with bash:

```bash
bash adventure.sh
```

### Run it straight from the web

You don't have to clone or download the script — you can pipe it into bash directly from the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/rodneyshupe/adventuresh/main/adventure.sh | bash
```

As always, piping a script from the internet straight into a shell runs whatever that URL serves. Have a look at the source first if you'd rather be sure of what you're running.

## Command Parameters

The script supports the following command-line options:

### Game Modes

- `-m, --mixedcase` — Play in mixed-case mode (readable text instead of all uppercase). By default, the game prints everything in uppercase, faithful to the original. This flag makes it more readable.

- `--crowther` — Play in Crowther-compatible mode, using the original 21-location, 19-object version with Crowther's 14-verb command set. This mode removes the Woods expansions: no scoring system, no pirate, and no closing sequence. Requires `advent-crowther.dat` file.

- `--data FILE` — Load game data from an external file instead of the embedded data. Useful for playing alternate versions or mods.

- `--resume [FILE]` — Resume a previously suspended game. Without a filename, it uses the default save file (`.adventure_save` in the current directory). Specify a custom file with `--resume=mysave.txt`.

### Information & Help

- `-h, --help` — Display the help message with usage information.

- `-V, --version` — Display version information about the game.

- `--history` — Display the history and background of Colossal Cave Adventure.

### Examples

```bash
./adventure.sh                      # Start a new 350-point game in uppercase
./adventure.sh --mixedcase          # Start a new game in readable mixed-case
./adventure.sh --crowther           # Play the original Crowther version
./adventure.sh --resume             # Resume your last saved game
./adventure.sh --resume=save2.txt   # Resume from a specific save file
./adventure.sh --data custom.dat    # Load a custom game data file
```

## How to play

You are deep within a cave system. Your goal is to explore, find treasures, and escape. The game presents you with a text description of your surroundings and reads your commands — terse two-word instructions like `GO NORTH` or `GET LAMP`.

### Basic commands

- `NORTH`, `SOUTH`, `EAST`, `WEST` (or `N`, `S`, `E`, `W`) — Move in a direction
- `UP`, `DOWN` (or `U`, `D`) — Move vertically
- `GET` — Pick up an item
- `DROP` — Leave an item behind
- `INVENTORY` — See what you're carrying
- `LOOK` — Describe the current location
- `QUIT` — Exit the game
- `SAVE` — Save your progress
- `RESTORE` — Load a saved game
- `HELP` — Get hints (but be warned: hints are limited!)

The cave is nonlinear and full of dead ends, mazes, and tricky puzzles. Some items are essential, others are treasures. Pay attention to the descriptions — they often contain clues.

## Implementation notes

- The original Fortran code heavily used integer arrays for state (`IOBJ`/`PLACE`, `ICHAIN`/`LINK`, `IPLACE`, `FIXED`). These have been ported to Bash indexed arrays.
- Now, the larger 12-section `advent.dat` (350-point) is embedded directly at the bottom of the bash script and parsed natively at startup.  This script also supports a functioning Crowther version with the neccesary advent-crowther.dat which works with the new loader.
- The game loop and parsing engine rely entirely on Bash string manipulation and file descriptors, avoiding the need for `awk`, `sed`, or associative arrays (to maintain compatibility with Bash 3.2).


## Credits

- **Will Crowther** for the original Colossal Cave Adventure.
- **Don Woods** for expanding the original Adventure.
- **Dennis Jerz** for recovering Crowther's original pre-Woods source from a backup of Don Woods' student account.
- **Alan H. Martin** for providing the 350-point PDP-10 source from a rescued copy of the LINK-10 regression test system.
- **Linards Ticmanis** for the DECUS Maintenance Release 4 FORTRAN 77 re-typing kept under `src/advent4/` as a secondary reference.
- This **Bash port** is a structural translation of the original Fortran sources into shell scripting.
