#!/bin/bash
#SBATCH --job-name=dcm2niigz
#SBATCH --account=st-toddwood-1
#SBATCH --nodes=1
#SBATCH --time=168:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=32G
#SBATCH --output=logs/dcm2niigz_%A_%a.out
#SBATCH --error=logs/dcm2niigz_%A_%a.err

set -Eeuo pipefail

# ==================================================
# PATH SETUP
# ==================================================

REPO_DIR="/scratch/st-toddwood-1/$USER/dcm2niigz2mnc"

DATA_DIR="$REPO_DIR/data"
PARTICIPANTS="$DATA_DIR/participants.tsv"
DERIVATIVES_DIR="$REPO_DIR/derivatives"
TOOLS_DIR="$REPO_DIR/tools"

DCM2NIIX="$TOOLS_DIR/dcm2niix"

# ==================================================
# READ PARTICIPANTS
# Match the working split_bold script
# ==================================================

if [[ ! -f "$PARTICIPANTS" ]]; then
    echo "ERROR: Missing participants file: $PARTICIPANTS"
    exit 1
fi

mapfile -t SUBJECTS < <(
    tail -n +2 "$PARTICIPANTS" |
    cut -f1 |
    sed 's/\r//'
)

TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
SUBJECT="${SUBJECTS[$TASK_ID]:-}"

if [[ -z "$SUBJECT" ]]; then
    echo "No subject found for index $TASK_ID"
    exit 1
fi

SUBJECT_UPPER="$(printf '%s' "$SUBJECT" | tr '[:lower:]' '[:upper:]')"

# ==================================================
# SUBJECT PATHS
# ==================================================

SUBJECT_DATA_DIR="$DATA_DIR/$SUBJECT"
ZIP_FILE="$SUBJECT_DATA_DIR/$SUBJECT_UPPER.zip"

SUBJECT_DERIV_DIR="$DERIVATIVES_DIR/$SUBJECT"
UNZIPPED_DIR="$SUBJECT_DERIV_DIR/unzipped"
NIFTI_DIR="$SUBJECT_DERIV_DIR/NIfTI"

# ==================================================
# LOGGING
# ==================================================

echo "=========================================="
echo "DICOM TO NIFTI"
echo "Subject: $SUBJECT"
echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Array task: $TASK_ID"
echo "Host: $(hostname)"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
START_EPOCH=$(date +%s)
echo "Script started at: $START_TIME"
echo "=========================================="

echo "Source directory: $SUBJECT_DATA_DIR"
echo "Unzipped directory: $UNZIPPED_DIR"
echo "NIfTI output: $NIFTI_DIR"

# ==================================================
# CHECK REQUIREMENTS
# ==================================================

if [[ ! -d "$SUBJECT_DATA_DIR" ]]; then
    echo "ERROR: Subject data directory not found: $SUBJECT_DATA_DIR"
    exit 1
fi

if [[ ! -x "$DCM2NIIX" ]]; then
    if command -v dcm2niix >/dev/null 2>&1; then
        DCM2NIIX="$(command -v dcm2niix)"
    else
        echo "ERROR: dcm2niix executable not found."
        echo "Expected: $TOOLS_DIR/dcm2niix"
        exit 1
    fi
fi

for CMD in unzip find mktemp; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $CMD"
        exit 1
    fi
done

mkdir -p "$SUBJECT_DERIV_DIR" "$NIFTI_DIR"

# ==================================================
# FIND ZIP ARCHIVES
# ==================================================

# Search for ZIP files directly inside the subject's
# data directory. This matches:
# data/subject-c01/SUBJECT-C01.zip

mapfile -t ZIP_FILES < <(
    find "$SUBJECT_DATA_DIR" -maxdepth 1 -type f \
        -iname '*.zip' -print | sort
)

EXTRACTED_BY_SCRIPT=0
INPUT_DIR=""

if (( ${#ZIP_FILES[@]} > 0 )); then

    echo "Found ${#ZIP_FILES[@]} ZIP archive(s):"
    printf '  %s\n' "${ZIP_FILES[@]}"

    # This pipeline expects one archive per subject.
    if (( ${#ZIP_FILES[@]} > 1 )); then
        echo "ERROR: Multiple ZIP archives found for $SUBJECT."
        echo "Please handle these archives explicitly before proceeding."
        exit 1
    fi

    ZIP_FILE="${ZIP_FILES[0]}"

    # Avoid mixing new data with a previous extraction.
    if [[ -e "$UNZIPPED_DIR" ]]; then
        echo "ERROR: Extraction directory already exists:"
        echo "$UNZIPPED_DIR"
        echo "Inspect or rename it before rerunning this subject."
        exit 1
    fi

    # Extract into a temporary directory first so a failed
    # extraction cannot leave a partially populated output.
    STAGING_DIR="$(mktemp -d "$SUBJECT_DERIV_DIR/.unzipped_staging.XXXXXX")"

    cleanup_staging() {
        if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
            rm -rf -- "$STAGING_DIR"
        fi
    }
    trap cleanup_staging EXIT

    echo "Testing archive: $ZIP_FILE"
    unzip -tq "$ZIP_FILE"

    UNZIP_START_EPOCH=$(date +%s)
    echo "Unzipping started at: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo "Extracting archive..."
    unzip -q "$ZIP_FILE" -d "$STAGING_DIR"

    # If the archive contains one top-level directory,
    # use its contents as the unzipped directory.
    mapfile -t TOP_LEVEL < <(
        find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -print
    )

    mkdir -p "$UNZIPPED_DIR"

    if (( ${#TOP_LEVEL[@]} == 1 )) &&
       [[ -d "${TOP_LEVEL[0]}" ]]; then

        # Move the contents of the archive's top-level folder
        # into derivatives/<subject>/unzipped/
        mv -- "${TOP_LEVEL[0]}" "$UNZIPPED_DIR/"

    else
        # Preserve the archive's contents directly.
        find "$STAGING_DIR" -mindepth 1 -maxdepth 1 \
            -exec mv -t "$UNZIPPED_DIR" -- {} +
    fi

    rm -rf -- "$STAGING_DIR"
    STAGING_DIR=""
    trap - EXIT

    EXTRACTED_BY_SCRIPT=1
    INPUT_DIR="$UNZIPPED_DIR"

    UNZIP_END_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    UNZIP_END_EPOCH=$(date +%s)

    echo "Unzipped directory: $UNZIPPED_DIR"
    echo "Unzipping completed at: $UNZIP_END_TIME"
    echo "Unzipping duration: $((UNZIP_END_EPOCH - UNZIP_START_EPOCH)) seconds"

else

    echo "No ZIP files found in $SUBJECT_DATA_DIR"

    # If no ZIP exists, use the original unzipped data.
    # Do not delete original data in this case.
    if [[ -d "$SUBJECT_DATA_DIR/$SUBJECT_UPPER" ]]; then
        INPUT_DIR="$SUBJECT_DATA_DIR/$SUBJECT_UPPER"
    else
        INPUT_DIR="$SUBJECT_DATA_DIR"
    fi

    echo "Using existing input directory: $INPUT_DIR"
fi

# ==================================================
# DICOM -> NIFTI
# ==================================================

echo "=========================================="
echo "Running dcm2niix"
echo "Input: $INPUT_DIR"
echo "Output: $NIFTI_DIR"
echo "=========================================="

# Record dcm2niix start time
DCM2NIIX_START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
DCM2NIIX_START_EPOCH=$(date +%s)

echo "=========================================="
echo "dcm2niix started at: $DCM2NIIX_START_TIME"
echo "=========================================="

if "$DCM2NIIX" \
    -z y \
    -d 9 \
    -w 0 \
    -o "$NIFTI_DIR" \
    "$INPUT_DIR"; then

    echo "dcm2niix returned successfully at $(date '+%Y-%m-%d %H:%M:%S %Z')"

else
    rc=$?
    echo "ERROR: dcm2niix failed with exit code $rc at $(date '+%Y-%m-%d %H:%M:%S %Z')" >&2
    exit "$rc"
fi

# Record dcm2niix end time
DCM2NIIX_END_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
DCM2NIIX_END_EPOCH=$(date +%s)

DCM2NIIX_DURATION=$((DCM2NIIX_END_EPOCH - DCM2NIIX_START_EPOCH))

echo "=========================================="
echo "dcm2niix completed at: $DCM2NIIX_END_TIME"
echo "dcm2niix runtime: $((DCM2NIIX_DURATION / 3600)) hours, $(((DCM2NIIX_DURATION % 3600) / 60)) minutes, $((DCM2NIIX_DURATION % 60)) seconds"
echo "=========================================="

# ==================================================
# VERIFY OUTPUT
# ==================================================

shopt -s nullglob
NIFTI_FILES=("$NIFTI_DIR"/*.nii.gz)
shopt -u nullglob

if (( ${#NIFTI_FILES[@]} == 0 )); then
    echo "ERROR: No .nii.gz files found in $NIFTI_DIR"
    echo "Keeping extracted data for troubleshooting."
    exit 1
fi

echo "Found ${#NIFTI_FILES[@]} NIfTI file(s):"
printf '  %s\n' "${NIFTI_FILES[@]}"

# ==================================================
# DELETE EXTRACTED DATA AFTER SUCCESS
# ==================================================

if (( EXTRACTED_BY_SCRIPT == 1 )); then

    echo "dcm2niix completed and NIfTI files were verified."
    echo "Removing temporary extracted directory:"
    echo "$UNZIPPED_DIR"

    rm -rf -- "$UNZIPPED_DIR"

else
    echo "Input was not extracted by this script."
    echo "Original input data will be preserved."
fi

# ==================================================
# STATUS LOG
# ==================================================

STATUS_FILE="$REPO_DIR/logs/status/${SUBJECT}_dcm2niigz_SUCCESS.txt"
mkdir -p "$(dirname "$STATUS_FILE")"

{
    echo "Subject: $SUBJECT"
    echo "Job ID: ${SLURM_JOB_ID:-unknown}"
    echo "Completed: $(date)"
    echo "NIfTI files: ${#NIFTI_FILES[@]}"
    echo "Output directory: $NIFTI_DIR"
} > "$STATUS_FILE"

# ==================================================
# FINAL COMPLETION TIME
# ==================================================

SCRIPT_END_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
SCRIPT_END_EPOCH=$(date +%s)

TOTAL_RUNTIME=$((SCRIPT_END_EPOCH - START_EPOCH))

echo "=========================================="
echo "PIPELINE COMPLETED SUCCESSFULLY"
echo "Subject: $SUBJECT"
echo "NIfTI output: $NIFTI_DIR"
echo "Script started: $START_TIME"
echo "dcm2niix runtime: $((DCM2NIIX_DURATION / 3600)) hours, $(((DCM2NIIX_DURATION % 3600) / 60)) minutes, $((DCM2NIIX_DURATION % 60)) seconds"
echo "Final completion time: $SCRIPT_END_TIME"
echo "Total script runtime: $((TOTAL_RUNTIME / 3600)) hours, $(((TOTAL_RUNTIME % 3600) / 60)) minutes, $((TOTAL_RUNTIME % 60)) seconds"
echo "=========================================="
