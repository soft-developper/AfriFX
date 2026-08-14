#!/usr/bin/env bash
# Fix TS2322: Button has no "secondary" variant. Valid: default|outline|ghost|danger|success.
# Use "outline" for the Circle pay button (distinct from the primary Connect action).
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
INNER="$WEB/components/invoice/InvoicePayInner.tsx"
[ -f "$INNER" ] || { echo "ERROR: $INNER not found"; exit 1; }

if grep -q 'variant="secondary" className="w-full" onClick={handlePayWithCircle}' "$INNER"; then
  perl -0pi -e 's/<Button variant="secondary" className="w-full" onClick=\{handlePayWithCircle\}>/<Button variant="outline" className="w-full" onClick={handlePayWithCircle}>/s' "$INNER"
  echo "✓ Circle pay button variant: secondary → outline"
elif grep -q 'variant="outline" className="w-full" onClick={handlePayWithCircle}' "$INNER"; then
  echo "• already outline (skip)"
else
  echo "✗ target button not found — check $INNER manually"; exit 1
fi
