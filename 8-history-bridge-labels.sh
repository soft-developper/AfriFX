#!/usr/bin/env bash
# ============================================================
# 8-history-bridge-labels.sh   (run once, then deploy web)
#
# HISTORY nav (item 3): bridge rows showed chain names where currencies belong.
# A bridge of 10 USDC from Unichain to Arbitrum rendered as:
#     unichain -> arbitrum      and     -10 unichain / +10.0000 arbitrum
# because the merge set from_currency = from_chain and to_currency = to_chain.
# CCTP only ever moves USDC, so:
#   - amounts should read  -10 USDC / +10.0000 USDC
#   - the chain route stays visible, shown as proper names (Unichain -> Arbitrum)
#     using the chain registry, next to the existing "Bridge" badge.
#
# FIX:
#   1. In the /history merge, keep chain names in dedicated from_chain/to_chain
#      fields and set from_currency/to_currency to 'USDC'.
#   2. In TxRow, for bridge rows, render the route from the chain fields and
#      force the currency label to USDC on both amount lines.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

HIST="$WEB/app/(app)/history/page.tsx"
[ -f "$HIST" ] || { echo "ERROR: $HIST not found"; exit 1; }

PL="$(mktemp /tmp/hist.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

# 0. import chainByKey for name lookup (after the lucide-react import).
my $imp_old = "import { ArrowLeftRight, ArrowRight, ExternalLink } from 'lucide-react'";
my $imp_new = $imp_old . "\nimport { chainByKey } from '\@/lib/cctp-chains'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# 1. merge: USDC currencies + keep chain names in from_chain/to_chain.
my $mg_old = "          __bridge: true,\n          id: b.id,\n          from_currency: b.from_chain, to_currency: b.to_chain,\n          from_amount: Number(b.amount ?? 0), to_amount: Number(b.amount ?? 0),";
my $mg_new = "          __bridge: true,\n"
  . "          id: b.id,\n"
  . "          // CCTP moves USDC only; keep the chain route in dedicated fields.\n"
  . "          from_currency: 'USDC', to_currency: 'USDC',\n"
  . "          from_chain: b.from_chain, to_chain: b.to_chain,\n"
  . "          from_amount: Number(b.amount ?? 0), to_amount: Number(b.amount ?? 0),";
$c = () = $s =~ /\Q$mg_old\E/g; die "merge anchor: found $c\n" unless $c==1;
$s =~ s/\Q$mg_old\E/$mg_new/;

# 2a. TxRow: derive the bridge route names alongside the existing vars.
my $var_old = "  const isBridge = tx.__bridge === true\n  const fromCcy   = tx.from_currency ?? tx.fromCurrency  ?? ''\n  const toCcy     = tx.to_currency   ?? tx.toCurrency    ?? ''";
my $var_new = "  const isBridge = tx.__bridge === true\n"
  . "  const fromCcy   = tx.from_currency ?? tx.fromCurrency  ?? ''\n"
  . "  const toCcy     = tx.to_currency   ?? tx.toCurrency    ?? ''\n"
  . "  // Bridge rows carry chain keys; show friendly names for the route.\n"
  . "  const fromChainName = tx.from_chain ? (chainByKey(tx.from_chain)?.name ?? tx.from_chain) : ''\n"
  . "  const toChainName   = tx.to_chain   ? (chainByKey(tx.to_chain)?.name   ?? tx.to_chain)   : ''";
$c = () = $s =~ /\Q$var_old\E/g; die "TxRow vars anchor: found $c\n" unless $c==1;
$s =~ s/\Q$var_old\E/$var_new/;

# 2b. title line: for bridge, show the chain route; otherwise the currency pair.
my $title_old = "          {fromCcy} \x{2192} {toCcy}\n          {isBridge && <span className=\"ml-1.5 align-middle\"><Badge variant=\"arc\">Bridge</Badge></span>}";
my $title_new = "          {isBridge ? `\${fromChainName} \x{2192} \${toChainName}` : `\${fromCcy} \x{2192} \${toCcy}`}\n"
  . "          {isBridge && <span className=\"ml-1.5 align-middle\"><Badge variant=\"arc\">Bridge</Badge></span>}";
$c = () = $s =~ /\Q$title_old\E/g; die "title anchor: found $c\n" unless $c==1;
$s =~ s/\Q$title_old\E/$title_new/;

# 2c. amount lines: label both with the currency (now 'USDC' for bridges).
#     fromCcy/toCcy are already 'USDC' for bridge rows after the merge fix, so
#     no special-casing needed — but guard against an empty label just in case.
my $amt_old = "        <p className=\"font-mono text-sm text-red-400\">\n          -{fromAmt.toLocaleString(undefined, { maximumFractionDigits: 4 })} {fromCcy}\n        </p>\n        <p className=\"font-mono text-sm text-emerald-400\">\n          +{toAmt.toFixed(4)} {toCcy}\n        </p>";
my $amt_new = "        <p className=\"font-mono text-sm text-red-400\">\n"
  . "          -{fromAmt.toLocaleString(undefined, { maximumFractionDigits: 4 })} {fromCcy || 'USDC'}\n"
  . "        </p>\n"
  . "        <p className=\"font-mono text-sm text-emerald-400\">\n"
  . "          +{toAmt.toFixed(4)} {toCcy || 'USDC'}\n"
  . "        </p>";
$c = () = $s =~ /\Q$amt_old\E/g; die "amounts anchor: found $c\n" unless $c==1;
$s =~ s/\Q$amt_old\E/$amt_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "history/page.tsx: bridge rows now show USDC amounts + chain route.\n";
PERL
perl "$PL" "$HIST"; rm -f "$PL"

echo
echo "Verify:"
grep -n "from_currency: 'USDC'\|fromChainName\|fromCcy || 'USDC'" "$HIST" | sed 's/^/  /'
echo
echo "Deploy (web only):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix(history): bridge rows show USDC amounts and chain route' && git push"
