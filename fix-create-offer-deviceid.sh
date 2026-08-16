#!/usr/bin/env bash
# ============================================================
# fix-create-offer-deviceid.sh
#
# BUG: Clicking "Create offer" does nothing — no error, no nav, no spinner
#      resolution. Root cause: Circle's SDK requires getDeviceId() to have
#      been called before instance.execute() will fire its callback. That
#      call only ever happens inside the LOGIN flow (startGoogleLogin /
#      sendEmailCode). A user with a live 30-day session who lands directly
#      on /marketplace/create never triggers a login, so getSdk() returns a
#      fresh SDK whose device id was never fetched. instance.execute() then
#      silently no-ops: the callback in executeChallenge never runs, its
#      Promise never settles, and createOffer awaits forever. Hence "nothing
#      happens" — the code never reaches a throw OR a resolve.
#
# FIX: Prime the device id inside both executeChallenge and
#      executeSigningChallenge, right after getSdk(), before
#      setAuthentication(). getDeviceId() is cached + idempotent (it reuses
#      the cached SDK and localStorage), so calling it every time is cheap
#      and self-healing for every challenge-executing path, not just P2P.
# ============================================================
set -euo pipefail

# Tolerate being run from repo root or elsewhere; resolve the web dir.
if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: cannot find nexum-web (run from repo root or ~/AfriFX)"; exit 1; fi

TARGET="$WEB/lib/circle.ts"
[ -f "$TARGET" ] || { echo "ERROR: $TARGET not found"; exit 1; }

echo "Patching $TARGET ..."

# .pl helper with \Q...\E literal matching — avoids perl eating template
# literals / delimiter clashes. Both executeChallenge variants share the
# exact two-line sequence below, so we insert the priming call before each.
PL="$(mktemp /tmp/circle_patch.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh, '<', $f or die $!;
my $s = <$fh>; close $fh;

my $old = "  const instance = await getSdk()\n  instance.setAuthentication({ userToken, encryptionKey })";
my $new = "  const instance = await getSdk()\n"
        . "  // Circle's SDK no-ops execute() until the device id is fetched.\n"
        . "  // Login primes it, but a user with a live session can reach a\n"
        . "  // signing screen without logging in this tab — prime it here so\n"
        . "  // the challenge callback actually fires.\n"
        . "  await getDeviceId()\n"
        . "  instance.setAuthentication({ userToken, encryptionKey })";

my $count = () = $s =~ /\Q$old\E/g;
die "Expected 2 matches of the getSdk/setAuthentication block, found $count\n"
  unless $count == 2;

$s =~ s/\Q$old\E/$new/g;

open my $out, '>', $f or die $!;
print $out $s; close $out;
print "Replaced $count occurrence(s).\n";
PERL

perl "$PL" "$TARGET"
rm -f "$PL"

echo
echo "Verifying getDeviceId() now precedes each setAuthentication():"
grep -n "await getDeviceId()" "$TARGET" || true
echo
echo "Done. Next:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix: prime Circle device id before challenge execute (create-offer hang)' && git push"
