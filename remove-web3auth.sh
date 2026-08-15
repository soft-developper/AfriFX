#!/usr/bin/env bash
# ============================================================
# remove-web3auth.sh — remove the dead Web3Auth social-login layer
#
# Web3Auth was the OLD social login (Google/email → embedded wallet), superseded
# by Circle wallets. It's unused but still instantiated, which emits the console
# warning: "You are on sapphire_devnet. Please set network: 'mainnet'...".
#
# This removes it cleanly. WalletConnect + injected wallets (MetaMask) STAY —
# external payers still connect their own wallet on the public invoice pay page.
#
# Changes:
#   1. lib/wagmi.ts — drop the web3auth import; wallets = RainbowKit defaults.
#   2. delete lib/web3auth.ts (kills the sapphire_devnet warning at its source).
#   3. remove the 6 @web3auth/* packages from package.json.
#
# Idempotent. Run from repo root:  cd ~/AfriFX && bash remove-web3auth.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/nexum-web"; [ -d "$WEB" ] || WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from repo root"; exit 1; }
cd "$WEB"

WAGMI="lib/wagmi.ts"
W3A="lib/web3auth.ts"
[ -f "$WAGMI" ] || { echo "ERROR: $WAGMI not found"; exit 1; }

echo "→ 1/3  Editing wagmi.ts (drop web3auth import + simplify wallet list)…"
if ! grep -q "web3auth" "$WAGMI"; then
  echo "  • wagmi.ts already clean (skip)"
else
  # remove the import line
  perl -0pi -e "s{import \{ web3AuthWallet, hasWeb3Auth \} from '\./web3auth'\n}{}" "$WAGMI"
  # replace the conditional wallets block with plain defaults
  perl -0pi -e "s{// Add Web3Auth social login.*?const wallets = hasWeb3Auth\n  \? \[\n      \{ groupName: 'Social login', wallets: \[web3AuthWallet\] \},\n      \.\.\.defaultWallets,\n    \]\n  : defaultWallets}{// Wallet options: RainbowKit defaults (MetaMask, WalletConnect, injected).\n// Web3Auth social login was removed - users get wallets via Circle now;\n// external payers still connect their own wallet here.\nconst wallets = defaultWallets}s" "$WAGMI"
  if grep -q "web3auth" "$WAGMI"; then echo "  ✗ wagmi.ts still references web3auth — review"; exit 1; fi
  grep -q "const wallets = defaultWallets" "$WAGMI" && echo "  ✓ wagmi.ts cleaned" || { echo "  ✗ wallets block not simplified"; exit 1; }
fi

echo "→ 2/3  Deleting lib/web3auth.ts…"
if [ -f "$W3A" ]; then
  if [ -d "$ROOT/.git" ]; then git rm -q "$W3A" 2>/dev/null || rm -f "$W3A"; else rm -f "$W3A"; fi
  echo "  ✓ removed $W3A (sapphire_devnet warning gone)"
else
  echo "  • already deleted (skip)"
fi

echo "→ 3/3  Removing @web3auth/* from package.json…"
if grep -q "@web3auth/" package.json; then
  perl -0pi -e "s/^\s*\"\@web3auth\/[^\"]+\":\s*\"[^\"]+\",?\n//mg" package.json
  # guard against a trailing comma left dangling before a } — normalize
  perl -0pi -e "s/,(\s*\n\s*})/\$1/g" package.json
  echo "  ✓ @web3auth/* deps removed from package.json"
  echo "  ⚠ run 'npm install' to update package-lock.json before building"
else
  echo "  • no @web3auth deps present (skip)"
fi

echo
echo "→ Verify: no web3auth references remain in source:"
grep -rn "web3auth\|Web3Auth\|sapphire" --include=*.ts --include=*.tsx lib app components hooks 2>/dev/null | grep -vE "node_modules|\.next" || echo "  ✓ none"

echo
echo "Done. Next:"
echo "  cd $(basename "$WEB") && npm install   # refresh lockfile (deps removed)"
echo "  rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'chore(wallet): remove dead Web3Auth social login (kills sapphire_devnet warning)' && git push"
echo
echo "SEPARATE (dashboard, for the OTHER console error): add https://nexumpay.xyz"
echo "  to your Reown/WalletConnect project allowlist at cloud.reown.com so"
echo "  WalletConnect QR connections work on the new domain."
