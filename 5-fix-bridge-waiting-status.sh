#!/usr/bin/env bash
# ============================================================
# 5-fix-bridge-waiting-status.sh   (run once, then deploy web)
#
# BUG (from the screenshot): a transfer that is simply WAITING for Circle's
# attestation shows a red error ("Transaction failed") beneath its waiting
# spinner, even though nothing failed.
#
# CAUSE: useCompleteBridge() is a SINGLE hook instance shared by the whole
# "Recent bridges" list. Its `error` is global, but BridgeHistory renders it
# inside the per-row map WITHOUT checking which row actually errored:
#     {finish.error && finish.busyId === null && (<p class=red>{finish.error}</p>)}
# When ANY row's "Complete transfer" attempt throws (e.g. clicking before
# Circle has attested), `error` is set and `busyId` is reset to null in the
# hook's finally — so the red text then paints under EVERY pending row,
# including ones that are only waiting. The row identity is lost by render time.
#
# FIX (minimal, row-scoped):
#   1. useCompleteBridge: track `errorId` (the row that errored). Set it next to
#      `error`, keep it through finally, clear it on reset and at the start of a
#      new attempt. (busyId still resets as before — nothing else changes.)
#   2. BridgeHistory: render the error only when finish.errorId === r.id, so a
#      genuine failure shows on its own row and a waiting transfer never does.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

HOOK="$WEB/hooks/useCompleteBridge.ts"
HIST="$WEB/components/bridge/BridgeHistory.tsx"
[ -f "$HOOK" ] || { echo "ERROR: $HOOK not found"; exit 1; }
[ -f "$HIST" ] || { echo "ERROR: $HIST not found"; exit 1; }

# ---------- (1) useCompleteBridge: add errorId ----------
PL1="$(mktemp /tmp/hook.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# 1a. new state next to error
my $st_old = "  const [error,  setError]  = useState<string | null>(null)";
my $st_new = "  const [error,  setError]  = useState<string | null>(null)\n"
           . "  const [errorId, setErrorId] = useState<string | null>(null)";
my $c = () = $s =~ /\Q$st_old\E/g; die "error state anchor: found $c\n" unless $c==1;
$s =~ s/\Q$st_old\E/$st_new/;

# 1b. reset clears errorId too
my $rs_old = "    setStep('idle'); setError(null); setMintTx(null); setBusyId(null); setNote(null)";
my $rs_new = "    setStep('idle'); setError(null); setErrorId(null); setMintTx(null); setBusyId(null); setNote(null)";
$c = () = $s =~ /\Q$rs_old\E/g; die "reset anchor: found $c\n" unless $c==1;
$s =~ s/\Q$rs_old\E/$rs_new/;

# 1c. clear a prior error when a NEW attempt starts (the no-burn early return)
my $nb_old = "    if (!bridge.burn_tx) {\n      setStep('error'); setError('No burn transaction recorded for this transfer.')\n      return\n    }";
my $nb_new = "    if (!bridge.burn_tx) {\n      setStep('error'); setError('No burn transaction recorded for this transfer.'); setErrorId(bridge.id)\n      return\n    }";
$c = () = $s =~ /\Q$nb_old\E/g; die "no-burn anchor: found $c\n" unless $c==1;
$s =~ s/\Q$nb_old\E/$nb_new/;

# 1d. clear prior error at the start of a real attempt
my $begin_old = "    setBusyId(bridge.id)\n    setStep('checking'); setError(null); setNote(null)";
my $begin_new = "    setBusyId(bridge.id)\n    setStep('checking'); setError(null); setErrorId(null); setNote(null)";
$c = () = $s =~ /\Q$begin_old\E/g; die "begin anchor: found $c\n" unless $c==1;
$s =~ s/\Q$begin_old\E/$begin_new/;

# 1e. on catch, tag the row that errored
my $cat_old = "      setStep('error'); setError(message); setNote(null)";
my $cat_new = "      setStep('error'); setError(message); setErrorId(bridge.id); setNote(null)";
$c = () = $s =~ /\Q$cat_old\E/g; die "catch anchor: found $c\n" unless $c==1;
$s =~ s/\Q$cat_old\E/$cat_new/;

# 1f. expose errorId in the return
my $ret_old = "  return { step, error, mintTx, busyId, note, complete, reset }";
my $ret_new = "  return { step, error, errorId, mintTx, busyId, note, complete, reset }";
$c = () = $s =~ /\Q$ret_old\E/g; die "return anchor: found $c\n" unless $c==1;
$s =~ s/\Q$ret_old\E/$ret_new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "useCompleteBridge.ts: errorId added.\n";
PERL
perl "$PL1" "$HOOK"; rm -f "$PL1"

# ---------- (2) BridgeHistory: scope the red error to its row ----------
PL2="$(mktemp /tmp/hist.XXXXXX.pl)"
cat > "$PL2" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

my $old = "                  {finish.error && finish.busyId === null && (\n                    <p className=\"mt-1 text-[10px] text-red-700 dark:text-red-300\">{finish.error}</p>\n                  )}";
my $new = "                  {/* Only show a failure on the row that actually failed —\n"
        . "                      never under a transfer that is merely waiting to attest. */}\n"
        . "                  {finish.errorId === r.id && finish.busyId === null && finish.error && (\n"
        . "                    <p className=\"mt-1 text-[10px] text-red-700 dark:text-red-300\">{finish.error}</p>\n"
        . "                  )}";
my $c = () = $s =~ /\Q$old\E/g; die "error-render anchor: found $c\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "BridgeHistory.tsx: error render scoped to its row.\n";
PERL
perl "$PL2" "$HIST"; rm -f "$PL2"

echo
echo "Verify:"
grep -n "errorId" "$HOOK" | sed 's/^/  hook: /'
grep -n "finish.errorId === r.id" "$HIST" | sed 's/^/  hist: /'
echo
echo "Deploy (web only):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix(bridge): scope completion error to its row; waiting transfers no longer show failed' && git push"
