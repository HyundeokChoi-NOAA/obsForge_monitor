#!/bin/bash
###############################################################################
# Unified realtime monitor + cycle detector + gfs/gdas/gcdas runner
# - Detects which cycle just completed by comparing snapshots
# - Runs only the correct workflow:
#       gfs  → realtime_gfs4.bash <cycle>
#       gdas → realtime_gdas4.bash <cycle> AND realtime_gcdas4.bash <cycle>
# - Sends correct emails
###############################################################################

export TZ="America/New_York"

###############################################################################
# PART 1 — CONFIG
###############################################################################

bases=(
    "/lfs/h2/emc/da/noscrub/emc.da/obsForge_realtime/COMROOT/realtime"
    "/lfs/h2/emc/da/noscrub/Hyundeok.Choi/obsForge_realtime/COMROOT/realtime"
)
products=("gfs" "gdas" "gcdas")
cycles=("00" "06" "12" "18")

TODAY=$(date +%Y%m%d)
TIME=$(date +%H%M)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

SNAPSHOT="/tmp/realtime_monitor.snapshot"
currentDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATUS_LOGDIR="${currentDir}/status_logs"
mkdir -p "$STATUS_LOGDIR"

LOGDIR_RUN="${currentDir}/logs"
mkdir -p "$LOGDIR_RUN"

###############################################################################
# PART 2 — BUILD CURRENT STATE (PER PRODUCT PER BASE)
###############################################################################

state=""
declare -A present_map   # key: "$prod|$base"

for base in "${bases[@]}"; do
    state+="${base}"$'\n'

    for prod in "${products[@]}"; do
        DIR="${base}/${prod}.${TODAY}"
        state+="${prod}.${TODAY}"$'\n'

        present=()
        missing=()

        if [ -d "$DIR" ]; then
            for c in "${cycles[@]}"; do
                if [ -d "${DIR}/${c}" ]; then
                    present+=("$c")
                else
                    missing+=("$c")
                fi
            done

            state+="present=${present[*]:-none} missing=${missing[*]:-none}"$'\n\n'
            present_map["$prod|$base"]="${present[*]}"

        else
            state+="present=none missing=00 06 12 18"$'\n\n'
            present_map["$prod|$base"]=""
        fi
    done
done

state="$(printf "%s" "$state")"

###############################################################################
# PART 3 — INITIAL SNAPSHOT
###############################################################################

if [ ! -f "$SNAPSHOT" ]; then
    echo "$state" > "$SNAPSHOT"

    echo "$state" | mailx -s "Realtime initial status" hyundeok.choi@noaa.gov

    LOGFILE="${STATUS_LOGDIR}/status_dir_${TODAY}_${TIME}.log"
    {
        echo "$TIMESTAMP - Initial snapshot created"
        echo "$state"
    } > "$LOGFILE"

    exit 0
fi

###############################################################################
# PART 4 — COMPARE WITH PREVIOUS SNAPSHOT
###############################################################################

previous="$(cat "$SNAPSHOT")"

if [ "$state" != "$previous" ]; then
    echo -e "ObsForge real time status changed at $TIMESTAMP\n\n$state" \
        | mailx -s "ObsForge real time status changed" hyundeok.choi@noaa.gov

    LOGFILE="${STATUS_LOGDIR}/status_dir_${TODAY}_${TIME}.log"
    {
        echo "$TIMESTAMP - Change detected"
        echo "$state"
    } > "$LOGFILE"

    echo "$state" > "$SNAPSHOT"
fi

###############################################################################
# PART 5 — DETERMINE WHICH CYCLES JUST COMPLETED (PER PRODUCT AND PER BASE)
###############################################################################

declare -A completed_cycles
declare -A completed_base

for prod in gfs gdas gcdas; do
    for base in "${bases[@]}"; do

        # Extract previous present cycles for this base + product
        prev_present=$(echo "$previous" | \
            awk -v b="$base" -v p="${prod}.${TODAY}" '
                # When we hit the base header, start a block
                $0 == b {inblock=1; next}

                # When we hit the next base header, stop the block
                inblock && $0 ~ "^/lfs" {inblock=0}

                # Inside the block, when we hit the product header, mark it
                inblock && $0 ~ p {found=1}

                # Inside the block, after product header, capture present=
                inblock && found && $1 ~ /^present=/ {
                    print substr($0,9)
                    found=0
                }
            ')

        curr_present="${present_map["$prod|$base"]}"

        read -ra prev_arr <<< "$prev_present"
        read -ra curr_arr <<< "$curr_present"

        for c in "${curr_arr[@]}"; do
            if [[ ! " ${prev_arr[*]} " =~ " $c " ]]; then
                completed_cycles["$prod"]="$c"
                completed_base["$prod"]="$base"
            fi
        done

    done
done

###############################################################################
# PART 6 — RUN ONLY THE WORKFLOWS THAT COMPLETED A NEW CYCLE
###############################################################################

# -------------------------
# GFS completed a cycle
# -------------------------
if [[ -n "${completed_cycles[gfs]}" ]]; then
    cycle="${completed_cycles[gfs]}"
    base="${completed_base[gfs]}"

    echo "Detected GFS cycle $cycle completed at base: $base"

    "$currentDir/realtime_gfs.bash" "$cycle" "$base"

    gfs_log="${LOGDIR_RUN}/gfs_${TODAY}_${cycle}.log"
    [ -f "$gfs_log" ] && cat "$gfs_log" | \
        mailx -s "gfs ${TODAY} ${cycle}" hyundeok.choi@noaa.gov
fi

# -------------------------
# GDAS completed a cycle
# -------------------------
if [[ -n "${completed_cycles[gdas]}" ]]; then
    cycle="${completed_cycles[gdas]}"
    base="${completed_base[gdas]}"

    echo "Detected GDAS cycle $cycle completed at base: $base"

    "$currentDir/realtime_gdas.bash" "$cycle" "$base"

    # GDAS 18Z uses yesterday's date
    if [[ "$cycle" == "18" ]]; then
        gdas_date=$(date -d "yesterday" +%Y%m%d)
    else
        gdas_date="$TODAY"
    fi

    gdas_log="${LOGDIR_RUN}/gdas_${gdas_date}_${cycle}.log"
    [ -f "$gdas_log" ] && cat "$gdas_log" | \
        mailx -s "gdas ${gdas_date} ${cycle}" hyundeok.choi@noaa.gov

fi
