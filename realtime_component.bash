#!/bin/bash
set -euo pipefail

###############################################################################
# Arguments
###############################################################################
cycle="$1"          # 00, 06, 12, 18
base="$2"           # base directory
component="$3"      # atmos | ocean | chem
prod="$4"           # gfs | gdas | gcdas

###############################################################################
# Environment
###############################################################################
export TZ="America/New_York"
TODAY=$(date +%Y%m%d)
cycle_tag="t${cycle}z"

NCDUMP="/apps/prod/hpc-stack/intel-19.1.3.304/netcdf/4.7.4/bin/ncdump"

# Initialize Lmod for cron
source /usr/share/lmod/lmod/init/bash
module use /apps/prod/hpc-stack/modulefiles/stack
module load hpc/1.2.0

currentDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${currentDir}/logs"
mkdir -p "$LOGDIR"

log_file="${LOGDIR}/${prod}_${component}_${TODAY}_${cycle}.log"
> "$log_file"

###############################################################################
# Expected file lists
###############################################################################
declare -A filelists=(
    ["atmos"]="$currentDir/atmos.txt"
    ["chem"]="$currentDir/chem-viirs.txt"
    ["ocean/adt"]="$currentDir/ocean-adt.txt"
    ["ocean/icec"]="$currentDir/ocean-icec.txt"
    ["ocean/insitu"]="$currentDir/ocean-insitu.txt"
    ["ocean/sss"]="$currentDir/ocean-sss.txt"
    ["ocean/sst"]="$currentDir/ocean-sst.txt"
)

###############################################################################
# Extract N_OBS from NetCDF
###############################################################################
get_nobs() {
    local file="$1"
    local nlocs

    nlocs=$("$NCDUMP" -h "$file" 2>/dev/null |
            awk '/^[[:space:]]*Location[[:space:]]*=/ {print $3; exit}')

    [[ -z "$nlocs" || "$nlocs" == "UNLIMITED" ]] && echo 0 || echo "$nlocs"
}

###############################################################################
# Print table
###############################################################################
print_table() {
    local dir="$1"
    shift
    local expected_files=("$@")

    printf "%-45s | %-45s | %s\n" "FILE NAME" "GENERATED FILE" "N_OBS" >> "$log_file"
    printf "%s\n" "------------------------------------------------------------------------------------------------------------" >> "$log_file"

    for f in "${expected_files[@]}"; do
        fullpath="$dir/$f"

        # Remove gdas.t06z. / gfs.t12z. / gcdas.t18z.
        shortname=$(basename "$f")
        shortname="${shortname#*.}"
        shortname="${shortname#*.}"

        if [[ -f "$fullpath" ]]; then
            n_obs=$(get_nobs "$fullpath")
            printf "%-45s | %-45s | %d\n" "$shortname" "$shortname" "$n_obs" >> "$log_file"
        else
            printf "%-45s | %-45s | %s\n" "$shortname" "" "0" >> "$log_file"
        fi
    done

    echo "" >> "$log_file"
}

###############################################################################
# Main
###############################################################################
echo "completed ${component}" >> "$log_file"

if [[ "$component" == "atmos" ]]; then
    ordered_keys=("atmos")
elif [[ "$component" == "chem" ]]; then
    ordered_keys=("chem")
else
    ordered_keys=("ocean/adt" "ocean/icec" "ocean/insitu" "ocean/sss" "ocean/sst")
fi

for subdir in "${ordered_keys[@]}"; do
    dir="${base}/${prod}.${TODAY}/${cycle}/${subdir}"
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

    mapfile -t suffixes < "$listfile"

    expected_files=()
    for suf in "${suffixes[@]}"; do
        expected_files+=("${prod}.${cycle_tag}.${suf}")
    done

    print_table "$dir" "${expected_files[@]}"
done

mailx -s "ObsForge ${prod^^} ${TODAY} ${cycle} (${component}) completed ($base)" \
      hyundeok.choi@noaa.gov < "$log_file"

