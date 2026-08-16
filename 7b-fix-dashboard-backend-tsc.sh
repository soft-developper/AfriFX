#!/usr/bin/env bash
# ============================================================
# 7b-fix-dashboard-backend-tsc.sh   (run AFTER 7-dashboard-cleanup.sh)
#
# Fixes 3 tsc errors introduced by 7-dashboard-cleanup.sh in nexum-api:
#   - monthVol / allVol were accidentally removed but the monthly/allTime
#     return block still references them -> "Cannot find name".
#   - isSend arrow param needs an explicit type -> TS7006.
#
# Idempotent-safe: anchors on the exact broken lines the previous script left.
# ============================================================
set -euo pipefail

if [ -d "nexum-api" ]; then API="nexum-api"
elif [ -d "$HOME/AfriFX/nexum-api" ]; then API="$HOME/AfriFX/nexum-api"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

USERR="$API/src/routes/user.ts"
[ -f "$USERR" ] || { echo "ERROR: $USERR not found"; exit 1; }

PL="$(mktemp /tmp/userfix.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# 1. Type the isSend param AND restore monthVol/allVol just before it.
my $old = "    const isSend = (t) => (t.from_currency ?? '') === (t.to_currency ?? '')";
my $new = "    const monthVol = monthTxs.reduce((s, t) => s + t._usdVol, 0)\n"
        . "    const allVol   = txs.reduce((s, t) => s + t._usdVol, 0)\n"
        . "    const isSend = (t: any) => (t.from_currency ?? '') === (t.to_currency ?? '')";
my $c = () = $s =~ /\Q$old\E/g;
die "isSend anchor: expected 1, found $c (already fixed?)\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "user.ts: restored monthVol/allVol, typed isSend.\n";
PERL
perl "$PL" "$USERR"; rm -f "$PL"

echo
echo "Verify (all three should resolve):"
grep -n "const monthVol\|const allVol\|isSend = (t: any)" "$USERR" | sed 's/^/  /'
echo
echo "Rebuild:"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'fix(dashboard-api): restore monthVol/allVol, type isSend' && git push"
