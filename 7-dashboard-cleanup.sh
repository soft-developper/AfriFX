#!/usr/bin/env bash
# ============================================================
# 7-dashboard-cleanup.sh   (run once, then deploy web + api)
#
# DASHBOARD cleanup (item 2). Per decisions:
#   A) Volume: the old "Volume (30d)" / "All-time volume" summed conversions +
#      corridor + sends + P2P. Conversion/corridor are deprecated. Split into
#      TWO honest, distinct stats:
#        - Send volume   = transactions where from_currency === to_currency
#                          (USDC->USDC transfers), i.e. the Send nav.
#        - P2P volume    = P2P released offers (USDC = USD).
#      Backend now returns sendVol/sendVolAll and p2pVolMonth/p2pVolAll.
#   B) Remove "Top pairs" entirely (we only send USDC; no pairs). Weekly volume
#      chart goes full-width.
#   C) Remove "Live rates" entirely (visible on P2P marketplace instead).
#      Recent activity goes full-width.
#   D) Recent activity: add date + time to every row.
#
# Cleans imports/interfaces left unused (useFXRates, PairStat, TrendingDown,
# pairBreakdown usage), and drops the deprecated "conversion" empty-state copy.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ] && [ -d "nexum-api" ]; then ROOT="."
elif [ -d "$HOME/AfriFX/nexum-web" ]; then ROOT="$HOME/AfriFX"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi
WEB="$ROOT/nexum-web"; API="$ROOT/nexum-api"
DASH="$WEB/app/(app)/dashboard/page.tsx"
USERR="$API/src/routes/user.ts"
[ -f "$DASH" ]  || { echo "ERROR: $DASH not found"; exit 1; }
[ -f "$USERR" ] || { echo "ERROR: $USERR not found"; exit 1; }

# ---------- (A) backend: split send vs p2p volume ----------
PL0="$(mktemp /tmp/userr.XXXXXX.pl)"
cat > "$PL0" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# A1. compute send-only volumes (from===to) alongside the existing totals.
my $vol_old = "    const monthTxs = txs.filter(t => t.created_at > now - month)\n    const monthVol = monthTxs.reduce((s, t) => s + t._usdVol, 0)\n    const allVol   = txs.reduce((s, t) => s + t._usdVol, 0)";
my $vol_new = "    const monthTxs = txs.filter(t => t.created_at > now - month)\n"
  . "    // Send volume = USDC->USDC transfers (from === to). Excludes deprecated\n"
  . "    // conversion/corridor rows so the figure matches the 'Send volume' label.\n"
  . "    const isSend = (t) => (t.from_currency ?? '') === (t.to_currency ?? '')\n"
  . "    const sendVol    = monthTxs.filter(isSend).reduce((s, t) => s + t._usdVol, 0)\n"
  . "    const sendVolAll = txs.filter(isSend).reduce((s, t) => s + t._usdVol, 0)\n"
  . "    const sendCount     = monthTxs.filter(isSend).length\n"
  . "    const sendCountAll  = txs.filter(isSend).length";
my $c = () = $s =~ /\Q$vol_old\E/g; die "vol anchor: found $c\n" unless $c==1;
$s =~ s/\Q$vol_old\E/$vol_new/;

# A2. p2p month volume next to the existing all-time p2pVol.
my $p2p_old = "    const p2pReleased = offers.filter(o => o.status === 'released')\n    const p2pVol      = p2pReleased.reduce((s, o) => s + o.usdc_amount, 0)";
my $p2p_new = "    const p2pReleased = offers.filter(o => o.status === 'released')\n"
  . "    const p2pVol      = p2pReleased.reduce((s, o) => s + o.usdc_amount, 0)\n"
  . "    const p2pVolMonth = p2pReleased.filter(o => o.created_at > now - month).reduce((s, o) => s + o.usdc_amount, 0)\n"
  . "    const p2pCountMonth = p2pReleased.filter(o => o.created_at > now - month).length";
$c = () = $s =~ /\Q$p2p_old\E/g; die "p2p anchor: found $c\n" unless $c==1;
$s =~ s/\Q$p2p_old\E/$p2p_new/;

# A3. return the new fields (keep old ones for back-compat / other readers).
my $ret_old = "      monthly: {\n        volume:  parseFloat(monthVol.toFixed(2)),\n        txCount: monthTxs.length,\n      },\n      allTime: {\n        totalVolume: parseFloat((allVol + p2pVol).toFixed(2)),\n        txCount:     txs.length,\n      },";
my $ret_new = "      monthly: {\n"
  . "        volume:  parseFloat(monthVol.toFixed(2)),\n"
  . "        txCount: monthTxs.length,\n"
  . "      },\n"
  . "      allTime: {\n"
  . "        totalVolume: parseFloat((allVol + p2pVol).toFixed(2)),\n"
  . "        txCount:     txs.length,\n"
  . "      },\n"
  . "      // Split volumes for the dashboard (Send transfers vs P2P released).\n"
  . "      send: {\n"
  . "        month:      parseFloat(sendVol.toFixed(2)),\n"
  . "        allTime:    parseFloat(sendVolAll.toFixed(2)),\n"
  . "        countMonth: sendCount,\n"
  . "        countAll:   sendCountAll,\n"
  . "      },\n"
  . "      p2pVolume: {\n"
  . "        month:      parseFloat(p2pVolMonth.toFixed(2)),\n"
  . "        allTime:    parseFloat(p2pVol.toFixed(2)),\n"
  . "        countMonth: p2pCountMonth,\n"
  . "        countAll:   p2pReleased.length,\n"
  . "      },";
$c = () = $s =~ /\Q$ret_old\E/g; die "return anchor: found $c\n" unless $c==1;
$s =~ s/\Q$ret_old\E/$ret_new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "user.ts: send/p2p split volumes added.\n";
PERL
perl "$PL0" "$USERR"; rm -f "$PL0"

# ---------- (B/C/D) frontend dashboard ----------
PL1="$(mktemp /tmp/dash.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

# D0. extend the stats interface with the new split fields.
my $if_old = "interface DashboardStats {\n  monthly:         { volume: number; txCount: number }\n  allTime:         { totalVolume: number; txCount: number }";
my $if_new = "interface VolumeSplit { month: number; allTime: number; countMonth: number; countAll: number }\n"
  . "interface DashboardStats {\n"
  . "  monthly:         { volume: number; txCount: number }\n"
  . "  allTime:         { totalVolume: number; txCount: number }\n"
  . "  send:            VolumeSplit\n"
  . "  p2pVolume:       VolumeSplit";
my $c = () = $s =~ /\Q$if_old\E/g; die "interface anchor: found $c\n" unless $c==1;
$s =~ s/\Q$if_old\E/$if_new/;

# D0b. drop the now-unused PairStat interface + pairBreakdown field.
my $ps_old = "interface PairStat { pair: string; volume: number; txs: number }\n";
$c = () = $s =~ /\Q$ps_old\E/g; die "PairStat anchor: found $c\n" unless $c==1;
$s =~ s/\Q$ps_old\E//;
my $pb_old = "  pairBreakdown:   PairStat[]\n";
$c = () = $s =~ /\Q$pb_old\E/g; die "pairBreakdown field anchor: found $c\n" unless $c==1;
$s =~ s/\Q$pb_old\E//;

# D0c. remove unused imports: useFXRates (rates) + TrendingDown.
my $fx_old = "import { useFXRates }        from '\@/hooks/useFXRate'\n";
$c = () = $s =~ /\Q$fx_old\E/g; die "useFXRates import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$fx_old\E//;
my $td_old = "  TrendingUp, TrendingDown, ArrowLeftRight,";
my $td_new = "  TrendingUp, ArrowLeftRight,";
$c = () = $s =~ /\Q$td_old\E/g; die "TrendingDown import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$td_old\E/$td_new/;

# D0d. drop the rates hook call.
my $rc_old = "  const { data: rates }        = useFXRates()\n";
$c = () = $s =~ /\Q$rc_old\E/g; die "rates call anchor: found $c\n" unless $c==1;
$s =~ s/\Q$rc_old\E//;

# A-frontend. replace the two combined volume cards with Send + P2P cards.
my $cards_old = "    {\n      label: 'Volume (30d)',\n      value: stats ? `\$\${formatAmount(stats.monthly.volume)}` : '-',\n      sub:   `\${stats?.monthly.txCount ?? 0} conversions this month`,\n      icon:  TrendingUp,\n      color: 'text-emerald-400',\n      highlight: false,\n    },\n    {\n      label: 'All-time volume',\n      value: stats ? `\$\${formatAmount(stats.allTime.totalVolume)}` : '-',\n      sub:   `\${stats?.allTime.txCount ?? 0} total transactions`,\n      icon:  TrendingUp,\n      color: 'text-app-accent-text',\n      highlight: false,\n    },";
my $cards_new = "    {\n"
  . "      label: 'Send volume',\n"
  . "      value: stats ? `\$\${formatAmount(stats.send.month)}` : '-',\n"
  . "      sub:   `\${stats?.send.countMonth ?? 0} transfers (30d) \x{b7} \$\${formatAmount(stats?.send.allTime ?? 0)} all-time`,\n"
  . "      icon:  Send,\n"
  . "      color: 'text-emerald-400',\n"
  . "      highlight: false,\n"
  . "    },\n"
  . "    {\n"
  . "      label: 'P2P volume',\n"
  . "      value: stats ? `\$\${formatAmount(stats.p2pVolume.month)}` : '-',\n"
  . "      sub:   `\${stats?.p2pVolume.countMonth ?? 0} released (30d) \x{b7} \$\${formatAmount(stats?.p2pVolume.allTime ?? 0)} all-time`,\n"
  . "      icon:  Store,\n"
  . "      color: 'text-app-accent-text',\n"
  . "      highlight: false,\n"
  . "    },";
$c = () = $s =~ /\Q$cards_old\E/g; die "volume cards anchor: found $c\n" unless $c==1;
$s =~ s/\Q$cards_old\E/$cards_new/;

# add Send to the lucide import (used by the new card).
my $li_old = "  TrendingUp, ArrowLeftRight,\n  ExternalLink, RefreshCw, Wallet,\n  Store, AlertTriangle,";
my $li_new = "  TrendingUp, ArrowLeftRight,\n  ExternalLink, RefreshCw, Wallet,\n  Store, AlertTriangle, Send,";
$c = () = $s =~ /\Q$li_old\E/g; die "lucide Send anchor: found $c\n" unless $c==1;
$s =~ s/\Q$li_old\E/$li_new/;

# B. Row 1: make Weekly volume full width, delete the Top pairs card.
my $row1_old = "      {/* Row 1: Weekly volume + Top pairs */}\n      <div className=\"mb-4 grid gap-4 grid-cols-1 lg:grid-cols-3\">\n        <div className=\"lg:col-span-2 rounded-2xl border border-app-border bg-app-surface p-5\">";
my $row1_new = "      {/* Row 1: Weekly volume (full width) */}\n      <div className=\"mb-4 grid gap-4 grid-cols-1\">\n        <div className=\"rounded-2xl border border-app-border bg-app-surface p-5\">";
$c = () = $s =~ /\Q$row1_old\E/g; die "row1 anchor: found $c\n" unless $c==1;
$s =~ s/\Q$row1_old\E/$row1_new/;

# delete the entire Top pairs card block.
my $tp_old = "\n        <div className=\"rounded-2xl border border-app-border bg-app-surface p-5\">\n          <p className=\"mb-4 text-sm font-medium text-app-text\">Top pairs</p>\n          {isLoading ? (\n            <div className=\"space-y-2\">\n              {[1,2,3].map(i => <div key={i} className=\"h-8 animate-pulse rounded bg-app-border\" />)}\n            </div>\n          ) : stats?.pairBreakdown.length ? (\n            <div className=\"space-y-2.5\">\n              {stats.pairBreakdown.map((p: PairStat) => (\n                <div key={p.pair} className=\"flex items-center justify-between text-xs\">\n                  <span className=\"font-medium text-app-text\">{p.pair}</span>\n                  <div className=\"text-right\">\n                    <p className=\"font-mono text-app-text\">\${formatAmount(Number(p.volume))}</p>\n                    <p className=\"text-app-muted\">{p.txs} txs</p>\n                  </div>\n                </div>\n              ))}\n            </div>\n          ) : (\n            <p className=\"text-xs text-app-muted\">No transactions yet</p>\n          )}\n        </div>\n";
$c = () = $s =~ /\Q$tp_old\E/g; die "top-pairs block anchor: found $c\n" unless $c==1;
$s =~ s/\Q$tp_old\E/\n/;

# C. Row 3: make Recent activity full width; delete the Live rates card.
my $row3_old = "      {/* Row 3: Recent activity + Live rates */}\n      <div className=\"grid gap-4 grid-cols-1 lg:grid-cols-2\">\n        <div className=\"rounded-2xl border border-app-border bg-app-surface p-5\">\n          <p className=\"mb-4 text-sm font-medium text-app-text\">Recent activity</p>";
my $row3_new = "      {/* Row 3: Recent activity (full width) */}\n      <div className=\"grid gap-4 grid-cols-1\">\n        <div className=\"rounded-2xl border border-app-border bg-app-surface p-5\">\n          <p className=\"mb-4 text-sm font-medium text-app-text\">Recent activity</p>";
$c = () = $s =~ /\Q$row3_old\E/g; die "row3 anchor: found $c\n" unless $c==1;
$s =~ s/\Q$row3_old\E/$row3_new/;

# D. Recent activity: add date + time under each row (replace the reference line).
my $ref_old = "                    <p className=\"truncate font-mono text-[10px] text-app-muted\">\n                      {tx.reference ?? tx.id.slice(0,16) + '\x{2026}'}\n                    </p>";
my $ref_new = "                    <p className=\"font-mono text-[10px] text-app-muted\">\n"
  . "                      {new Date(tx.createdAt * 1000).toLocaleString([], {\n"
  . "                        year: 'numeric', month: 'short', day: 'numeric',\n"
  . "                        hour: '2-digit', minute: '2-digit',\n"
  . "                      })}\n"
  . "                    </p>";
$c = () = $s =~ /\Q$ref_old\E/g; die "recent ref anchor: found $c\n" unless $c==1;
$s =~ s/\Q$ref_old\E/$ref_new/;

# delete the Live rates card block (from its opening div through its close),
# which is the last card before the row's closing.
my $lr_old = "\n        <div className=\"rounded-2xl border border-app-border bg-app-surface p-5\">\n          <p className=\"mb-4 text-sm font-medium text-app-text\">Live rates</p>\n          <div className=\"space-y-2.5\">\n            {(rates ?? []).map(r => {\n              const up = r.change24h >= 0\n              return (\n                <div key={r.pair} className=\"flex items-center justify-between text-xs\">\n                  <span className=\"text-app-muted\">{r.pair}</span>\n                  <span className=\"font-mono text-app-text\">{r.rate.toLocaleString()}</span>\n                  <span className={`flex items-center gap-0.5 \${up ? 'text-emerald-400' : 'text-red-400'}`}>\n                    {up ? <TrendingUp className=\"h-3 w-3\" /> : <TrendingDown className=\"h-3 w-3\" />}\n                    {up ? '+' : ''}{r.change24h.toFixed(2)}%\n                  </span>\n                </div>\n              )\n            })}\n          </div>\n        </div>\n";
$c = () = $s =~ /\Q$lr_old\E/g; die "live-rates block anchor: found $c\n" unless $c==1;
$s =~ s/\Q$lr_old\E/\n/;

# D2. fix the deprecated empty-state copy (conversions -> transfers & trades).
my $es_old = "              <p className=\"mt-0.5 text-xs text-app-muted\">Your conversions and swaps will show up here.</p>\n              <Link href=\"/convert\" className=\"mt-3 inline-flex items-center gap-1.5 rounded-lg bg-app-accent px-3 py-1.5 text-xs font-medium text-app-on-accent hover:bg-app-accent-hover\">\n                Make your first conversion\n              </Link>";
my $es_new = "              <p className=\"mt-0.5 text-xs text-app-muted\">Your transfers and trades will show up here.</p>\n              <Link href=\"/send\" className=\"mt-3 inline-flex items-center gap-1.5 rounded-lg bg-app-accent px-3 py-1.5 text-xs font-medium text-app-on-accent hover:bg-app-accent-hover\">\n                Make your first transfer\n              </Link>";
$c = () = $s =~ /\Q$es_old\E/g; die "empty-state anchor: found $c\n" unless $c==1;
$s =~ s/\Q$es_old\E/$es_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "dashboard/page.tsx: volume split, top pairs + live rates removed, dates added.\n";
PERL
perl "$PL1" "$DASH"; rm -f "$PL1"

echo
echo "Verify:"
grep -n "Send volume\|P2P volume" "$DASH" | sed 's/^/  /'
for token in "Top pairs" "Live rates" "pairBreakdown" "useFXRates" "TrendingDown"; do
  if grep -q "$token" "$DASH"; then echo "  !! residue: $token"; else echo "  removed: $token"; fi
done
grep -n "send: {" "$USERR" | sed 's/^/  api: /'
echo
echo "Deploy:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  cd $ROOT && git add -A && git commit -m 'feat(dashboard): split send/p2p volume, remove top pairs + live rates, add timestamps' && git push"
