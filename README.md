# dcm2niigz2mnc

# Steps to Run the Pipeline

## Software Setup

To begin, please log onto Sockeye (https://ondemand.arc.ubc.ca/pun/sys/dashboard/) and open the Terminal window.

In the Terminal window above, please run the following code:

```sh
SCRATCH_DIR="/scratch/st-toddwood-1/$USER"

mkdir -p "$SCRATCH_DIR"

cd "$SCRATCH_DIR"

git clone -b dcm2niigz2mnc_Version-1.00 --single-branch https://github.com/jshahki/dcm2niigz2mnc.git

cd /scratch/st-toddwood-1/$USER/dcm2niigz2mnc

source ./code/dcm2niigz2mnc_setup.sh
```

Please ensure to keep the Terminal window open while this process completes.

## Unzipping Each Subject's Data Folder

```sh
cd /scratch/st-toddwood-1/$USER/dcm2niigz2mnc
git pull

PARTICIPANTS_FILE="./data/participants.tsv"
SUB_SIZE=1  # Subjects per job

# Read subject IDs from file (ignore header)
mapfile -t SUBJECTS < <(tail -n +2 "$PARTICIPANTS_FILE" | cut -f1 | tr -d '\r' | sed '/^$/d')

N_SUBJECTS=${#SUBJECTS[@]}
ARRAY_LENGTH=$(( (N_SUBJECTS + SUB_SIZE - 1) / SUB_SIZE ))

echo "Found $N_SUBJECTS subjects. Launching array with $ARRAY_LENGTH jobs."

sbatch --array=0-$((ARRAY_LENGTH - 1)) ./code/unzip_raw_data.sh
```

## Convert DICOM Files to NIfTI

```sh
cd /scratch/st-toddwood-1/$USER/dcm2niigz2mnc
git pull

PARTICIPANTS_FILE="./data/participants.tsv"
SUB_SIZE=1  # Subjects per job

# Read subject IDs from file (ignore header)
mapfile -t SUBJECTS < <(tail -n +2 "$PARTICIPANTS_FILE" | cut -f1 | tr -d '\r' | sed '/^$/d')

N_SUBJECTS=${#SUBJECTS[@]}
ARRAY_LENGTH=$(( (N_SUBJECTS + SUB_SIZE - 1) / SUB_SIZE ))

echo "Found $N_SUBJECTS subjects. Launching array with $ARRAY_LENGTH jobs."

sbatch --array=0-$((ARRAY_LENGTH - 1)) ./code/dcm2niigz.sh
```

## Convert NIfTI Files to MINC

```sh
cd /scratch/st-toddwood-1/$USER/dcm2niigz2mnc
git pull

PARTICIPANTS_FILE="./data/participants.tsv"
SUB_SIZE=1  # Subjects per job

# Read subject IDs from file (ignore header)
mapfile -t SUBJECTS < <(tail -n +2 "$PARTICIPANTS_FILE" | cut -f1 | tr -d '\r' | sed '/^$/d')

N_SUBJECTS=${#SUBJECTS[@]}
ARRAY_LENGTH=$(( (N_SUBJECTS + SUB_SIZE - 1) / SUB_SIZE ))

echo "Found $N_SUBJECTS subjects. Launching array with $ARRAY_LENGTH jobs."

sbatch --array=0-$((ARRAY_LENGTH - 1)) ./code/niigz2mnc.sh
```
