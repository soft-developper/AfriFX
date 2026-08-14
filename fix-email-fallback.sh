#!/usr/bin/env bash
# Update the EMAIL_FROM fallback default from the now-DELETED afrifx.xyz sender
# to the verified Nexum subdomain. The env EMAIL_FROM still wins; this only fixes
# the dormant fallback so an unset env can't silently send from a rejected domain.
set -euo pipefail
ROOT="$(pwd)"; API="$ROOT/afrifx-api"
[ -d "$API" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
CLIENT="$API/src/services/email/client.ts"
[ -f "$CLIENT" ] || { echo "ERROR: $CLIENT not found"; exit 1; }

if grep -q "notifications@send.nexumpay.xyz" "$CLIENT"; then
  echo "• fallback already updated (skip)"
elif grep -q "'AfriFX <notifications@afrifx.xyz>'" "$CLIENT"; then
  perl -0pi -e "s/'AfriFX <notifications\@afrifx\.xyz>'/'Nexum <notifications\@send.nexumpay.xyz>'/" "$CLIENT"
  grep -q "Nexum <notifications@send.nexumpay.xyz>" "$CLIENT" && echo "✓ fallback → Nexum <notifications@send.nexumpay.xyz>" || { echo "✗ replace failed"; exit 1; }
else
  echo "⚠ fallback string not in expected form — check $CLIENT manually:"; grep -n "FROM_EMAIL" "$CLIENT"; exit 1
fi
