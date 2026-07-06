#!/bin/bash
# ============================================================
# AfriFX -- Branded favicon + social (OG) share image
#
# Replaces the old blue favicon (a leftover from before the gold rebrand)
# with the AfriFX hexagon mark in brand gold, and adds a 1200x630 OG image
# so shared links show a branded preview instead of a generic card. Also
# wires up OpenGraph + Twitter metadata in the root layout.
#
# Delivered as a checksummed tarball because it contains a binary PNG
# (heredoc scripts corrupt binaries). Run from ~/AfriFX with favicon-og.tar.gz
# in the same folder:
#     bash favicon-og-recover.sh
# ============================================================
set -e
EXPECTED="b4167f67ef50a41d0849c2fcddb6d347a28431647e8f655fd98af9f68b659a73"
if [ ! -f favicon-og.tar.gz ]; then echo "ERROR: favicon-og.tar.gz not found in $(pwd)"; exit 1; fi
ACTUAL=$(sha256sum favicon-og.tar.gz | cut -d' ' -f1)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "ERROR: checksum mismatch (download corrupted)."
  echo "  expected: $EXPECTED"
  echo "  actual:   $ACTUAL"
  exit 1
fi
echo "Checksum OK. Extracting..."
tar -xzf favicon-og.tar.gz
echo ""
echo "Applied:"
echo "  afrifx-web/public/favicon.svg        (gold hexagon mark)"
echo "  afrifx-web/public/brand/og-image.png (1200x630 social image)"
echo "  afrifx-web/app/layout.tsx            (OG + Twitter metadata)"
echo ""
echo "Now:  cd afrifx-web && npm run build"
echo "      git add -A && git commit -m 'Brand: gold favicon + OG social image'"
echo "      git push"
echo ""
echo "Tip: after deploy, test the link preview with"
echo "     https://www.opengraph.xyz  (paste your afrifx.xyz URL)."
