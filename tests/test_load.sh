#!/bin/bash
set -u
declare -a RAW_TRAVEL=()

# Test reading from the data section
section=-1
in_data=0
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
    
    if (( section == 3 )); then
        RAW_TRAVEL+=("$line")
    fi
done < "$0"

echo "RAW_TRAVEL has ${#RAW_TRAVEL[@]} entries"
if (( ${#RAW_TRAVEL[@]} > 0 )); then
    echo "First entry: ${RAW_TRAVEL[0]}"
fi

exit 0
: <<'DATA_START'
3
1	2	2	44
1	3	3	12	19	43
-1
0
DATA_START
