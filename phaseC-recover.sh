#!/bin/bash
# ============================================================
# AfriFX -- Phase C recovery (safe extract, no giant paste)
#
# The big paste-in script got corrupted in transfer. This instead
# extracts the 53 correct files from phaseC-files.tar.gz, which is a
# binary download and cannot be mangled by copy/paste.
#
# USAGE:
#   1. Download phaseC-files.tar.gz into ~/AfriFX (same folder as this)
#   2. cd ~/AfriFX
#   3. bash phaseC-recover.sh
# ============================================================
set -e

EXPECTED_SHA="300c2f96c77a0fe923f8ea303106320ee0ea95ad2e13461051c504d806bd4601"

if [ ! -f phaseC-files.tar.gz ]; then
  echo "ERROR: phaseC-files.tar.gz not found in $(pwd)"
  echo "Download it into ~/AfriFX first, then re-run."
  exit 1
fi

# Integrity check — refuse to extract a truncated/corrupt download
ACTUAL_SHA=$(sha256sum phaseC-files.tar.gz | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "ERROR: checksum mismatch -- the download is incomplete or corrupt."
  echo "  expected: $EXPECTED_SHA"
  echo "  got:      $ACTUAL_SHA"
  echo "Re-download phaseC-files.tar.gz and try again."
  exit 1
fi
echo "Checksum OK -- extracting 53 files..."

tar xzf phaseC-files.tar.gz
echo ""
echo "Done. Now:"
echo "  cd afrifx-web && npm run build"
echo "  # if the build is clean:"
echo "  git add -A && git commit -m 'Phase C: fix corrupted transfer -- restore correct files'"
echo "  git push"
