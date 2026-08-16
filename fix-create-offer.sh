#!/usr/bin/env bash
# ============================================================
# fix-create-offer.sh   (run once, then deploy)
#
# THREE THINGS, in priority order:
#
#  (1) MOST LIKELY ROOT CAUSE — vault env name.
#      lib/contracts.ts reads ONLY process.env.NEXT_PUBLIC_AFRIFX_VAULT.
#      There is no NEXUM_VAULT fallback here (unlike the rest of the app).
#      If the Vercel var was renamed to NEXT_PUBLIC_NEXUM_VAULT during the
#      rebrand, this reads nothing -> vault === ZERO -> createOffer() throws
#      "Vault not configured" BEFORE setIsLoading(true). That is exactly the
#      symptom: click does nothing, no spinner, no error (old catch swallowed
#      non-reauth throws). Fix: read NEXUM first, fall back to AFRIFX.
#      NOTE: Next.js inlines NEXT_PUBLIC_* by literal name at build time, so
#      both names must appear literally — you can't compute the key.
#
#  (2) REAL BUG from the global expansion — localRaw rounding to zero.
#      localAmount = usdcAmount * rate. High-value fiat added globally
#      (KWD/BHD/OMR, rate < 1 per USDC) makes localAmount < 0.5 for small
#      offers, so BigInt(Math.round(localAmount)) === 0n and the vault
#      reverts on require(localAmount > 0). African rates (hundreds/thousands)
#      never hit this. Fix: floor at 1.
#
#  (3) DIAGNOSTICS so a single click on the live site is decisive:
#      [CREATE] console.error step logs (survive minification) + a visible
#      amber "DEBUG:" line on the page. All tagged "DEBUG" for easy removal.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: cannot find nexum-web (run from repo root or ~/AfriFX)"; exit 1; fi

CONTRACTS="$WEB/lib/contracts.ts"
CLIENT="$WEB/app/(app)/marketplace/create/CreateOfferClient.tsx"
HOOK="$WEB/hooks/useP2P.ts"
for f in "$CONTRACTS" "$CLIENT" "$HOOK"; do
  [ -f "$f" ] || { echo "ERROR: $f not found"; exit 1; }
done

# ---------- (1) vault env fallback in contracts.ts ----------
PL0="$(mktemp /tmp/contracts_fix.XXXXXX.pl)"
cat > "$PL0" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

my $ov = "  AFRIFX_VAULT:    (process.env.NEXT_PUBLIC_AFRIFX_VAULT    || ZERO) as `0x\${string}`,";
my $nv = "  AFRIFX_VAULT:    (process.env.NEXT_PUBLIC_NEXUM_VAULT || process.env.NEXT_PUBLIC_AFRIFX_VAULT || ZERO) as `0x\${string}`,";
my $c = () = $s =~ /\Q$ov\E/g; die "vault anchor: expected 1, found $c\n" unless $c==1;
$s =~ s/\Q$ov\E/$nv/;

my $oe = "  AFRIFX_EXCHANGE: (process.env.NEXT_PUBLIC_AFRIFX_EXCHANGE || ZERO) as `0x\${string}`,";
my $ne = "  AFRIFX_EXCHANGE: (process.env.NEXT_PUBLIC_NEXUM_EXCHANGE || process.env.NEXT_PUBLIC_AFRIFX_EXCHANGE || ZERO) as `0x\${string}`,";
$c = () = $s =~ /\Q$oe\E/g; die "exchange anchor: expected 1, found $c\n" unless $c==1;
$s =~ s/\Q$oe\E/$ne/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "contracts.ts patched (NEXUM env names now read first).\n";
PERL
perl "$PL0" "$CONTRACTS"; rm -f "$PL0"

# ---------- (2)+(3) localRaw fix + step logs in useP2P.ts ----------
PL1="$(mktemp /tmp/p2p_fix.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

my $old = "      const localRaw = BigInt(Math.round(params.localAmount))";
my $new = "      // DEBUG: floor at 1 so high-value fiat can't round to 0 (vault reverts on 0).\n"
        . "      const localRaw = BigInt(Math.max(1, Math.round(params.localAmount)))\n"
        . "      console.error('[CREATE] step 1: localAmount=', params.localAmount, 'localRaw=', localRaw.toString(), 'currency=', params.localCurrency, 'vault=', vault)";
my $c = () = $s =~ /\Q$old\E/g; die "localRaw anchor: found $c\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

my $oa = "      // 1. Approve the vault to pull the maker's USDC.";
my $na = "      console.error('[CREATE] step 2: calling approve on USDC ->', vault)\n"
       . "      // 1. Approve the vault to pull the maker's USDC.";
$c = () = $s =~ /\Q$oa\E/g; die "approve anchor: found $c\n" unless $c==1;
$s =~ s/\Q$oa\E/$na/;

my $oc = "      // 2. Create the offer.";
my $nc = "      console.error('[CREATE] step 3: approve returned, calling createP2POffer')\n"
       . "      // 2. Create the offer.";
$c = () = $s =~ /\Q$oc\E/g; die "create anchor: found $c\n" unless $c==1;
$s =~ s/\Q$oc\E/$nc/;

my $oh = "      const hash = (createResult.txHash ?? '') as `0x\${string}`";
my $nh = "      console.error('[CREATE] step 4: createP2POffer returned', createResult)\n"
       . "      const hash = (createResult.txHash ?? '') as `0x\${string}`";
$c = () = $s =~ /\Q$oh\E/g; die "hash anchor: found $c\n" unless $c==1;
$s =~ s/\Q$oh\E/$nh/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "useP2P.ts patched.\n";
PERL
perl "$PL1" "$HOOK"; rm -f "$PL1"

# ---------- (3) diagnostics in CreateOfferClient.tsx ----------
PL2="$(mktemp /tmp/client_fix.XXXXXX.pl)"
cat > "$PL2" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

my $os = "  const [submitted,     setSubmitted]     = useState(false)";
my $ns = "  const [submitted,     setSubmitted]     = useState(false)\n"
       . "  const [debugMsg,      setDebugMsg]      = useState('') // DEBUG";
my $c = () = $s =~ /\Q$os\E/g; die "submitted anchor: found $c\n" unless $c==1;
$s =~ s/\Q$os\E/$ns/;

my $og = "    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) return";
my $ng = "    console.error('[CREATE] click: usdcAmount=', usdcAmount, 'localAmount=', localAmount, 'timerSeconds=', timerSeconds, 'insufficientUsdc=', insufficientUsdc, 'payoutComplete=', payoutComplete, 'marketRate=', marketRate, 'address=', address)\n"
       . "    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300 || insufficientUsdc || !payoutComplete) {\n"
       . "      console.error('[CREATE] BLOCKED by guard')\n"
       . "      setDebugMsg('Guard blocked: check amount / rate / timer / payout')\n"
       . "      return\n"
       . "    }\n"
       . "    setDebugMsg('Submitting...')\n"
       . "    console.error('[CREATE] guard passed, calling createOffer')";
$c = () = $s =~ /\Q$og\E/g; die "guard anchor: found $c\n" unless $c==1;
$s =~ s/\Q$og\E/$ng/;

my $oc = "      if (err instanceof NeedsReauthError) {\n        router.push('/signin?returnTo=/marketplace/create')\n      }";
my $nc = "      console.error('[CREATE] threw:', err?.name, err?.message, err)\n"
       . "      setDebugMsg('Error: ' + (err?.message ?? String(err)))\n"
       . "      if (err instanceof NeedsReauthError) {\n"
       . "        router.push('/signin?returnTo=/marketplace/create')\n"
       . "      }";
$c = () = $s =~ /\Q$oc\E/g; die "catch anchor: found $c\n" unless $c==1;
$s =~ s/\Q$oc\E/$nc/;

my $oe = "        {error && (";
my $ne = "        {debugMsg && (\n"
       . "          <div className=\"rounded-lg bg-amber-900/20 px-4 py-3 text-xs text-amber-300\">DEBUG: {debugMsg}</div>\n"
       . "        )}\n\n"
       . "        {error && (";
$c = () = $s =~ /\Q$oe\E/g; die "error-render anchor: found $c\n" unless $c==1;
$s =~ s/\Q$oe\E/$ne/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "CreateOfferClient.tsx patched.\n";
PERL
perl "$PL2" "$CLIENT"; rm -f "$PL2"

echo
echo "Verifying:"
grep -n "NEXT_PUBLIC_NEXUM_VAULT" "$CONTRACTS" | sed 's/^/  /'
grep -cn "\[CREATE\]" "$HOOK" "$CLIENT" | sed 's/^/  [CREATE] tags: /'
echo
echo "Deploy:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix: nexum vault env fallback + localRaw floor + create-offer diagnostics' && git push"
echo
echo "IF the vault env was the cause, it will just work now (given the Vercel"
echo "var is set under EITHER name). If it still fails: live site -> create-offer"
echo "page -> DevTools Console -> click Create once -> send me the amber DEBUG"
echo "line + the last [CREATE] console line."
