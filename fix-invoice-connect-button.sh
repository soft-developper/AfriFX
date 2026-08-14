#!/usr/bin/env bash
# ============================================================
# fix-invoice-connect-button.sh
#
# BUG (from screenshot): the public invoice page shows "Connect your wallet to
# pay this invoice" as STATIC TEXT with nothing to click. A logged-out payer
# has no way to connect MetaMask and pay.
#
# ROOT CAUSE (verified in code, not guessed):
#   • InvoicePayInner uses wagmi's REAL useAccount + useWriteContract — the
#     self-custody EVM pay path is fully intact and correct.
#   • RainbowKit is wired app-wide (providers.tsx → RainbowKitProvider;
#     wagmiConfig via getDefaultConfig/getDefaultWallets), so the connect
#     modal WORKS — it was just never rendered on this page.
#   • When !isConnected the page rendered text only, no button. That's the
#     entire defect. Not an architecture problem, not the Circle migration.
#
# FIX: replace the dead "!isConnected" text block with the existing
#      <ConnectButton/> (RainbowKit useConnectModal) so the payer can connect
#      MetaMask / injected / WalletConnect and pay. Self-custody is the correct
#      model here — invoice payers are not platform users and shouldn't need a
#      Circle account.
#
# Run from repo root:  cd ~/AfriFX && bash fix-invoice-connect-button.sh
# ============================================================
set -euo pipefail

ROOT="$(pwd)"
WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root (afrifx-web/ not found)"; exit 1; }
cd "$WEB"

INNER="components/invoice/InvoicePayInner.tsx"
[ -f "$INNER" ] || { echo "ERROR: $INNER not found — run feat-public-invoice-qr.sh first."; exit 1; }

# ---- guard: already applied? --------------------------------
if grep -q "ConnectButton" "$INNER"; then
  echo "• InvoicePayInner already renders ConnectButton — nothing to do."
  exit 0
fi

echo "→ 1/2  Importing ConnectButton into InvoicePayInner…"
# add the import right after the Button import to keep imports grouped
perl -0pi -e "s/(import \{ Button \} from '\@\/components\/ui\/button'\n)/\$1import { ConnectButton } from '\@\/components\/wallet\/ConnectButton'\n/s" "$INNER"
grep -q "import { ConnectButton }" "$INNER" && echo "  ✓ import added" || { echo "  ✗ import anchor not found"; exit 1; }

echo "→ 2/2  Replacing the dead '!isConnected' text block with a real connect button…"
# Use a Perl block match anchored on the exact JSX we verified.
perl -0pi -e '
s{
  \)\ :\ !isConnected\ \?\ \(\s*
  <div\ className="rounded-xl\ bg-app-bg\ p-4\ text-center\ text-sm\ text-app-muted">\s*
  <Wallet\ className="mx-auto\ mb-2\ h-6\ w-6"\ />\s*
  Connect\ your\ wallet\ to\ pay\ this\ invoice\s*
  </div>
}{) : !isConnected ? (
          <div className="rounded-xl bg-app-bg p-4 text-center">
            <Wallet className="mx-auto mb-2 h-6 w-6 text-app-muted" />
            <p className="mb-3 text-sm text-app-muted">
              Connect your wallet to pay this invoice
            </p>
            <div className="flex justify-center">
              <ConnectButton label="Connect wallet to pay" />
            </div>
            <p className="mt-2 text-[10px] text-app-muted">
              MetaMask, WalletConnect or any injected wallet holding USDC on Arc. No account needed.
            </p>
          </div>}sx;
' "$INNER"

# verify the swap landed
if grep -q 'ConnectButton label="Connect wallet to pay"' "$INNER"; then
  echo "  ✓ connect button rendered in the !isConnected branch"
else
  echo "  ✗ replacement did not match — the JSX text may differ. No changes committed to that block."
  echo "    Inspect around the '!isConnected ?' branch in $INNER and adjust manually."
  exit 1
fi

echo
echo "──────────────────────────────────────────────"
echo "Done. Changed: $INNER"
echo "  • imported ConnectButton (RainbowKit useConnectModal — already provided app-wide)"
echo "  • !isConnected branch now shows a working Connect button (MetaMask/injected/WalletConnect)"
echo
echo "Why this is safe: the pay logic (useWriteContract, memo/transfer, receipt"
echo "write-back) is untouched. Once connected, isConnected flips true and the"
echo "existing Pay button path runs exactly as before."
echo
echo "Next (your standard flow):"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # test logged-OUT: open /pay/<ref> in a private window → Connect wallet to pay → MetaMask → pay"
echo "  git add -A && git commit -m 'fix(invoice): render Connect button on public pay page so payers can connect a wallet' && git push"#!/usr/bin/env bash
# ============================================================
# fix-invoice-connect-button.sh
#
# BUG (from screenshot): the public invoice page shows "Connect your wallet to
# pay this invoice" as STATIC TEXT with nothing to click. A logged-out payer
# has no way to connect MetaMask and pay.
#
# ROOT CAUSE (verified in code, not guessed):
#   • InvoicePayInner uses wagmi's REAL useAccount + useWriteContract — the
#     self-custody EVM pay path is fully intact and correct.
#   • RainbowKit is wired app-wide (providers.tsx → RainbowKitProvider;
#     wagmiConfig via getDefaultConfig/getDefaultWallets), so the connect
#     modal WORKS — it was just never rendered on this page.
#   • When !isConnected the page rendered text only, no button. That's the
#     entire defect. Not an architecture problem, not the Circle migration.
#
# FIX: replace the dead "!isConnected" text block with the existing
#      <ConnectButton/> (RainbowKit useConnectModal) so the payer can connect
#      MetaMask / injected / WalletConnect and pay. Self-custody is the correct
#      model here — invoice payers are not platform users and shouldn't need a
#      Circle account.
#
# Run from repo root:  cd ~/AfriFX && bash fix-invoice-connect-button.sh
# ============================================================
set -euo pipefail

ROOT="$(pwd)"
WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root (afrifx-web/ not found)"; exit 1; }
cd "$WEB"

INNER="components/invoice/InvoicePayInner.tsx"
[ -f "$INNER" ] || { echo "ERROR: $INNER not found — run feat-public-invoice-qr.sh first."; exit 1; }

# ---- guard: already applied? --------------------------------
if grep -q "ConnectButton" "$INNER"; then
  echo "• InvoicePayInner already renders ConnectButton — nothing to do."
  exit 0
fi

echo "→ 1/2  Importing ConnectButton into InvoicePayInner…"
# add the import right after the Button import to keep imports grouped
perl -0pi -e "s/(import \{ Button \} from '\@\/components\/ui\/button'\n)/\$1import { ConnectButton } from '\@\/components\/wallet\/ConnectButton'\n/s" "$INNER"
grep -q "import { ConnectButton }" "$INNER" && echo "  ✓ import added" || { echo "  ✗ import anchor not found"; exit 1; }

echo "→ 2/2  Replacing the dead '!isConnected' text block with a real connect button…"
# Use a Perl block match anchored on the exact JSX we verified.
perl -0pi -e '
s{
  \)\ :\ !isConnected\ \?\ \(\s*
  <div\ className="rounded-xl\ bg-app-bg\ p-4\ text-center\ text-sm\ text-app-muted">\s*
  <Wallet\ className="mx-auto\ mb-2\ h-6\ w-6"\ />\s*
  Connect\ your\ wallet\ to\ pay\ this\ invoice\s*
  </div>
}{) : !isConnected ? (
          <div className="rounded-xl bg-app-bg p-4 text-center">
            <Wallet className="mx-auto mb-2 h-6 w-6 text-app-muted" />
            <p className="mb-3 text-sm text-app-muted">
              Connect your wallet to pay this invoice
            </p>
            <div className="flex justify-center">
              <ConnectButton label="Connect wallet to pay" />
            </div>
            <p className="mt-2 text-[10px] text-app-muted">
              MetaMask, WalletConnect or any injected wallet holding USDC on Arc. No account needed.
            </p>
          </div>}sx;
' "$INNER"

# verify the swap landed
if grep -q 'ConnectButton label="Connect wallet to pay"' "$INNER"; then
  echo "  ✓ connect button rendered in the !isConnected branch"
else
  echo "  ✗ replacement did not match — the JSX text may differ. No changes committed to that block."
  echo "    Inspect around the '!isConnected ?' branch in $INNER and adjust manually."
  exit 1
fi

echo
echo "──────────────────────────────────────────────"
echo "Done. Changed: $INNER"
echo "  • imported ConnectButton (RainbowKit useConnectModal — already provided app-wide)"
echo "  • !isConnected branch now shows a working Connect button (MetaMask/injected/WalletConnect)"
echo
echo "Why this is safe: the pay logic (useWriteContract, memo/transfer, receipt"
echo "write-back) is untouched. Once connected, isConnected flips true and the"
echo "existing Pay button path runs exactly as before."
echo
echo "Next (your standard flow):"
echo "  cd afrifx-web && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # test logged-OUT: open /pay/<ref> in a private window → Connect wallet to pay → MetaMask → pay"
echo "  git add -A && git commit -m 'fix(invoice): render Connect button on public pay page so payers can connect a wallet' && git push"
