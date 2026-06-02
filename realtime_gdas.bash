#!/bin/bash
set -euo pipefail

NCDUMP="/apps/prod/hpc-stack/intel-19.1.3.304/netcdf/4.7.4/bin/ncdump"

# Initialize Lmod for cron
source /usr/share/lmod/lmod/init/bash

# Now module command works
module use /apps/prod/hpc-stack/modulefiles/stack
module load hpc/1.2.0


today=$(date +%Y%m%d)
hour=${1:-00}
cycle="t${hour}z"

# If hour is 18, use yesterday's date
if [ "$hour" = "18" ]; then
    today=$(date -d "yesterday" +%Y%m%d)
fi

# Base directory
#obsforgeDir="/lfs/h2/emc/da/noscrub/Hyundeok.Choi/obsForge_realtime/COMROOT/obsforge"
obsforgeDir="${2:-/lfs/h2/emc/da/noscrub/emc.da/obsForge_realtime/COMROOT/realtime}"
currentDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mapping subdirectories → expected list files
declare -A filelists=(
    ["atmos"]="$currentDir/atmos.txt"
    ["ocean/adt"]="$currentDir/ocean-adt.txt"
    ["ocean/icec"]="$currentDir/ocean-icec.txt"
    ["ocean/insitu"]="$currentDir/ocean-insitu.txt"
    ["ocean/sss"]="$currentDir/ocean-sss.txt"
    ["ocean/sst"]="$currentDir/ocean-sst.txt"
    ["chem"]="$currentDir/chem-viirs.txt"
)

# Log file
log_file="$currentDir/logs/gdas_${today}_${hour}.log"
> "$log_file"

###############################################
# Helper: Extract number of observations (nlocs)
###############################################
get_nobs() {
    local file="$1"

    # Extract "Location" dimension from NetCDF header
    local nlocs
    nlocs=$("$NCDUMP" -h "$file" 2>/dev/null |
            awk '/^[[:space:]]*Location[[:space:]]*=/ {print $3; exit}')
    # Fallback if parsing fails
    if [[ -z "$nlocs" || "$nlocs" == "UNLIMITED" ]]; then
        echo 0
    else
        echo "$nlocs"
    fi
}

###############################################
# Function: Print 3-column table
###############################################
print_table() {
    local dir="$1"
    shift
    local expected_files=("$@")

    printf "%-45s | %-45s | %s\n" "FILE NAME" "GENERATED FILE" "N_OBS" >> "$log_file"
    printf "%s\n" "------------------------------------------------------------------------------------------------------------" >> "$log_file"

    for f in "${expected_files[@]}"; do
        local fullpath="$dir/$f"

        if [[ -f "$fullpath" ]]; then
            local n_obs
            n_obs=$(get_nobs "$fullpath")
            printf "%-45s | %-45s | %d\n" "$f" "$f" "$n_obs" >> "$log_file"
        else
            printf "%-45s | %-45s | %s\n" "$f" "" "0" >> "$log_file"
        fi
    done

    echo "" >> "$log_file"
}

###############################################
# Main loop
###############################################
ordered_keys=( "atmos"
               "ocean/adt"
               "ocean/icec"
               "ocean/insitu"
               "ocean/sss"
               "ocean/sst"
               "chem" )

for subdir in "${ordered_keys[@]}"; do
    if [[ "$subdir" == "chem" ]]; then
        dir="$obsforgeDir/gcdas.${today}/${hour}/${subdir}"
    else
        dir="$obsforgeDir/gdas.${today}/${hour}/${subdir}"
    fi

    listfile="${filelists[$subdir]}"

    echo "Directory: $dir" >> "$log_file"

    if [[ ! -d "$dir" ]]; then
        echo "  [ERROR] Directory does not exist" >> "$log_file"
        echo "" >> "$log_file"
        continue
    fi

    if [[ ! -f "$listfile" ]]; then
        echo "  [ERROR] Missing expected list file: $listfile" >> "$log_file"
        echo "" >> "$log_file"
        continue
    fi

    # Read suffixes from text file
    mapfile -t suffixes < "$listfile"

    # Build full expected filenames
    expected_files=()
    for suf in "${suffixes[@]}"; do
        if [[ "$subdir" == "chem" ]]; then
            expected_files+=("gcdas.${cycle}.${suf}")
        else
            expected_files+=("gdas.${cycle}.${suf}")
        fi
    done

    # Print table comparing expected vs actual
    print_table "$dir" "${expected_files[@]}"
done

echo "Diagnostics complete. Results saved to $log_file"
