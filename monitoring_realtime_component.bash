#!/bin/bash
###############################################################################
# Unified realtime monitor + cycle + component detector + workflow runner
# - Detects cycle completion (per product/base/cycle)
# - Detects component updates (atmos/ocean/chem)
# - Sends component update emails
# - Sends updated-file-list emails
# - Runs component-specific workflow scripts:
#       realtime_gfs_atmos.bash
#       realtime_gfs_ocean.bash
#       realtime_gdas_atmos.bash
#       realtime_gdas_ocean.bash
#       realtime_gcdas_chem.bash
###############################################################################

set -euo pipefail
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

SNAPSHOT="/tmp/realtime_monitor_task.snapshot"
currentDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATUS_LOGDIR="${currentDir}/status_logs"
mkdir -p "$STATUS_LOGDIR"

LOGDIR_RUN="${currentDir}/logs"
mkdir -p "$LOGDIR_RUN"

declare -A required_components
required_components["gfs"]="atmos ocean"
required_components["gdas"]="atmos ocean"
required_components["gcdas"]="chem"

###############################################################################
# PART 2 — BUILD CURRENT STATE (STABLE VERSION)
###############################################################################

state=""
declare -A present_map

for base in "${bases[@]}"; do
    for prod in "${products[@]}"; do
        DIR="${base}/${prod}.${TODAY}"

        cycles_present=()

        if [[ -d "$DIR" ]]; then
            for c in "${cycles[@]}"; do
                # A cycle is considered present if the cycle directory exists
                [[ -d "${DIR}/${c}" ]] && cycles_present+=("$c")
            done
        fi

        # Build a stable, deterministic line
        # No blank lines, no variable spacing, no missing list
        state+="${base}|${prod}|${TODAY}|present=${cycles_present[*]:-none}"$'\n'

        # Save present cycles for PART 5
        present_map["$prod|$base"]="${cycles_present[*]}"
    done
done

###############################################################################
# PART 3 — INITIAL SNAPSHOT (CLEAN SUMMARY ONLY)
###############################################################################

if [ ! -f "$SNAPSHOT" ]; then

    {
        echo "ObsForge realtime initial status for $TODAY"
        echo ""

        for base in "${bases[@]}"; do
            echo "$base"

            for prod in gfs gdas gcdas; do
                dir="$base/${prod}.${TODAY}"

                if [[ -d "$dir" ]]; then
                    cycles_present=()
                    cycles_missing=()

                    for cycle in 00 06 12 18; do
                        if [[ -d "$dir/$cycle" ]]; then
                            cycles_present+=("$cycle")
                        else
                            cycles_missing+=("$cycle")
                        fi
                    done

                    echo "${prod}: present=${cycles_present[*]:-none}  missing=${cycles_missing[*]:-none}"
                else
                    echo "${prod}: no directory for today"
                fi
            done

            echo ""
        done
    } | mailx -s "ObsForge realtime initial status" hyundeok.choi@noaa.gov

    # Save snapshot for future comparisons
    echo "$state" > "$SNAPSHOT"

    exit 0
fi

previous="$(cat "$SNAPSHOT")"

###############################################################################
# PART 4 — SNAPSHOT CHANGE EMAIL (CLEAN SUMMARY)
###############################################################################

if [ "$state" != "$previous" ]; then

    {
        echo "ObsForge realtime status changed at $TIMESTAMP"
        echo ""

        for base in "${bases[@]}"; do
            echo "$base"

            for prod in gfs gdas gcdas; do
                dir="$base/${prod}.${TODAY}"

                if [[ -d "$dir" ]]; then
                    cycles_present=()
                    cycles_missing=()

                    for cycle in 00 06 12 18; do
                        if [[ -d "$dir/$cycle" ]]; then
                            cycles_present+=("$cycle")
                        else
                            cycles_missing+=("$cycle")
                        fi
                    done

                    echo "${prod}.${TODAY}"
                    echo "present=${cycles_present[*]:-none} missing=${cycles_missing[*]:-none}"
                    echo ""
                fi
            done

            echo ""
        done
    } | mailx -s "ObsForge realtime status changed" hyundeok.choi@noaa.gov

    echo "$state" > "$SNAPSHOT"
fi

###############################################################################
# PART 5 — DETECT CYCLE COMPLETION
###############################################################################

declare -A completed_cycles

for prod in "${products[@]}"; do
    for base in "${bases[@]}"; do

        prev_present=$(echo "$previous" | \
            awk -v b="$base" -v p="${prod}." -v d="$TODAY" '
                $0==b {inblock=1; next}
                inblock && $0 ~ "^/lfs" {inblock=0}
                inblock && $0 ~ p d {found=1}
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
                completed_cycles["$prod|$base"]="$c"
            fi
        done
    done
done

###############################################################################
# PART 5B — DETECT COMPONENT UPDATES
###############################################################################

declare -A prev_component_mtime
declare -A updated_components
declare -A updated_prev_mtime

prev_component_state=$(echo "$previous" | sed -n '/COMPONENT_STATE_BEGIN/,/COMPONENT_STATE_END/p')

while read -r line; do
    [[ "$line" == COMPONENT_STATE_BEGIN || "$line" == COMPONENT_STATE_END ]] && continue
    [[ -z "$line" ]] && continue
    key=$(echo "$line" | awk '{print $1}')
    mtime=$(echo "$line" | awk '{print $2}')
    prev_component_mtime["$key"]="$mtime"
done <<< "$prev_component_state"

for key in "${!component_map[@]}"; do
    curr="${component_map[$key]}"
    prev="${prev_component_mtime[$key]:-0}"
    if (( curr > prev )); then
        updated_components["$key"]=1
        updated_prev_mtime["$key"]="$prev"
    fi
done

###############################################################################
# PART 5C — SEND COMPONENT UPDATE EMAILS
###############################################################################

for key in "${!updated_components[@]}"; do
    IFS='|' read -r prod base cycle comp <<< "$key"

    comp_dir="${base}/${prod}.${TODAY}/${cycle}/${comp}"
    prev_mtime="${updated_prev_mtime[$key]:-0}"

    echo "Component updated: ${comp_dir}" \
        | mailx -s "ObsForge ${prod^^} ${TODAY} ${cycle} (${comp}) updated ($base)" \
          hyundeok.choi@noaa.gov

    if [ "$prev_mtime" -eq 0 ]; then
        updated_files=$(find "$comp_dir" -type f | sort)
    else
        updated_files=$(find "$comp_dir" -type f -newermt "@$prev_mtime" | sort)
    fi

    echo "$updated_files" \
        | mailx -s "ObsForge ${prod^^} ${TODAY} ${cycle} (${comp}) updated files ($base)" \
          hyundeok.choi@noaa.gov
done

###############################################################################
# PART 6 — RUN COMPONENT WORKFLOWS (MASTER SCRIPT)
###############################################################################

for key in "${!updated_components[@]}"; do
    IFS='|' read -r prod base cycle comp <<< "$key"

    # Call the unified component processor
    "$currentDir/monitoring_realtime_component.bash" "$cycle" "$base" "$comp" "$prod"
done
