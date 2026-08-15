#!/usr/bin/env bash
# ============================================================
# fix-send-history-recording.sh
#
# BUG: /history has recorded nothing for SENDS since the Circle migration.
# ROOT CAUSE (verified): the Send page calls sendUsdc() (Circle transfer) but
# never POSTs to /transactions. Convert/swap still record (useSwap/useCorridorSwap
# kept their POST); Send lost it when it was rewired to Circle. History reads
# GET /transactions?wallet=<address> and finds no send rows → appears empty.
# It's NOT a connection issue — it's a missing write.
#
# FIX: after a successful sendUsdc(), record the transfer to /transactions
# (matching useSwap's schema), then PATCH status once confirmed on-chain.
# A send is a same-asset USDC→USDC movement on Arc.
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash fix-send-history-recording.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/nexum-web"
[ -d "$WEB" ] || WEB="$ROOT/afrifx-web"   # tolerate pre/post dir-rename
[ -d "$WEB" ] || { echo "ERROR: web dir not found (run from repo root)"; exit 1; }
SEND="$WEB/app/(app)/send/page.tsx"
[ -f "$SEND" ] || { echo "ERROR: $SEND not found"; exit 1; }

if grep -q "/transactions" "$SEND"; then
  echo "• Send already records to /transactions (skip)"
  exit 0
fi

echo "→ 1/2  Add API base constant to the send page…"
# Insert after the last import line (the lucide-react import we saw at line ~13).
perl -0pi -e "s{(import \{ AlertCircle, CheckCircle, Loader2, Zap \} from 'lucide-react'\n)}{\$1\nconst API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'\n}s" "$SEND"
grep -q "const API = process.env.NEXT_PUBLIC_API_URL" "$SEND" && echo "  ✓ API const added" || { echo "  ✗ import anchor not matched"; exit 1; }

echo "→ 2/2  Record the send to /transactions after success…"
# Insert recording right after `setTxHash(result.txHash ...)` inside the
# `if (result.txHash) {` branch, and also record when hash is absent (pending).
perl -0pi -e "s{(      if \(result\.txHash\) \{\n        setTxHash\(result\.txHash as \`0x\\\$\{string\}\`\)\n)}{\$1        // Record this send so it appears in History (GET /transactions?wallet=).\n        // Same-asset USDC→USDC movement on Arc.\n        if (address) {\n          const hash = result.txHash as \`0x\\\${string}\`\n          fetch(\`\\\${API}/transactions\`, {\n            method: 'POST',\n            headers: { 'Content-Type': 'application/json' },\n            body: JSON.stringify({\n              walletAddress: address,\n              fromCurrency: 'USDC', toCurrency: 'USDC',\n              fromAmount: Number(amount), toAmount: Number(amount),\n              arcTxHash: hash,\n            }),\n          }).catch(() => {})\n          // Confirm on-chain, then mark settled/failed.\n          if (publicClient) {\n            publicClient.waitForTransactionReceipt({ hash }).then(r => {\n              const ok = r.status === 'success'\n              fetch(\`\\\${API}/transactions/\\\${hash}\`, {\n                method: 'PATCH',\n                headers: { 'Content-Type': 'application/json' },\n                body: JSON.stringify({ status: ok ? 'settled' : 'failed' }),\n              }).catch(() => {})\n            }).catch(() => {})\n          }\n        }\n}s" "$SEND"

if grep -q "Record this send so it appears in History" "$SEND"; then
  echo "  ✓ send now records to /transactions"
else echo "  ✗ success-branch anchor not matched — review $SEND"; exit 1; fi

# We referenced publicClient — ensure it's available (add usePublicClient if missing).
if ! grep -q "usePublicClient" "$SEND"; then
  perl -0pi -e "s/import \{ useWaitForTransactionReceipt \} from 'wagmi'/import { useWaitForTransactionReceipt, usePublicClient } from 'wagmi'/" "$SEND"
  # add the hook call near the other hooks (after useAccount line)
  perl -0pi -e "s/(const \{ address, isConnected \}  = useAccount\(\)\n)/\$1  const publicClient              = usePublicClient()\n/" "$SEND"
  echo "  ✓ added usePublicClient for confirmation"
fi

echo
echo "→ Verify:"
grep -n "const API =\|/transactions\|usePublicClient" "$SEND" | head

echo
echo "Done. Sends will now appear in History. Next:"
echo "  cd $(basename "$WEB") && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # test: make a small send, then open /history — it should list it"
echo "  git add -A && git commit -m 'fix(history): record Circle-wallet sends to /transactions' && git push"
echo
echo "NOTE: P2P and invoice payments may have the same missing-record gap — check"
echo "  /history after testing a send; if those are also absent we fix them next."
