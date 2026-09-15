# ADVENTURESH

A pure Bash port of **Colossal Cave Adventure**, the classic 1976 interactive fiction game originally written in Fortran by Will Crowther.

This port runs in any modern terminal using **pure Bash**. No external tools are required beyond a standard POSIX-ish shell environment. The game data is fully embedded within the script itself.

## A little history

Colossal Cave Adventure is the grandfather of all interactive fiction and text adventure games. Originally created in 1976-1977 by Will Crowther and expanded in 1977 by Don Woods, it captivated early computer users on mainframes like the PDP-10. 

I first encountered a version of this in the early 1980s on a DEC PDP-11 but only had a printed version of the source code and data file. I meticulously hand-typed it into that system and spent countless hours exploring the cave and trying to find all the treasures. It was a magical experience that I have never forgotten.

It inspired me to write my own text adventure in pascal but unfortunatly that code base has been lost to time.

This project aims to recreate the magic of the original Will Crowther Fortran version using only Bash. It is an exercise in pushing the shell to its limits, converting Fortran's `GOTO`-heavy state machine and integer arrays into Bash flat indexed arrays and `while` loops. 

## Requirements

- `bash` 3.2 or newer (the macOS system shell works perfectly)
- A terminal

## Running it

```bash
chmod +x adventure.sh
./adventure.sh
```

## Implementation notes

- The original Fortran code (`77-03-31_adventure.f`) heavily used integer arrays for state (`IOBJ`, `ICHAIN`, `IPLACE`). These have been ported to Bash indexed arrays.
- The massive 700+ line data file (`77-03-31_adventure.dat`) is embedded directly at the bottom of the bash script and parsed natively at startup.
- The game loop and parsing engine rely entirely on Bash string manipulation and file descriptors, avoiding the need for `awk`, `sed`, or associative arrays (to maintain compatibility with Bash 3.2).

## Credits

- **Will Crowther** for the original Colossal Cave Adventure.
- This **Bash port** is a structural translation of the 1977 Fortran source into shell scripting.
