
#!/bin/bash
#SBATCH --job-name=dcm2niigz2mnc
#SBATCH --time=24:00:00
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --account=st-toddwood-1
#SBATCH --output=logs/dcm2niigz2mnc_%A_%a.out
#SBATCH --error=logs/dcm2niigz2mnc_%A_%a.err

set -Eeuo pipefail

# ==================================================
# Paths
# ==================================================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DATA_DIR="$REPO_DIR/data"
PARTICIPANTS_FILE="$DATA_DIR/participants.tsv"
DERIVATIVES_DIR="$REPO_DIR/derivatives"
TOOLS_DIR="$REPO_DIR/tools"

DCM2NIIX="$TOOLS_DIR/dcm2niix"

# One subject per array task
SUB_SIZE=1

# ==================================================
# Logging
# ==================================================
echo "=========================================="
echo "DICOM -> NIfTI -> MINC"
echo "User: ${USER:-unknown}"
echo "Host: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID:-interactive}"
echo "Array task: ${SLURM_ARRAY_TASK_ID:-0}"
echo "Start: $(date)"
echo "=========================================="

# ==================================================
# Check requirements
# ==================================================
if [[ ! -f "$PARTICIPANTS_FILE" ]]; then
    echo "ERROR: Missing participants file: $PARTICIPANTS_FILE"
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

if ! command -v nii2mnc >/dev/null 2>&1; then
    echo "ERROR: nii2mnc not found in PATH."
    echo "Load a compatible MINC toolkit module before running."
    exit 1
fi

NII2MNC="$(command -v nii2mnc)"

# ==================================================
# Read participants.tsv
# ==================================================
mapfile -t SUBJECTS < <(
    tail -n +2 "$PARTICIPANTS_FILE" |
    cut -f1 |
    tr -d '\r' |
    sed '/^[[:space:]]*$/d'
)

N_SUBJECTS=${#SUBJECTS[@]}
TASK_ID=${SLURM_ARRAY_TASK_ID:-0}

START_INDEX=$((TASK_ID * SUB_SIZE))
END_INDEX=$((START_INDEX + SUB_SIZE))

if (( START_INDEX >= N_SUBJECTS )); then
    echo "No subject assigned to task $TASK_ID."
    exit 0
fi

# ==================================================
# Process assigned subjects
# ==================================================
for ((i = START_INDEX; i < END_INDEX && i < N_SUBJECTS; i++)); do

    SUBJECT_ID="${SUBJECTS[$i]}"
    SUBJECT_UPPER="$(printf '%s' "$SUBJECT_ID" | tr '[:lower:]' '[:upper:]')"

    SUBJECT_DATA_DIR="$DATA_DIR/$SUBJECT_ID"
    ZIP_FILE="$SUBJECT_DATA_DIR/$SUBJECT_UPPER.zip"

    NIFTI_DIR="$DERIVATIVES_DIR/$SUBJECT_ID/NIfTI"
    MINC_DIR="$DERIVATIVES_DIR/$SUBJECT_ID/MINC"
    UNZIP_DIR="$NIFTI_DIR/$SUBJECT_UPPER"

    EXTRACTED_BY_SCRIPT=0
    STAGING_DIR=""

    echo
    echo "=========================================="
    echo "Subject: $SUBJECT_ID"
    echo "Start: $(date)"
    echo "=========================================="

    mkdir -p "$NIFTI_DIR" "$MINC_DIR"

    # ----------------------------------------------
    # Identify input and extract ZIP if needed
    # ----------------------------------------------
    if [[ -f "$ZIP_FILE" ]]; then

        echo "ZIP found: $ZIP_FILE"

        if [[ -e "$UNZIP_DIR" ]]; then
            echo "ERROR: Extraction destination already exists:"
            echo "$UNZIP_DIR"
            echo "Refusing to overwrite existing data."
            exit 1
        fi

        STAGING_DIR="$(mktemp -d "$NIFTI_DIR/.staging_${SUBJECT_ID}.XXXXXX")"

        echo "Testing ZIP archive..."
        unzip -tq "$ZIP_FILE"

        echo "Extracting ZIP archive..."
        unzip -q "$ZIP_FILE" -d "$STAGING_DIR"

        # Preserve the archive's directory structure.
        # If it contains a single SUBJECT-C01 folder,
        # place that folder directly at UNZIP_DIR.
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

        echo "Extracted DICOM directory: $INPUT_DIR"

    else

        echo "No ZIP found; looking for existing unzipped data."

        if [[ -d "$SUBJECT_DATA_DIR/$SUBJECT_UPPER" ]]; then
            INPUT_DIR="$SUBJECT_DATA_DIR/$SUBJECT_UPPER"
        elif [[ -d "$SUBJECT_DATA_DIR" ]]; then
            INPUT_DIR="$SUBJECT_DATA_DIR"
        else
            echo "ERROR: No ZIP or input directory for $SUBJECT_ID"
            exit 1
        fi

        echo "Using existing input: $INPUT_DIR"
        echo "Original input will be preserved."
    fi

    # ----------------------------------------------
    # Convert DICOM to NIfTI
    # ----------------------------------------------
    echo "Running dcm2niix..."

    "$DCM2NIIX" \
        -z y \
        -d 9 \
        -w 0 \
        -o "$NIFTI_DIR" \
        "$INPUT_DIR"

    # ----------------------------------------------
    # Find NIfTI files
    # ----------------------------------------------
    shopt -s nullglob
    NIFTI_FILES=("$NIFTI_DIR"/*.nii.gz)
    shopt -u nullglob

    if (( ${#NIFTI_FILES[@]} == 0 )); then
        echo "ERROR: No .nii.gz files found in $NIFTI_DIR"
        echo "Keeping input data for troubleshooting."
        exit 1
    fi

    echo "Found ${#NIFTI_FILES[@]} NIfTI file(s)."

    # ----------------------------------------------
    # Convert each NIfTI to MINC
    # ----------------------------------------------
    echo "Running nii2mnc..."

    for NIFTI_FILE in "${NIFTI_FILES[@]}"; do

        BASENAME="$(basename "$NIFTI_FILE" .nii.gz)"
        MINC_FILE="$MINC_DIR/$BASENAME.mnc"

        echo "------------------------------------------"
        echo "Input:  $NIFTI_FILE"
        echo "Output: $MINC_FILE"

        if [[ -s "$MINC_FILE" ]]; then
            echo "MINC output already exists; skipping: $MINC_FILE"
            continue
        fi

        # Write to a temporary file so incomplete outputs
        # are not mistaken for completed conversions.
        TEMP_MINC="$MINC_DIR/.${BASENAME}.$$.$RANDOM.mnc"

        if ! "$NII2MNC" "$NIFTI_FILE" "$TEMP_MINC"; then
            echo "ERROR: nii2mnc failed for $NIFTI_FILE"
            rm -f -- "$TEMP_MINC"
            echo "Keeping extracted DICOM data for troubleshooting."
            exit 1
        fi

        if [[ ! -s "$TEMP_MINC" ]]; then
            echo "ERROR: MINC output is missing or empty."
            rm -f -- "$TEMP_MINC"
            exit 1
        fi

        mv -- "$TEMP_MINC" "$MINC_FILE"

        echo "Converted successfully: $MINC_FILE"
    done

    # ----------------------------------------------
    # Verify MINC outputs
    # ----------------------------------------------
    MINC_COUNT=0

    for NIFTI_FILE in "${NIFTI_FILES[@]}"; do
        BASENAME="$(basename "$NIFTI_FILE" .nii.gz)"
        MINC_FILE="$MINC_DIR/$BASENAME.mnc"

        if [[ ! -s "$MINC_FILE" ]]; then
            echo "ERROR: Missing MINC output: $MINC_FILE"
            echo "Keeping extracted DICOM data for troubleshooting."
            exit 1
        fi

        ((MINC_COUNT += 1))
    done

    echo "Verified $MINC_COUNT MINC output(s)."

    # ----------------------------------------------
    # Remove extracted DICOM folder only after success
    # ----------------------------------------------
    if (( EXTRACTED_BY_SCRIPT == 1 )); then
        echo "Both conversions succeeded."
        echo "Removing extracted DICOM folder: $UNZIP_DIR"
        rm -rf -- "$UNZIP_DIR"
    fi

    echo "Finished subject: $SUBJECT_ID"
    echo "NIfTI directory: $NIFTI_DIR"
    echo "MINC directory: $MINC_DIR"
    echo "End: $(date)"

done

echo
echo "=========================================="
echo "Task completed successfully."
echo "End: $(date)"
echo "=========================================="
