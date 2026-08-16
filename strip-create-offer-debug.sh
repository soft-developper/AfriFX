#!/usr/bin/env bash
# ============================================================
# strip-create-offer-debug.sh   (run once, then deploy)
#
# Removes ALL diagnostics added by fix-create-offer.sh, while KEEPING the
# two real fixes:
#   - contracts.ts NEXUM_VAULT/NEXUM_EXCHANGE env fallback  (untouched)
#   - localRaw floor-at-1 for high-value fiat               (kept, log removed)
#
# Strips:
#   - every console.error('[CREATE] ...') line
#   - the debugMsg state + all setDebugMsg(...) calls
#   - the amber DEBUG render block
#   - restores the guard back to the original one-line early return
#   - restores the catch to reauth-only (createOffer still sets visible error)
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: cannot find nexum-web (run from repo root or ~/AfriFX)"; exit 1; fi

CLIENT="$WEB/app/(app)/marketplace/create/CreateOfferClient.tsx"
HOOK="$WEB/hooks/useP2P.ts"
[ -f "$CLIENT" ] || { echo "ERROR: $CLIENT not found"; exit 1; }
[ -f "$HOOK" ]   || { echo "ERROR: $HOOK not found"; exit 1; }

# ---------- useP2P.ts: drop [CREATE] logs, keep the localRaw fix ----------
PL1="$(mktemp /tmp/p2p_strip.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# Restore the localRaw block to a clean version (drop the DEBUG comment + log,
# keep the floor-at-1 fix).
my $old = "      // DEBUG: floor at 1 so high-value fiat can't round to 0 (vault reverts on 0).\n"
        . "      const localRaw = BigInt(Math.max(1, Math.round(params.localAmount)))\n"
        . "      console.error('[CREATE] step 1: localAmount=', params.localAmount, 'localRaw=', localRaw.toString(), 'currency=', params.localCurrency, 'vault=', vault)";
my $new = "      // Floor at 1 so high-value fiat (rate < 1/USDC) can't round to 0,\n"
        . "      // which would revert the vault's require(localAmount > 0).\n"
        . "      const localRaw = BigInt(Math.max(1, Math.round(params.localAmount)))";
my $c = () = $s =~ /\Q$old\E/g; die "localRaw block: found $c\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

# Remove the three standalone [CREATE] log lines (each followed by a newline).
for my $line (
  "      console.error('[CREATE] step 2: calling approve on USDC ->', vault)\n",
  "      console.error('[CREATE] step 3: approve returned, calling createP2POffer')\n",
  "      console.error('[CREATE] step 4: createP2POffer returned', createResult)\n",
) {
  my $n = () = $s =~ /\Q$line\E/g; die "log line missing/dup ($n): $line" unless $n==1;
  $s =~ s/\Q$line\E//;
}

die "residual [CREATE] in hook\n" if $s =~ /\[CREATE\]/;
open my $out,'>',$f or die $!; print $out $s; close $out;
print "useP2P.ts cleaned.\n";
PERL
perl "$PL1" "$HOOK"; rm -f "$PL1"

# ---------- CreateOfferClient.tsx: drop all debug UI + logs ----------
PL2="$(mktemp /tmp/client_strip.XXXXXX.pl)"
cat > "$PL2" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# 1. debugMsg state line
my $st = "  const [debugMsg,      setDebugMsg]      = useState('') // DEBUG\n";
my $n = () = $s =~ /\Q$st\E/g; die "debug state: found $n\n" unless $n==1;
$s =~ s/\Q$st\E//;

# 2. restore the guarded handleCreate opening back to the original one-liner
my $og = "    console.error('[CREATE] click: usdcAmount=', usdcAmount, 'localAmount=', localAmount, 'timerSeconds=', timerSeconds, 'insufficientUsdc=', insufficientUsdc, 'payoutComplete=', payoutComplete, 'marketRate=', marketRate, 'address=', address)\n"
       . "    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) {\n"
       . "      console.error('[CREATE] BLOCKED by guard')\n"
       . "      setDebugMsg('Guard blocked: check amount / rate / timer / payout')\n"
       . "      return\n"
       . "    }\n"
       . "    setDebugMsg('Submitting...')\n"
       . "    console.error('[CREATE] guard passed, calling createOffer')";
my $ng = "    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) return";
$n = () = $s =~ /\Q$og\E/g; die "guard block: found $n\n" unless $n==1;
$s =~ s/\Q$og\E/$ng/;

# 3. restore catch to reauth-only
my $oc = "      console.error('[CREATE] threw:', err?.name, err?.message, err)\n"
       . "      setDebugMsg('Error: ' + (err?.message ?? String(err)))\n"
       . "      if (err instanceof NeedsReauthError) {\n"
       . "        router.push('/signin?returnTo=/marketplace/create')\n"
       . "      }";
my $nc = "      if (err instanceof NeedsReauthError) {\n"
       . "        router.push('/signin?returnTo=/marketplace/create')\n"
       . "      }";
$n = () = $s =~ /\Q$oc\E/g; die "catch block: found $n\n" unless $n==1;
$s =~ s/\Q$oc\E/$nc/;

# 4. remove the amber DEBUG render block
my $od = "        {debugMsg && (\n"
       . "          <div className=\"rounded-lg bg-amber-900/20 px-4 py-3 text-xs text-amber-300\">DEBUG: {debugMsg}</div>\n"
       . "        )}\n\n"
       . "        {error && (";
my $nd = "        {error && (";
$n = () = $s =~ /\Q$od\E/g; die "debug render block: found $n\n" unless $n==1;
$s =~ s/\Q$od\E/$nd/;

die "residual [CREATE] in client\n"  if $s =~ /\[CREATE\]/;
die "residual debugMsg in client\n"  if $s =~ /debugMsg/;
open my $out,'>',$f or die $!; print $out $s; close $out;
print "CreateOfferClient.tsx cleaned.\n";
PERL
perl "$PL2" "$CLIENT"; rm -f "$PL2"

echo
echo "Sanity — no debug residue anywhere:"
if grep -rn "\[CREATE\]\|debugMsg\|DEBUG:" "$HOOK" "$CLIENT"; then
  echo "  !! residue found above"; exit 1
else
  echo "  clean."
fi
echo
echo "Kept: contracts.ts env fallback + localRaw floor-at-1."
echo
echo "Deploy:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'chore: remove create-offer debug instrumentation' && git push"
