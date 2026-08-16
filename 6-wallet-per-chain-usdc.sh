#!/usr/bin/env bash
# ============================================================
# 6-wallet-per-chain-usdc.sh   (run once, then deploy web)
#
# WALLET NAV cleanup (item 1):
#   - Allocation pie: remove local-currency slices, replace with USDC balance
#     on EVERY supported chain (Arc incl.), keep Escrow slice.
#   - Token balances: remove local-currency cards, replace with a USDC card per
#     chain, keep the Escrow card.
#   - All chains show even with 0 USDC. New chains appear automatically because
#     everything maps over cctpChains() — no per-chain code to add later.
#
# HOW (reuses existing architecture):
#   New hook useAllChainUsdcBalances() reads balanceOf(USDC) on each
#   cctpChains() entry via the SAME wagmi getPublicClient + 6-decimals logic as
#   useChainUsdcBalance (which is single-chain and can't be looped per
#   rules-of-hooks). One effect, parallel reads, per-chain {balance,loading,error}.
#
# Local-equivalent data (data.localEquiv) is simply no longer rendered; the
# backend field can stay, we just stop using it here.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

HOOK="$WEB/hooks/useAllChainUsdcBalances.ts"
WALLET="$WEB/app/(app)/wallet/WalletContent.tsx"
[ -f "$WALLET" ] || { echo "ERROR: $WALLET not found"; exit 1; }
[ -f "$HOOK" ] && { echo "ERROR: $HOOK exists — aborting"; exit 1; }

# ---------- (1) new all-chains balance hook ----------
cat > "$HOOK" <<'TSX'
'use client'
// ============================================================
// useAllChainUsdcBalances — a wallet's USDC balance on EVERY supported chain.
//
// useChainUsdcBalance is single-chain and can't be called in a loop (rules of
// hooks), so this reads them all in one effect using the same wagmi
// getPublicClient + ERC-20 balanceOf + 6-decimals conversion. It maps over
// cctpChains(), so adding a chain to that registry makes it appear here with
// no extra code. A failed RPC read surfaces `error` for that chain and keeps
// the last known balance rather than faking 0.
// ============================================================
import { useState, useEffect, useCallback } from 'react'
import { useConfig } from 'wagmi'
import { getPublicClient } from 'wagmi/actions'
import { useAccountAddress as useAccount } from '@/hooks/useAccountAddress'
import { cctpChains } from '@/lib/cctp-chains'
import { evmChainId } from '@/lib/bridge-chains'

const ERC20_BALANCE_ABI = [
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export interface ChainBalance {
  key:     string
  name:    string
  isHome:  boolean
  balance: number
  error:   string | null
}

export function useAllChainUsdcBalances() {
  const { address } = useAccount()
  const config = useConfig()
  const [balances, setBalances] = useState<ChainBalance[]>([])
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    const chains = cctpChains()
    // Seed the shape immediately so all chains render (at 0) even before reads.
    const seed: ChainBalance[] = chains.map(c => ({
      key: c.key, name: c.name, isHome: !!c.isHome, balance: 0, error: null,
    }))
    if (!address) { setBalances(seed); return }
    setLoading(true)

    const results = await Promise.all(chains.map(async (c): Promise<ChainBalance> => {
      const base = { key: c.key, name: c.name, isHome: !!c.isHome }
      const chainId = evmChainId(c.key)
      if (!c.usdc || !chainId) return { ...base, balance: 0, error: 'Chain not configured' }
      try {
        const client = getPublicClient(config, { chainId })
        if (!client) return { ...base, balance: 0, error: 'No RPC client' }
        const raw = await client.readContract({
          address: c.usdc as `0x${string}`,
          abi: ERC20_BALANCE_ABI,
          functionName: 'balanceOf',
          args: [address],
        })
        // USDC is 6 decimals on every chain (Arc native is 18 — not this).
        return { ...base, balance: Number(raw as bigint) / 1_000_000, error: null }
      } catch (e) {
        return { ...base, balance: 0, error: e instanceof Error ? e.message : 'read failed' }
      }
    }))

    setBalances(results)
    setLoading(false)
  }, [address, config])

  useEffect(() => { load() }, [load])

  return { balances, loading, refresh: load }
}
TSX
echo "Created $HOOK"

# ---------- (2) rewrite WalletContent slices + cards ----------
PL="$(mktemp /tmp/wallet.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

# 2a. import the new hook (after useTokens import)
my $imp_old = "import { useTokens } from '\@/lib/tokens'";
my $imp_new = "import { useTokens } from '\@/lib/tokens'\n"
            . "import { useAllChainUsdcBalances } from '\@/hooks/useAllChainUsdcBalances'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# 2a-bis. remove now-unused CURRENCY_FLAG const (only the local cards used it).
my $cf_old = "const CURRENCY_FLAG: Record<string, string> = {\n  NGN: '\x{1F1F3}\x{1F1EC}', GHS: '\x{1F1EC}\x{1F1ED}', KES: '\x{1F1F0}\x{1F1EA}', ZAR: '\x{1F1FF}\x{1F1E6}', EGP: '\x{1F1EA}\x{1F1EC}'\n}\n\n";
$c = () = $s =~ /\Q$cf_old\E/g; die "CURRENCY_FLAG anchor: found $c\n" unless $c==1;
$s =~ s/\Q$cf_old\E//;

# 2b. call the hook near the other hooks
my $call_old = "  const { data, isLoading, refetch } = useWallet()";
my $call_new = "  const { data, isLoading, refetch } = useWallet()\n"
             . "  const { balances: chainBalances } = useAllChainUsdcBalances()";
$c = () = $s =~ /\Q$call_old\E/g; die "hook-call anchor: found $c\n" unless $c==1;
$s =~ s/\Q$call_old\E/$call_new/;

# 2c. replace LOCAL_COLORS + localSlices + pieData with chain-based versions.
# Anchor spans from the "Local currency colors" comment through the pieData close.
my $blk_old = "  // Local currency colors\n  const LOCAL_COLORS: Record<string, string> = {\n    NGN: '#16A34A', GHS: '#DC2626',\n    KES: '#9333EA', ZAR: '#0891B2', EGP: '#C2410C',\n  }\n\n  // Local currency slices USD equivalent (localAmount / rate = usdcBalance)\n  const localSlices = (data?.localEquiv ?? [])\n    .map(({ currency, amount, rate }) => ({\n      name:  currency,\n      value: rate > 0 ? parseFloat((amount / rate).toFixed(2)) : 0,\n      color: LOCAL_COLORS[currency] ?? '#6366F1',\n    }))\n    .filter(d => d.value > 0)\n\n  // Full pie: tokens + escrow + local equivalents\n  const pieData = [\n    ...(data?.tokens ?? []).map(t => ({\n      name: t.symbol, value: t.usdValue, color: t.color,\n    })),\n    ...(escrowUSD > 0 ? [{ name: 'Escrow', value: escrowUSD, color: '#F59E0B' }] : []),\n    ...localSlices,\n  ].filter(d => d.value > 0)";

my $blk_new = "  // Per-chain USDC palette. Chains beyond this list fall back to indigo, so a\n"
  . "  // newly added chain still gets a slice/legend colour without a code change.\n"
  . "  const CHAIN_COLORS: Record<string, string> = {\n"
  . "    arc: '#B8860B', base: '#0052FF', ethereum: '#627EEA', arbitrum: '#28A0F0',\n"
  . "    polygon: '#8247E5', optimism: '#FF0420', avalanche: '#E84142',\n"
  . "    unichain: '#F50DB4', monad: '#836EF9',\n"
  . "  }\n"
  . "  const chainColor = (key: string) => CHAIN_COLORS[key] ?? '#6366F1'\n\n"
  . "  // USDC held on each supported chain (USDC = USD 1:1). All chains listed,\n"
  . "  // even at 0, so users see the full footprint; new chains appear automatically.\n"
  . "  const chainSlices = chainBalances.map(b => ({\n"
  . "    name:  `USDC \x{b7} \${b.name}`,\n"
  . "    value: parseFloat(b.balance.toFixed(2)),\n"
  . "    color: chainColor(b.key),\n"
  . "  }))\n\n"
  . "  // Pie shows only non-zero slices (a pie of zeros renders nothing useful),\n"
  . "  // plus the Escrow slice. The legend/table below lists every chain incl. 0.\n"
  . "  const pieData = [\n"
  . "    ...chainSlices.filter(d => d.value > 0),\n"
  . "    ...(escrowUSD > 0 ? [{ name: 'Escrow', value: escrowUSD, color: '#F59E0B' }] : []),\n"
  . "  ]";
$c = () = $s =~ /\Q$blk_old\E/g; die "pie-block anchor: found $c\n" unless $c==1;
$s =~ s/\Q$blk_old\E/$blk_new/;

# 2d. the legend under the pie: list every chain (incl 0) + escrow, not pieData.
my $leg_old = "              <div className=\"mt-2 max-h-44 overflow-y-auto space-y-1.5 pr-1\">\n                {pieData.map(d => (\n                  <div key={d.name} className=\"flex items-center justify-between text-xs\">\n                    <div className=\"flex items-center gap-1.5\">\n                      <span className=\"h-2 w-2 shrink-0 rounded-full\" style={{ background: d.color }} />\n                      <span className=\"text-app-muted\">{d.name}</span>\n                    </div>\n                    <span className=\"font-mono text-app-text\">\${formatAmount(d.value)}</span>\n                  </div>\n                ))}\n              </div>\n              <p className=\"mt-2 border-t border-app-border pt-2 text-[10px] text-app-muted\">\n                Local currencies show USD equivalent of your USDC holdings\n              </p>";
my $leg_new = "              <div className=\"mt-2 max-h-44 overflow-y-auto space-y-1.5 pr-1\">\n"
  . "                {[...chainSlices, ...(escrowUSD > 0 ? [{ name: 'Escrow', value: escrowUSD, color: '#F59E0B' }] : [])].map(d => (\n"
  . "                  <div key={d.name} className=\"flex items-center justify-between text-xs\">\n"
  . "                    <div className=\"flex items-center gap-1.5\">\n"
  . "                      <span className=\"h-2 w-2 shrink-0 rounded-full\" style={{ background: d.color }} />\n"
  . "                      <span className=\"text-app-muted\">{d.name}</span>\n"
  . "                    </div>\n"
  . "                    <span className=\"font-mono text-app-text\">\${formatAmount(d.value)}</span>\n"
  . "                  </div>\n"
  . "                ))}\n"
  . "              </div>\n"
  . "              <p className=\"mt-2 border-t border-app-border pt-2 text-[10px] text-app-muted\">\n"
  . "                USDC balance held on each supported chain\n"
  . "              </p>";
$c = () = $s =~ /\Q$leg_old\E/g; die "legend anchor: found $c\n" unless $c==1;
$s =~ s/\Q$leg_old\E/$leg_new/;

# 2e. replace the local-currency token cards with per-chain USDC cards.
my $cards_old = "          {/* Local currency equivalent cards */}\n          {(data?.localEquiv ?? []).map(({ currency, flag, rate, amount }) => (\n            <div key={currency}\n              className=\"flex items-center gap-3 rounded-xl border border-app-border bg-app-bg p-4\">\n              <div className=\"flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-app-border text-xl\">\n                {flag}\n              </div>\n              <div className=\"flex-1 min-w-0\">\n                <div className=\"flex items-center justify-between\">\n                  <p className=\"text-sm font-medium text-app-text\">{currency}</p>\n                  <p className=\"font-mono text-sm font-semibold text-app-text\">\n                    {isLoading\n                      ? <span className=\"inline-block h-4 w-20 animate-pulse rounded bg-app-border\" />\n                      : amount.toLocaleString(undefined, { maximumFractionDigits: 0 })\n                    }\n                  </p>\n                </div>\n                <div className=\"flex items-center justify-between\">\n                  <p className=\"text-xs text-app-muted\">USDC equivalent</p>\n                  <p className=\"text-xs text-app-muted\">1 USDC = {rate.toLocaleString()}</p>\n                </div>\n              </div>\n            </div>\n          ))}";
my $cards_new = "          {/* Per-chain USDC cards. Every supported chain shows, even at 0.\n"
  . "              Maps chainBalances so new chains appear with no code change. */}\n"
  . "          {chainBalances.map(b => (\n"
  . "            <div key={b.key}\n"
  . "              className=\"flex items-center gap-3 rounded-xl border border-app-border bg-app-bg p-4\">\n"
  . "              <div className=\"flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-[11px] font-bold text-white\"\n"
  . "                style={{ background: chainColor(b.key) }}>\n"
  . "                USDC\n"
  . "              </div>\n"
  . "              <div className=\"flex-1 min-w-0\">\n"
  . "                <div className=\"flex items-center justify-between\">\n"
  . "                  <p className=\"text-sm font-medium text-app-text\">USDC</p>\n"
  . "                  <p className=\"font-mono text-sm font-semibold text-app-text\">\n"
  . "                    {formatAmount(b.balance)}\n"
  . "                  </p>\n"
  . "                </div>\n"
  . "                <div className=\"flex items-center justify-between\">\n"
  . "                  <p className=\"text-xs text-app-muted\">{b.name}{b.isHome ? ' (home)' : ''}</p>\n"
  . "                  <p className=\"text-xs text-app-muted\">\x{2248} \${formatAmount(b.balance)}</p>\n"
  . "                </div>\n"
  . "              </div>\n"
  . "            </div>\n"
  . "          ))}";
$c = () = $s =~ /\Q$cards_old\E/g; die "cards anchor: found $c\n" unless $c==1;
$s =~ s/\Q$cards_old\E/$cards_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "WalletContent.tsx: allocation + token balances now per-chain USDC.\n";
PERL
perl "$PL" "$WALLET"; rm -f "$PL"

echo
echo "Verify:"
grep -n "useAllChainUsdcBalances\|chainSlices\|chainBalances.map\|CHAIN_COLORS" "$WALLET" | sed 's/^/  /'
if grep -q "localEquiv" "$WALLET"; then echo "  note: data.localEquiv still referenced somewhere (check):"; grep -n "localEquiv" "$WALLET" | sed 's/^/    /'; else echo "  localEquiv no longer used in wallet."; fi
echo
echo "Deploy (web only):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'feat(wallet): per-chain USDC in allocation + token balances' && git push"
