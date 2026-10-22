
import nibabel as nib
from pathlib import Path

source = Path("test.nii.gz")
destination = Path("test.mnc")

img = nib.load(str(source))
nib.save(img, str(destination))

print(f"Saved: {destination}")
print(f"Shape: {img.shape}")
print(f"Affine:\n{img.affine}")

# Verify the output can be reopened
check = nib.load(str(destination))
print(f"Output shape: {check.shape}")
print(f"Output format: {type(check).__name__}")
