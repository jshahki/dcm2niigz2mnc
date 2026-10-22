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

## Unzipping Each Subject Folder

