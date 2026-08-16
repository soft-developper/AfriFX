#!/usr/bin/env bash
# ============================================================
# 1-add-cctp-chains.sh   (run once, then deploy web + api)
#
# Adds 4 new CCTP chains to the bridge, reusing the EXISTING architecture
# (registry-driven, no execution-logic changes). Every value below is taken
# from Circle's official docs, cross-verified across three Circle sources:
#   - Supported chains & domains  (CCTP domain numbers)
#   - USDC contract addresses     (testnet USDC per chain)
#   - Wallets supported blockchains (SCA + contract-execution capable)
#
# WHY ONLY THESE 4 (not the full CCTP list):
#   Users bridge via Circle user-controlled SCA wallets, and the burn/mint
#   legs are CONTRACT EXECUTION calls. A chain only works if Circle Wallets
#   supports SCA + contract execution on it. Per Circle's Wallets docs, the
#   testnets meeting that bar (beyond the 5 we already have) are exactly:
#     Optimism, Avalanche, Unichain, Monad.
#   Chains like Linea/Sonic/World/Sei/Ink/Plume are CCTP domains but are
#   "Other EVM" = SIGNING ONLY in Circle Wallets (no contract execution),
#   so depositForBurn can't be executed from a user's SCA there. Shipping
#   them would strand funds. Skipped, per the "only reachable chains" rule.
#
# VERIFIED VALUES (Circle docs):
#   optimism : domain 2  chainId 11155420 OP-SEPOLIA
#              USDC 0x5fd84259d66Cd46123540766Be93DFE6D43130D7
#   avalanche: domain 1  chainId 43113    AVAX-FUJI
#              USDC 0x5425890298aed601595a70AB815c96711a31Bc65
#   unichain : domain 10 chainId 1301     UNI-SEPOLIA
#              USDC 0x31d0220469e10c4E71834a79b1f276d740d3768F
#   monad    : domain 15 chainId 10143    MONAD-TESTNET
#              USDC 0x534b2f3A21130d7a60830c2Df862319e593943A3
#
# TOUCHES 3 sync-critical files (all four chains added to each):
#   web  lib/cctp-chains.ts       - CCTP registry (domain, usdc, explorer)
#   web  lib/bridge-chains.ts     - wagmi/viem chains (chainId, rpc) + evmChainId
#   api  services/circleWallets.ts- cctpBlockchainFor (Circle blockchain code)
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ] && [ -d "nexum-api" ]; then ROOT="."
elif [ -d "$HOME/AfriFX/nexum-web" ]; then ROOT="$HOME/AfriFX"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

WEB="$ROOT/nexum-web"; API="$ROOT/nexum-api"
CCTP="$WEB/lib/cctp-chains.ts"
BRIDGE="$WEB/lib/bridge-chains.ts"
WALLETS="$API/src/services/circleWallets.ts"
for f in "$CCTP" "$BRIDGE" "$WALLETS"; do [ -f "$f" ] || { echo "ERROR: $f not found"; exit 1; }; done

# ---------- (1) cctp-chains.ts : append 4 chains to TESTNET_CHAINS ----------
PL1="$(mktemp /tmp/cctp.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# Insert new testnet entries right before the closing "]" of TESTNET_CHAINS.
# Anchor on the polygon amoy block's trailing "},\n]" that ends the testnet array.
my $anchor = "    usdc: process.env.NEXT_PUBLIC_ARC_USDC ?? '',\n    rpcUrl:  process.env.NEXT_PUBLIC_ARC_RPC_URL ?? '',\n    explorer: 'https://arcscan.app',\n    isHome: true,\n  },";
# ^ that's in MAINNET; we instead target the TESTNET closing. Find the testnet
# polygon entry uniquely by its Amoy USDC address then the array close.
my $tanchor = "    explorer: 'https://amoy.polygonscan.com',\n  },\n]";
my $c = () = $s =~ /\Q$tanchor\E/g;
die "testnet-close anchor: expected 1, found $c\n" unless $c==1;

my $add = "    explorer: 'https://amoy.polygonscan.com',\n  },\n"
  . "  {\n"
  . "    key: 'optimism', name: 'OP Sepolia', domain: 2, chainId: 11155420,\n"
  . "    usdc: '0x5fd84259d66Cd46123540766Be93DFE6D43130D7',\n"
  . "    rpcUrl:  process.env.NEXT_PUBLIC_OP_RPC_URL ?? 'https://sepolia.optimism.io',\n"
  . "    explorer: 'https://sepolia-optimism.etherscan.io',\n"
  . "  },\n"
  . "  {\n"
  . "    key: 'avalanche', name: 'Avalanche Fuji', domain: 1, chainId: 43113,\n"
  . "    usdc: '0x5425890298aed601595a70AB815c96711a31Bc65',\n"
  . "    rpcUrl:  process.env.NEXT_PUBLIC_AVAX_RPC_URL ?? 'https://api.avax-test.network/ext/bc/C/rpc',\n"
  . "    explorer: 'https://testnet.snowtrace.io',\n"
  . "  },\n"
  . "  {\n"
  . "    key: 'unichain', name: 'Unichain Sepolia', domain: 10, chainId: 1301,\n"
  . "    usdc: '0x31d0220469e10c4E71834a79b1f276d740d3768F',\n"
  . "    rpcUrl:  process.env.NEXT_PUBLIC_UNICHAIN_RPC_URL ?? 'https://sepolia.unichain.org',\n"
  . "    explorer: 'https://sepolia.uniscan.xyz',\n"
  . "  },\n"
  . "  {\n"
  . "    key: 'monad', name: 'Monad Testnet', domain: 15, chainId: 10143,\n"
  . "    usdc: '0x534b2f3A21130d7a60830c2Df862319e593943A3',\n"
  . "    rpcUrl:  process.env.NEXT_PUBLIC_MONAD_RPC_URL ?? 'https://testnet-rpc.monad.xyz',\n"
  . "    explorer: 'https://testnet.monadexplorer.com',\n"
  . "  },\n"
  . "]";
$s =~ s/\Q$tanchor\E/$add/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "cctp-chains.ts: +4 testnet chains.\n";
PERL
perl "$PL1" "$CCTP"; rm -f "$PL1"

# ---------- (2) bridge-chains.ts : viem chains + rpc + evmChainId ----------
PL2="$(mktemp /tmp/bridge.XXXXXX.pl)"
cat > "$PL2" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# 2a. import optimismSepolia + avalancheFuji from viem/chains (they're built-in);
#     define unichainSepolia + monadTestnet via defineChain.
my $imp_old = "import {\n  base, baseSepolia, mainnet, sepolia,\n  arbitrum, arbitrumSepolia, polygon, polygonAmoy,\n} from 'viem/chains'";
my $imp_new = "import {\n  base, baseSepolia, mainnet, sepolia,\n  arbitrum, arbitrumSepolia, polygon, polygonAmoy,\n  optimism, optimismSepolia, avalanche, avalancheFuji,\n} from 'viem/chains'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "viem import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# 2b. re-export block
my $rex_old = "export {\n  base, baseSepolia, mainnet, sepolia,\n  arbitrum, arbitrumSepolia, polygon, polygonAmoy,\n}";
my $rex_new = "export {\n  base, baseSepolia, mainnet, sepolia,\n  arbitrum, arbitrumSepolia, polygon, polygonAmoy,\n  optimism, optimismSepolia, avalanche, avalancheFuji,\n}";
$c = () = $s =~ /\Q$rex_old\E/g; die "re-export anchor: found $c\n" unless $c==1;
$s =~ s/\Q$rex_old\E/$rex_new/;

# 2c. defineChain for Unichain Sepolia + Monad testnet (viem may not ship these).
#     Insert right after the arcTestnet import line.
my $after = "import { arcTestnet } from './arc-chain'\nimport { CCTP_ENV } from './cctp-chains'";
my $defs = "import { arcTestnet } from './arc-chain'\n"
  . "import { CCTP_ENV } from './cctp-chains'\n\n"
  . "// Chains viem doesn't ship a built-in for — defined from verified network params.\n"
  . "export const unichainSepolia = defineChain({\n"
  . "  id: 1301, name: 'Unichain Sepolia',\n"
  . "  nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },\n"
  . "  rpcUrls: { default: { http: ['https://sepolia.unichain.org'] } },\n"
  . "  blockExplorers: { default: { name: 'Uniscan', url: 'https://sepolia.uniscan.xyz' } },\n"
  . "  testnet: true,\n"
  . "})\n\n"
  . "export const monadTestnet = defineChain({\n"
  . "  id: 10143, name: 'Monad Testnet',\n"
  . "  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },\n"
  . "  rpcUrls: { default: { http: ['https://testnet-rpc.monad.xyz'] } },\n"
  . "  blockExplorers: { default: { name: 'Monad Explorer', url: 'https://testnet.monadexplorer.com' } },\n"
  . "  testnet: true,\n"
  . "})";
$c = () = $s =~ /\Q$after\E/g; die "arc-import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$after\E/$defs/;

# 2d. add to TESTNET_CHAINS list
my $tc_old = "export const TESTNET_CHAINS = [\n  arcTestnet, baseSepolia, sepolia, arbitrumSepolia, polygonAmoy,\n] as const";
my $tc_new = "export const TESTNET_CHAINS = [\n  arcTestnet, baseSepolia, sepolia, arbitrumSepolia, polygonAmoy,\n  optimismSepolia, avalancheFuji, unichainSepolia, monadTestnet,\n] as const";
$c = () = $s =~ /\Q$tc_old\E/g; die "TESTNET_CHAINS anchor: found $c\n" unless $c==1;
$s =~ s/\Q$tc_old\E/$tc_new/;

# 2e. rpcUrlFor map — add testnet rpc entries (insert after polygonAmoy line)
my $rpc_anchor = "    [polygonAmoy.id]:     process.env.NEXT_PUBLIC_POLYGON_RPC_URL ?? 'https://polygon-amoy-bor-rpc.publicnode.com',";
my $rpc_add = $rpc_anchor . "\n"
  . "    [optimismSepolia.id]: process.env.NEXT_PUBLIC_OP_RPC_URL       ?? 'https://sepolia.optimism.io',\n"
  . "    [avalancheFuji.id]:   process.env.NEXT_PUBLIC_AVAX_RPC_URL     ?? 'https://api.avax-test.network/ext/bc/C/rpc',\n"
  . "    [unichainSepolia.id]: process.env.NEXT_PUBLIC_UNICHAIN_RPC_URL ?? 'https://sepolia.unichain.org',\n"
  . "    [monadTestnet.id]:    process.env.NEXT_PUBLIC_MONAD_RPC_URL    ?? 'https://testnet-rpc.monad.xyz',";
$c = () = $s =~ /\Q$rpc_anchor\E/g; die "rpc anchor: found $c\n" unless $c==1;
$s =~ s/\Q$rpc_anchor\E/$rpc_add/;

# 2f. evmChainId testnet map
my $ev_old = "  const testnet: Record<string, number> = {\n    arc: arcTestnet.id, base: baseSepolia.id, ethereum: sepolia.id,\n    arbitrum: arbitrumSepolia.id, polygon: polygonAmoy.id,\n  }";
my $ev_new = "  const testnet: Record<string, number> = {\n    arc: arcTestnet.id, base: baseSepolia.id, ethereum: sepolia.id,\n    arbitrum: arbitrumSepolia.id, polygon: polygonAmoy.id,\n    optimism: optimismSepolia.id, avalanche: avalancheFuji.id,\n    unichain: unichainSepolia.id, monad: monadTestnet.id,\n  }";
$c = () = $s =~ /\Q$ev_old\E/g; die "evmChainId testnet anchor: found $c\n" unless $c==1;
$s =~ s/\Q$ev_old\E/$ev_new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "bridge-chains.ts: +4 viem chains, rpc, evmChainId.\n";
PERL
perl "$PL2" "$BRIDGE"; rm -f "$PL2"

# ---------- (3) circleWallets.ts : cctpBlockchainFor testnet map ----------
PL3="$(mktemp /tmp/wallets.XXXXXX.pl)"
cat > "$PL3" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

my $old = "  const testnet: Record<string, string> = {\n    arc: 'ARC-TESTNET', base: 'BASE-SEPOLIA', ethereum: 'ETH-SEPOLIA',\n    arbitrum: 'ARB-SEPOLIA', polygon: 'MATIC-AMOY',\n  }";
my $new = "  const testnet: Record<string, string> = {\n    arc: 'ARC-TESTNET', base: 'BASE-SEPOLIA', ethereum: 'ETH-SEPOLIA',\n    arbitrum: 'ARB-SEPOLIA', polygon: 'MATIC-AMOY',\n    optimism: 'OP-SEPOLIA', avalanche: 'AVAX-FUJI',\n    unichain: 'UNI-SEPOLIA', monad: 'MONAD-TESTNET',\n  }";
my $c = () = $s =~ /\Q$old\E/g; die "cctpBlockchainFor testnet anchor: found $c\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "circleWallets.ts: cctpBlockchainFor +4 chains.\n";
PERL
perl "$PL3" "$WALLETS"; rm -f "$PL3"

echo
echo "Verify (each should list the 4 new keys):"
grep -c "optimism\|avalanche\|unichain\|monad" "$CCTP"    | sed 's/^/  cctp-chains hits:   /'
grep -c "optimismSepolia\|avalancheFuji\|unichainSepolia\|monadTestnet" "$BRIDGE" | sed 's/^/  bridge-chains hits: /'
grep -c "OP-SEPOLIA\|AVAX-FUJI\|UNI-SEPOLIA\|MONAD-TESTNET" "$WALLETS" | sed 's/^/  wallets hits:       /'
echo
echo "Deploy:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  cd $ROOT && git add -A && git commit -m 'feat(bridge): add OP, Avalanche, Unichain, Monad CCTP chains' && git push"
echo
echo "NOTE: existing users' Circle wallets were provisioned only on the old"
echo "chains. First bridge to a new chain hits NEEDS_CHAIN and the existing"
echo "add-chains self-heal flow provisions it — no manual step. (That path is"
echo "already built in useCircleTx.executeContractCall.)"
