#!/usr/bin/env bash
###############################################################################
# Unified realtime cycle + component monitor (NORMAL + DEBUG MODE)
#
# NORMAL:
#   ./monitoring_realtime_component.bash
#   - Sends emails
#   - Updates real snapshot
#
# DEBUG:
#   ./monitoring_realtime_component.bash --debug
#   - Same behavior as normal (emails + snapshot)
#   - PLUS full trace printed and logged (timestamped)
###############################################################################

export TZ="America/New_York"

###############################################################################
# PART 1 — CONFIG & DEBUG SETUP
###############################################################################

DEBUG=0
if [[ "$1" == "--debug" ]]; then
    DEBUG=1
fi

bases=(
    "/lfs/h2/emc/da/noscrub/emc.da/obsForge_realtime/COMROOT/realtime"
    "/lfs/h2/emc/da/noscrub/Hyundeok.Choi/obsForge_realtime/COMROOT/realtime"
)

products=("gfs" "gdas" "gcdas")
cycles=("00" "06" "12" "18")

TODAY=$(date +%Y%m%d)
TIME=$(date +%H%M)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")


currentDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


SNAPSHOT="${currentDir}/SNAPSHOT/realtime_cycle_monitor.snapshot"

STATUS_LOGDIR="${currentDir}/status_logs"
mkdir -p "$STATUS_LOGDIR"

LOGDIR_RUN="${currentDir}/logs"
mkdir -p "$LOGDIR_RUN"

DEBUG_LOGDIR="${LOGDIR_RUN}/debug"
mkdir -p "$DEBUG_LOGDIR"

if [[ $DEBUG -eq 1 ]]; then
    DEBUG_LOGFILE="${DEBUG_LOGDIR}/debug_${TODAY}_${TIME}.log"
    echo "================ DEBUG RUN ================" | tee -a "$DEBUG_LOGFILE"
    echo "Timestamp: $TIMESTAMP" | tee -a "$DEBUG_LOGFILE"
    echo "Today:     $TODAY" | tee -a "$DEBUG_LOGFILE"
    echo | tee -a "$DEBUG_LOGFILE"
fi

EXPECT_DIR="/lfs/h2/emc/da/noscrub/Hyundeok.Choi/obsForge_monitor"

MAIL_TO="hyundeok.choi@noaa.gov"

dbg() {
    if [[ $DEBUG -eq 1 ]]; then
        echo "$@" | tee -a "$DEBUG_LOGFILE"
    fi
}

###############################################################################
# PART 2 — N_OBS helper
###############################################################################

get_nobs() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo 0
        return
    fi

    local nlocs
    nlocs=$(ncdump -h "$file" 2>/dev/null | awk '/Location *=/ {print $3; exit}')

    if [[ -z "$nlocs" || "$nlocs" == "UNLIMITED" ]]; then
        echo 0
    else
        echo "$nlocs"
    fi
}

###############################################################################
# PART 3 — BUILD CURRENT STATE
###############################################################################

state=""
declare -A present_map

dbg ">>> Building current state"

for base in "${bases[@]}"; do
    state+="${base}"$'\n'
    dbg "Base: $base"

    for prod in "${products[@]}"; do
        DIR="${base}/${prod}.${TODAY}"
        state+="${prod}.${TODAY}"$'\n'
        dbg "  Product: $prod"

        present=()
        missing=()

        if [[ -d "$DIR" ]]; then
            for c in "${cycles[@]}"; do
                if [[ -d "${DIR}/${c}" ]]; then
                    present+=("$c")
                    dbg "    Cycle $c: PRESENT"
                else
                    missing+=("$c")
                    dbg "    Cycle $c: missing"
                fi
            done

            state+="present=${present[*]:-none} missing=${missing[*]:-none}"$'\n\n'
            present_map["$prod|$base"]="${present[*]}"
        else
            state+="present=none missing=00 06 12 18"$'\n\n'
            present_map["$prod|$base"]=""
            dbg "    No directory for $prod.$TODAY"
        fi
    done
done

dbg ""
dbg ">>> Current state:"
dbg "----------------------------------------------------"
dbg "$state"
dbg "----------------------------------------------------"
dbg ""

###############################################################################
# PART 4 — SNAPSHOT HANDLING
###############################################################################

if [[ ! -f "$SNAPSHOT" ]]; then
    echo "$state" > "$SNAPSHOT"
    dbg ">>> Initial snapshot created at $SNAPSHOT"

    echo "$state" | mailx -s "ObsForge real-time initial status" "$MAIL_TO"

    LOGFILE="${STATUS_LOGDIR}/status_dir_${TODAY}_${TIME}.log"
    {
        echo "$TIMESTAMP - Initial snapshot created"
        echo "$state"
    } > "$LOGFILE"

    dbg ">>> Initial status email sent"
    exit 0
fi

previous="$(cat "$SNAPSHOT")"

if [[ "$state" != "$previous" ]]; then
    dbg ">>> Status changed vs previous snapshot"
    dbg ">>> Sending status change email"

    echo -e "ObsForge real-time status changed at $TIMESTAMP\n\n$state" \
        | mailx -s "ObsForge real time status changed" "$MAIL_TO"

    LOGFILE="${STATUS_LOGDIR}/status_dir_${TODAY}_${TIME}.log"
    {
        echo "$TIMESTAMP - Change detected"
        echo "$state"
    } > "$LOGFILE"

    echo "$state" > "$SNAPSHOT"
    dbg ">>> Snapshot updated at $SNAPSHOT"
else
    dbg ">>> No change in status vs previous snapshot"
fi

###############################################################################
# PART 5 — DETERMINE NEWLY COMPLETED CYCLES
###############################################################################

declare -A completed_cycles
declare -A all_present_cycles

dbg ""
dbg ">>> Detecting new cycles"

for prod in "${products[@]}"; do
    for base in "${bases[@]}"; do

        prev_present=$(echo "$previous" | \
            awk -v b="$base" -v p="${prod}.${TODAY}" '
                $0 == b {inblock=1; next}
                inblock && $0 ~ "^/lfs" {inblock=0}
                inblock && $0 == p {found=1; next}
                inblock && found && $1 ~ /^present=/ {
                    print substr($0,9)
                    found=0
                }
            ')

        curr_present="${present_map["$prod|$base"]}"

        # Save ALL present cycles for PART 6
        all_present_cycles["$prod|$base"]="$curr_present"

        read -ra prev_arr <<< "$prev_present"
        read -ra curr_arr <<< "$curr_present"

        for c in "${curr_arr[@]}"; do
            if [[ ! " ${prev_arr[*]} " =~ " $c " ]]; then
                completed_cycles["$prod|$base"]+="$c "
                dbg "NEW CYCLE: prod=$prod base=$base cycle=$c"
            fi
        done
    done
done

dbg ""
dbg ">>> Completed cycles map:"
for key in "${!completed_cycles[@]}"; do
    dbg "  $key -> ${completed_cycles[$key]}"
done
dbg ""

###############################################################################
# PART 6 — COMPONENT EMAILS (WITH COMPONENT-LEVEL DETECTION)
###############################################################################

# IMPORTANT:
# This now loops over ALL PRESENT CYCLES, not only newly completed cycles.
for key in "${!all_present_cycles[@]}"; do
    prod="${key%%|*}"
    base="${key##*|}"
    cycles_now="${all_present_cycles[$key]}"

    # Tag for email subject
    if [[ "$base" == *"/emc.da/"* ]]; then
        tag="emc.da"
    elif [[ "$base" == *"/Hyundeok.Choi/"* ]]; then
        tag="backup"
    else
        tag="unknown"
    fi

    # Component list:
    # gfs, gdas → atmos + ocean
    # gcdas → chem only, but chem should NOT trigger component-level detection
    case "$prod" in
        gfs|gdas)
            components=("atmos" "ocean")
            ;;
        gcdas)
            components=()   # chem excluded from component-level detection
            ;;
    esac

    for cycle in $cycles_now; do
        DIR="${base}/${prod}.${TODAY}/${cycle}"

        dbg "----------------------------------------------------"
        dbg "Product: $prod"
        dbg "Cycle:   $cycle"
        dbg "Base:    $base"
        dbg "Dir:     $DIR"
        dbg "----------------------------------------------------"

        for comp in "${components[@]}"; do
            comp_dir="${DIR}/${comp}"
            expected_list="${EXPECT_DIR}/${comp}.txt"

            dbg ""
            dbg "  Component: $comp"
            dbg "  Directory: $comp_dir"

            # Component snapshot path
            COMP_SNAP="/tmp/component_state_${prod}_${TODAY}_${cycle}_${comp}.snapshot"

            # Determine current component state
            if [[ -d "$comp_dir" ]]; then
                current_state="present"
            else
                current_state="missing"
            fi

            # Read previous state if exists
            if [[ -f "$COMP_SNAP" ]]; then
                previous_state=$(cat "$COMP_SNAP")
            else
                previous_state="none"
            fi

            dbg "    Previous state: $previous_state"
            dbg "    Current state:  $current_state"

            #
            # CASE 1 — Component state changed
            #
            if [[ "$current_state" != "$previous_state" ]]; then
                dbg ">>> Component state changed for $prod $cycle $comp: $previous_state → $current_state"

                #
                # CASE 1A — Component just appeared → send FULL FILE TABLE EMAIL
                #
                if [[ "$current_state" == "present" ]]; then

                    body=""
                    body+="Component updated"$'\n'
                    body+="Product: ${prod}"$'\n'
                    body+="Cycle: ${cycle}"$'\n'
                    body+="Component: ${comp}"$'\n'
                    body+="Base: ${base}"$'\n\n'

                    body+="FILE NAME                                     | GENERATED FILE                                | N_OBS"$'\n'
                    body+="------------------------------------------------------------------------------------------------------------"$'\n'

                    if [[ -f "$expected_list" ]]; then
                        while IFS= read -r expected_file; do
                            [[ -z "$expected_file" ]] && continue

                            match=$(ls "${comp_dir}"/*"${expected_file}" 2>/dev/null | head -1)
                            if [[ -n "$match" ]]; then
                                generated="$expected_file"
                                nobs=$(get_nobs "$match")
                            else
                                generated=""
                                nobs=0
                            fi

                            line=$(printf "%-45s | %-45s | %s" \
                                "$expected_file" "$generated" "$nobs")
                            body+="$line"$'\n'
                        done < "$expected_list"
                    else
                        body+="(expected list missing)"$'\n'
                    fi

                    subject="[$tag] ${prod^^} ${TODAY} ${cycle} ${comp} updated"

                    dbg ""
                    dbg ">>> EMAIL (FULL TABLE):"
                    dbg "Subject: $subject"
                    dbg "$body"
                    dbg ">>> END EMAIL"
                    dbg ""

                    echo "$body" | mailx -s "$subject" "$MAIL_TO"

                #
                # CASE 1B — Component disappeared → send SIMPLE STATE CHANGE EMAIL
                #
                else
                    body="Component state changed
Product: ${prod}
Cycle: ${cycle}
Component: ${comp}
Base: ${base}

State changed: ${previous_state} → ${current_state}
"

                    subject="[$tag] ${prod^^} ${TODAY} ${cycle} ${comp} state changed"

                    dbg ""
                    dbg ">>> EMAIL (STATE CHANGE):"
                    dbg "Subject: $subject"
                    dbg "$body"
                    dbg ">>> END EMAIL"
                    dbg ""

                    echo "$body" | mailx -s "$subject" "$MAIL_TO"
                fi

                # Update snapshot
                echo "$current_state" > "$COMP_SNAP"

            else
                dbg ">>> No change in component state for $prod $cycle $comp"
            fi

        done
    done
done

dbg ">>> Run complete (emails sent, snapshot updated)"
