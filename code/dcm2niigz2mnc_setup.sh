
#!/bin/bash

set -euo pipefail

# ----------------------------
# Paths
# ----------------------------
SCRATCH_DIR="/scratch/st-toddwood-1/$USER"
REPO_DIR="$SCRATCH_DIR/dcm2niigz2mnc"

TOOLS_DIR="$REPO_DIR/tools"
LOG_DIR="$REPO_DIR/logs"
DERIVATIVES_DIR="$REPO_DIR/derivatives"
CACHE_DIR="$REPO_DIR/cache"

# ----------------------------
# Create directories
# ----------------------------
mkdir -p \
    "$TOOLS_DIR" \
    "$LOG_DIR" \
    "$DERIVATIVES_DIR" \
    "$CACHE_DIR"

LOG_FILE="$LOG_DIR/setup_login_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================"
echo "fMRI SETUP (LOGIN NODE)"
echo "User: $USER"
echo "Host: $(hostname)"
echo "Start: $(date)"
echo "======================================"

# ----------------------------
# Check dependencies
# ----------------------------
for cmd in curl unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

# ----------------------------
# Download dcm2niix
# ----------------------------
cd "$TOOLS_DIR"

ARCHIVE="$TOOLS_DIR/dcm2niix_lnx.zip"
DOWNLOAD_URL="https://github.com/rordenlab/dcm2niix/releases/latest/download/dcm2niix_lnx.zip"

echo "Downloading dcm2niix..."

curl -fL --retry 3 "$DOWNLOAD_URL" -o "$ARCHIVE"

echo "Extracting dcm2niix..."
unzip -o "$ARCHIVE" -d "$TOOLS_DIR"

# ----------------------------
# Verify installation
# ----------------------------
if [[ ! -f "$TOOLS_DIR/dcm2niix" ]]; then
    echo "ERROR: dcm2niix executable was not found after extraction."
    echo "Inspect the ZIP contents to determine the executable path."
    exit 1
fi

chmod +x "$TOOLS_DIR/dcm2niix"

echo "Checking dcm2niix..."
"$TOOLS_DIR/dcm2niix" -h

echo "======================================"
echo "Setup completed: $(date)"
echo "Executable: $TOOLS_DIR/dcm2niix"
echo "======================================"
