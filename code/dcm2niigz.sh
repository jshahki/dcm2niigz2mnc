#!/bin/bash
#SBATCH --job-name=dcm2niigz
#SBATCH --account=st-toddwood-1
#SBATCH --nodes=1
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=200G
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

mapfile -t SUBJECTS < <(
    tail -n +2 "$PARTICIPANTS" |
    cut -f1 |
    sed 's/\r//'
)

SUBJECT="${SUBJECTS[${SLURM_ARRAY_TASK_ID:-0}]:-}"

if [[ -z "$SUBJECT" ]]; then
    echo "No subject found for index ${SLURM_ARRAY_TASK_ID:-0}"
    exit 1
fi

SUBJECT_UPPER="$(printf '%s' "$SUBJECT" | tr '[:lower:]' '[:upper:]')"

# ==================================================
# SUBJECT PATHS
# ==================================================

SUBJECT_DATA_DIR="$DATA_DIR/$SUBJECT"
ZIP_FILE="$SUBJECT_DATA_DIR/$SUBJECT_UPPER.zip"

NIFTI_DIR="$DERIVATIVES_DIR/$SUBJECT/NIfTI"
UNZIP_DIR="$NIFTI_DIR/$SUBJECT_UPPER"

# ==================================================
# LOGGING
# ==================================================

echo "=========================================="
echo "DICOM TO NIFTI"
echo "Subject: $SUBJECT"
echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Array task: ${SLURM_ARRAY_TASK_ID:-0}"
echo "Host: $(hostname)"
echo "Start: $(date)"
echo "=========================================="

echo "Input directory: $SUBJECT_DATA_DIR"
echo "NIfTI output: $NIFTI_DIR"

# ==================================================
# CHECK REQUIREMENTS
# ==================================================

if [[ ! -f "$PARTICIPANTS" ]]; then
    echo "ERROR: Missing participants.tsv: $PARTICIPANTS"
    exit 1
fi

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

for CMD in unzip find grep mktemp; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $CMD"
        exit 1
    fi
done

mkdir -p "$NIFTI_DIR"

# ==================================================
# EXTRACT ZIP IF PRESENT
# ==================================================

EXTRACTED_BY_SCRIPT=0
STAGING_DIR=""

cleanup_staging() {
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}

trap cleanup_staging EXIT

if [[ -f "$ZIP_FILE" ]]; then

    echo "ZIP archive found: $ZIP_FILE"

    if [[ -e "$UNZIP_DIR" ]]; then
        echo "ERROR: Extraction destination already exists:"
        echo "$UNZIP_DIR"
        echo "Refusing to overwrite existing data."
        exit 1
    fi

    STAGING_DIR="$(mktemp -d "$NIFTI_DIR/.staging_${SUBJECT}.XXXXXX")"

    echo "Testing ZIP archive..."
    unzip -tq "$ZIP_FILE"

    echo "Extracting ZIP archive..."
    unzip -q "$ZIP_FILE" -d "$STAGING_DIR"

    mapfile -t TOP_LEVEL < <(
        find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -print
    )

    if (( ${#TOP_LEVEL[@]} == 1 )) &&
       [[ -d "${TOP_LEVEL[0]}" ]] &&
       [[ "$(basename "${TOP_LEVEL[0]}")" == "$SUBJECT_UPPER" ]]; then

        mv -- "${TOP_LEVEL[0]}" "$UNZIP_DIR"
        rmdir "$STAGING_DIR"
        STAGING_DIR=""

    else
        mv -- "$STAGING_DIR" "$UNZIP_DIR"
        STAGING_DIR=""
    fi

    EXTRACTED_BY_SCRIPT=1
    INPUT_DIR="$UNZIP_DIR"

    echo "Extracted input: $INPUT_DIR"

else

    echo "No ZIP archive found; checking for unzipped input."

    if [[ -d "$SUBJECT_DATA_DIR/$SUBJECT_UPPER" ]]; then
        INPUT_DIR="$SUBJECT_DATA_DIR/$SUBJECT_UPPER"

    elif [[ -d "$SUBJECT_DATA_DIR" ]]; then
        INPUT_DIR="$SUBJECT_DATA_DIR"

    else
        echo "ERROR: No usable input directory found."
        exit 1
    fi

    echo "Using existing input: $INPUT_DIR"
    echo "Original input will not be deleted."
fi

# ==================================================
# DICOM -> NIFTI
# ==================================================

echo "=========================================="
echo "Running dcm2niix"
echo "Input: $INPUT_DIR"
echo "Output: $NIFTI_DIR"
echo "=========================================="

"$DCM2NIIX" \
    -z y \
    -d 9 \
    -w 0 \
    -o "$NIFTI_DIR" \
    "$INPUT_DIR"

# ==================================================
# VERIFY NIFTI OUTPUT
# ==================================================

shopt -s nullglob
NIFTI_FILES=("$NIFTI_DIR"/*.nii.gz)
shopt -u nullglob

if (( ${#NIFTI_FILES[@]} == 0 )); then
    echo "ERROR: No .nii.gz files found in $NIFTI_DIR"
    echo "Keeping input data for troubleshooting."
    exit 1
fi

echo "Found ${#NIFTI_FILES[@]} NIfTI file(s):"
printf '  %s\n' "${NIFTI_FILES[@]}"

# ==================================================
# DELETE EXTRACTED DICOM AFTER SUCCESS
# ==================================================

if (( EXTRACTED_BY_SCRIPT == 1 )); then
    echo "NIfTI conversion completed."
    echo "Removing extracted DICOM folder: $UNZIP_DIR"
    rm -rf -- "$UNZIP_DIR"
else
    echo "Input was not extracted by this script."
    echo "Preserving original input data."
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

echo "=========================================="
echo "Finished subject: $SUBJECT"
echo "Output: $NIFTI_DIR"
echo "End: $(date)"
echo "=========================================="
