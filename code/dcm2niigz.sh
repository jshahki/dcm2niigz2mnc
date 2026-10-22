
#!/bin/bash
#SBATCH --job-name=dcm2niigz
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --account=st-toddwood-1
#SBATCH --output=logs/dcm2niigz_%A_%a.out
#SBATCH --error=logs/dcm2niigz_%A_%a.err

set -Eeuo pipefail

# --------------------------------------------------
# Paths
# --------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DATA_DIR="$REPO_DIR/data"
PARTICIPANTS_FILE="$DATA_DIR/participants.tsv"
DERIVATIVES_DIR="$REPO_DIR/derivatives"
TOOLS_DIR="$REPO_DIR/tools"

DCM2NIIX="$TOOLS_DIR/dcm2niix"

# One subject per array task
SUB_SIZE=1

# --------------------------------------------------
# Logging
# --------------------------------------------------
echo "=========================================="
echo "DICOM TO NIFTI"
echo "Host: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID:-interactive}"
echo "Array task: ${SLURM_ARRAY_TASK_ID:-0}"
echo "Start: $(date)"
echo "=========================================="

# --------------------------------------------------
# Check requirements
# --------------------------------------------------
if [[ ! -f "$PARTICIPANTS_FILE" ]]; then
    echo "ERROR: Missing $PARTICIPANTS_FILE"
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

# --------------------------------------------------
# Read participant IDs
# --------------------------------------------------
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

# --------------------------------------------------
# Process assigned subject(s)
# --------------------------------------------------
for ((i = START_INDEX; i < END_INDEX && i < N_SUBJECTS; i++)); do

    SUBJECT_ID="${SUBJECTS[$i]}"

    # Expected archive/folder names:
    # data/subject-c01/SUBJECT-C01.zip
    SUBJECT_UPPER="$(printf '%s' "$SUBJECT_ID" | tr '[:lower:]' '[:upper:]')"

    SUBJECT_DATA_DIR="$DATA_DIR/$SUBJECT_ID"
    ZIP_FILE="$SUBJECT_DATA_DIR/$SUBJECT_UPPER.zip"

    NIFTI_DIR="$DERIVATIVES_DIR/$SUBJECT_ID/NIfTI"
    UNZIP_DIR="$NIFTI_DIR/$SUBJECT_UPPER"

    echo
    echo "------------------------------------------"
    echo "Subject: $SUBJECT_ID"
    echo "Start: $(date)"
    echo "------------------------------------------"

    mkdir -p "$NIFTI_DIR"

    # ----------------------------------------------
    # Identify the DICOM input
    # ----------------------------------------------
    EXTRACTED_BY_SCRIPT=0

    if [[ -f "$ZIP_FILE" ]]; then

        echo "ZIP archive found: $ZIP_FILE"

        if [[ -e "$UNZIP_DIR" ]]; then
            echo "ERROR: Extraction destination already exists:"
            echo "$UNZIP_DIR"
            echo "Refusing to overwrite existing data."
            exit 1
        fi

        # Extract to a temporary staging directory first.
        STAGING_DIR="$(mktemp -d "$NIFTI_DIR/.staging_${SUBJECT_ID}.XXXXXX")"

        cleanup_staging() {
            if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
                rm -rf -- "$STAGING_DIR"
            fi
        }
        trap cleanup_staging EXIT

        echo "Extracting archive..."
        if ! unzip -q "$ZIP_FILE" -d "$STAGING_DIR"; then
            echo "ERROR: ZIP extraction failed."
            exit 1
        fi

        # If the ZIP contains a single top-level folder named
        # SUBJECT-C01, move that folder into the desired location.
        # Otherwise, preserve all extracted contents inside it.
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

        trap - EXIT
        EXTRACTED_BY_SCRIPT=1

        INPUT_DIR="$UNZIP_DIR"

    else

        echo "No ZIP archive found."

        # Prefer an existing subject-specific unzipped folder.
        if [[ -d "$SUBJECT_DATA_DIR/$SUBJECT_UPPER" ]]; then
            INPUT_DIR="$SUBJECT_DATA_DIR/$SUBJECT_UPPER"

        elif [[ -d "$SUBJECT_DATA_DIR" ]]; then
            # Otherwise use the subject's data directory itself.
            INPUT_DIR="$SUBJECT_DATA_DIR"

        else
            echo "ERROR: No ZIP or unzipped input found for $SUBJECT_ID"
            exit 1
        fi

        echo "Using existing, unzipped input: $INPUT_DIR"
        echo "Original input will not be deleted."
    fi

    # ----------------------------------------------
    # Convert DICOM to NIfTI
    # ----------------------------------------------
    echo "Running dcm2niix..."
    echo "Input:  $INPUT_DIR"
    echo "Output: $NIFTI_DIR"

    "$DCM2NIIX" \
        -z y \
        -d 9 \
        -w 0 \
        -o "$NIFTI_DIR" \
        "$INPUT_DIR"

    # ----------------------------------------------
    # Verify that NIfTI files exist
    # ----------------------------------------------
    if ! find "$NIFTI_DIR" -maxdepth 1 -type f \
        \( -name '*.nii.gz' -o -name '*.nii' \) \
        -print -quit | grep -q .; then

        echo "ERROR: No NIfTI files found in $NIFTI_DIR"
        echo "Keeping the input data for inspection."
        exit 1
    fi

    echo "NIfTI output files:"
    find "$NIFTI_DIR" -maxdepth 1 -type f \
        \( -name '*.nii.gz' -o -name '*.nii' \) -print

    # ----------------------------------------------
    # Delete only data extracted by this script
    # ----------------------------------------------
    if (( EXTRACTED_BY_SCRIPT == 1 )); then
        echo "Conversion completed. Removing extracted DICOM folder:"
        echo "$UNZIP_DIR"

        rm -rf -- "$UNZIP_DIR"
    fi

    echo "Finished subject: $SUBJECT_ID at $(date)"

done

echo
echo "=========================================="
echo "All assigned subjects processed."
echo "End: $(date)"
echo "=========================================="
