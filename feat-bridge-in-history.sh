#!/usr/bin/env bash
# ============================================================
# feat-bridge-in-history.sh — show BRIDGE transfers in the general /history
#
# Bridge transfers live in their own /bridge table. Invoice & payroll have their
# own history views; this ONLY adds bridge rows to the general /history, by ALSO
# fetching /bridge and merging — no double-writing, /bridge stays source of truth.
#
# Uses a temp .pl helper for the JSX edits to avoid regex-delimiter clashes with
# the '/' in URLs and </a> tags. Idempotent.
# Run from repo root:  cd ~/AfriFX && bash feat-bridge-in-history.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"; WEB="$ROOT/nexum-web"
[ -d "$WEB" ] || WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: web dir not found"; exit 1; }
H="$WEB/app/(app)/history/page.tsx"
[ -f "$H" ] || { echo "ERROR: $H not found"; exit 1; }

echo "→ 1/2  Fetch /bridge alongside /transactions and merge…"
if grep -q "__bridge: true" "$H"; then
  echo "  • merge already present (skip)"
else
  PL1="$(mktemp --suffix=.pl)"
  cat > "$PL1" <<'PERL'
local $/; my $s = <>;
my $old = <<'OLD';
  useEffect(() => {
    if (!address) return
    setLoading(true)
    fetch(`${API}/transactions?wallet=${address}`)
      .then(r => r.json())
      .then(data => setTxs(Array.isArray(data) ? data : []))
      .catch(() => setTxs([]))
      .finally(() => setLoading(false))
  }, [address])
OLD
my $new = <<'NEW';
  useEffect(() => {
    if (!address) return
    setLoading(true)
    // Fetch core transactions AND bridge transfers, then merge by time.
    // Bridge rows live in their own table (/bridge); we read, not duplicate.
    Promise.all([
      fetch(`${API}/transactions?wallet=${address}`).then(r => r.json()).catch(() => []),
      fetch(`${API}/bridge?wallet=${address}`).then(r => r.json()).catch(() => []),
    ]).then(([txData, brData]) => {
      const core = Array.isArray(txData) ? txData : []
      const bridges = (Array.isArray(brData) ? brData : []).map((b) => {
        const raw = String(b.status ?? 'pending').toLowerCase()
        const status = raw === 'completed' ? 'settled'
                     : (raw === 'failed' || raw === 'error') ? 'failed'
                     : 'pending'
        return {
          __bridge: true,
          id: b.id,
          from_currency: b.from_chain, to_currency: b.to_chain,
          from_amount: Number(b.amount ?? 0), to_amount: Number(b.amount ?? 0),
          arc_tx_hash: b.mint_tx ?? b.burn_tx ?? '',
          status,
          created_at: b.created_at,
        }
      })
      setTxs([...core, ...bridges].sort(
        (a, b) => Number(b.created_at ?? 0) - Number(a.created_at ?? 0)
      ))
    }).finally(() => setLoading(false))
  }, [address])
NEW
$s =~ s/\Q$old\E/$new/ or die "useEffect anchor not found";
print $s;
PERL
  perl "$PL1" "$H" > "$H.tmp" && mv "$H.tmp" "$H"; rm -f "$PL1"
  grep -q "__bridge: true" "$H" && echo "  ✓ history fetches + merges /bridge" || { echo "  ✗ merge failed"; exit 1; }
fi

echo "→ 2/2  Render bridge rows distinctly in TxRow…"
if grep -q "isBridge" "$H"; then
  echo "  • TxRow already bridge-aware (skip)"
else
  PL2="$(mktemp --suffix=.pl)"
  cat > "$PL2" <<'PERL'
local $/; my $s = <>;

# (a) add isBridge flag at top of TxRow
my $fn = "function TxRow({ tx, isCorridorStep = false }: { tx: any; isCorridorStep?: boolean }) {\n";
$s =~ s/\Q$fn\E/$fn  const isBridge = tx.__bridge === true\n/ or die "TxRow fn not found";

# (b) Bridge badge after the currency label line
my $lbl = "          {fromCcy} → {toCcy}\n";
my $lblnew = $lbl . "          {isBridge && <span className=\"ml-1.5 align-middle\"><Badge variant=\"arc\">Bridge</Badge></span>}\n";
$s =~ s/\Q$lbl\E/$lblnew/ or die "currency label not found";

# (c) guard the ArcScan link to non-bridge rows only
my $a = "        {hash && (\n          <a href={`https://testnet.arcscan.app/tx/\${hash}`}";
my $anew = "        {hash && !isBridge && (\n          <a href={`https://testnet.arcscan.app/tx/\${hash}`}";
$s =~ s/\Q$a\E/$anew/ or die "arcscan anchor not found";

# (d) add a plain hash indicator for bridge rows (no link; source chain varies)
my $close = "          </a>\n        )}\n";
my $closenew = $close . "        {hash && isBridge && (\n          <span className=\"font-mono text-[9px] text-app-muted\" title=\"Bridge tx — view on source-chain explorer\">{hash.slice(0,6)}…{hash.slice(-4)}</span>\n        )}\n";
$s =~ s/\Q$close\E/$closenew/ or die "closing anchor not found";

print $s;
PERL
  perl "$PL2" "$H" > "$H.tmp" && mv "$H.tmp" "$H"; rm -f "$PL2"
  grep -q "isBridge" "$H" && echo "  ✓ TxRow renders bridge rows distinctly" || { echo "  ✗ TxRow edits failed"; exit 1; }
fi

echo
echo "→ Verify:"
grep -nE "__bridge|isBridge|/bridge\?wallet|Bridge</Badge>" "$H" | head

echo
echo "Done. Next:"
echo "  cd $(basename "$WEB") && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  git add -A && git commit -m 'feat(history): show bridge transfers in general history' && git push"
