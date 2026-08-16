#!/usr/bin/env bash
# ============================================================
# 4-fix-bridge-chain-provisioning.sh   (run once, then deploy api)
#
# BUG: Bridging Arc -> OP failed at the MINT stage with
#   "Your wallet isn't set up on OP-SEPOLIA yet."
#
# CAUSE: A 4th sync point missed when the chains were added. The backend
# provisions Circle wallets on a FIXED list, CCTP_BRIDGE_CHAINS, which still
# defaulted to only the original four:
#     BASE-SEPOLIA,ETH-SEPOLIA,ARB-SEPOLIA,MATIC-AMOY
# So missingBridgeChains() never flags the new chains, addUserWalletChains()
# never creates wallets there, and getWalletIdForChain() throws NEEDS_CHAIN at
# mint time. (The burn on Arc succeeded — those funds are in-flight, not lost;
# after this deploys, finish the pending mint from "Recent bridges".)
#
# NOT related to NEXT_PUBLIC_*_RPC_URL — those only affect frontend RPC reads
# (balances/receipts), never wallet provisioning.
#
# FIX: add OP-SEPOLIA, AVAX-FUJI, UNI-SEPOLIA, MONAD-TESTNET to the default
# list (all support SCA per Circle Wallets docs). Also add the mainnet-code
# counterparts to the accompanying comment set is unnecessary; the mainnet
# override path already uses CIRCLE_BRIDGE_CHAINS env when you go to mainnet.
# ============================================================
set -euo pipefail

if [ -d "nexum-api" ]; then API="nexum-api"
elif [ -d "$HOME/AfriFX/nexum-api" ]; then API="$HOME/AfriFX/nexum-api"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

WALLETS="$API/src/services/circleWallets.ts"
[ -f "$WALLETS" ] || { echo "ERROR: $WALLETS not found"; exit 1; }

PL="$(mktemp /tmp/prov.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

my $old = "  (process.env.CIRCLE_BRIDGE_CHAINS ?? 'BASE-SEPOLIA,ETH-SEPOLIA,ARB-SEPOLIA,MATIC-AMOY')";
my $new = "  (process.env.CIRCLE_BRIDGE_CHAINS ?? 'BASE-SEPOLIA,ETH-SEPOLIA,ARB-SEPOLIA,MATIC-AMOY,OP-SEPOLIA,AVAX-FUJI,UNI-SEPOLIA,MONAD-TESTNET')";
my $c = () = $s =~ /\Q$old\E/g;
die "CCTP_BRIDGE_CHAINS anchor: expected 1, found $c\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "circleWallets.ts: CCTP_BRIDGE_CHAINS default now includes the 4 new chains.\n";
PERL
perl "$PL" "$WALLETS"; rm -f "$PL"

echo
echo "Verify:"
grep -n "OP-SEPOLIA,AVAX-FUJI,UNI-SEPOLIA,MONAD-TESTNET" "$WALLETS" | sed 's/^/  /'
echo
echo "Deploy (API only):"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'fix(bridge): provision Circle wallets on new CCTP chains (NEEDS_CHAIN at mint)' && git push"
echo
echo "AFTER deploy:"
echo "  1. Reload the app so the wallet picks up the add-chains flow."
echo "  2. Your pending Arc->OP transfer: open Recent bridges and use"
echo "     'Complete transfer' — the burn already succeeded, only the mint is owed."
echo "     The first action will trigger one wallet-approval to enable OP-SEPOLIA,"
echo "     then the mint proceeds. Funds were never at risk."
