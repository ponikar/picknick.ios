#!/usr/bin/env bash
# Copies the MobileCLIP models, BPE merges and GeoNames gazetteer into ios/assets (gitignored).
# The Xcode project bundles ios/assets/*; Xcode compiles each .mlpackage into a .mlmodelc.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
data="${PICKNICK_DATA:?Set PICKNICK_DATA to a folder with models/ and gazetteer/}"
dest="$here/ios/assets"

mkdir -p "$dest"
for item in models/mobileclip_s2_image.mlpackage models/mobileclip_s2_text.mlpackage models/bpe_merges.txt \
  gazetteer/cities15000.txt gazetteer/countryInfo.txt gazetteer/admin1CodesASCII.txt; do
  rsync -a --delete "$data/$item" "$dest/"
done
echo "Copied assets to $dest"
