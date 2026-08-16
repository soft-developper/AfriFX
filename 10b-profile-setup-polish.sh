#!/usr/bin/env bash
# ============================================================
# 10b-profile-setup-polish.sh   (run once, then deploy web)
#
# Elevates the profile-setup page header to match the redesigned sign-in
# (gold-ringed mark, wordmark + tagline, ambient glow) so all three auth
# surfaces feel like one product. Logic and the stepper are untouched.
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

F="$WEB/app/(auth)/profile/setup/ProfileSetupClient.tsx"
[ -f "$F" ] || { echo "ERROR: $F not found"; exit 1; }

PL="$(mktemp /tmp/psetup.XXXXXX.pl)"
cat > "$PL" <<'PERL'
use strict; use warnings; use utf8;
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

# Elevate the outer container (add relative+overflow for the glow) and the
# header block to match signin: gold-ringed mark + wordmark + tagline + glow.
my $old = "    <div className=\"flex min-h-screen flex-col items-center justify-center px-4 py-12\">\n"
        . "      <div className=\"mb-8 flex items-center gap-2\">\n"
        . "        <div className=\"flex h-10 w-10 items-center justify-center rounded-xl bg-app-accent/20\">\n"
        . "          <ArrowLeftRight className=\"h-5 w-5 text-app-accent-text\" />\n"
        . "        </div>\n"
        . "        <span className=\"text-xl font-semibold text-app-text\">Nexum</span>\n"
        . "      </div>";
my $new = "    <div className=\"relative flex min-h-screen flex-col items-center justify-center overflow-hidden px-4 py-12\">\n"
        . "      <div aria-hidden className=\"pointer-events-none absolute left-1/2 top-24 h-72 w-72 -translate-x-1/2 rounded-full bg-app-accent/10 blur-3xl\" />\n"
        . "      <div className=\"relative z-10 mb-8 flex items-center gap-3\">\n"
        . "        <div className=\"flex h-12 w-12 items-center justify-center rounded-2xl border border-app-accent/30 bg-app-accent/15\">\n"
        . "          <ArrowLeftRight className=\"h-6 w-6 text-app-accent-text\" />\n"
        . "        </div>\n"
        . "        <div>\n"
        . "          <h1 className=\"text-2xl font-semibold tracking-tight text-app-text\">Nexum</h1>\n"
        . "          <p className=\"text-xs text-app-muted\">Dollars that move like messages</p>\n"
        . "        </div>\n"
        . "      </div>";
my $c = () = $s =~ /\Q$old\E/g; die "header anchor: expected 1, found $c\n" unless $c==1;
$s =~ s/\Q$old\E/$new/;

# Give the step content a z-10 so it sits above the glow.
my $s1_old = "      {step === 3 && (\n        <div className=\"w-full max-w-sm text-center\">";
my $s1_new = "      {step === 3 && (\n        <div className=\"relative z-10 w-full max-w-sm text-center\">";
$c = () = $s =~ /\Q$s1_old\E/g; die "step3 anchor: $c\n" unless $c==1;
$s =~ s/\Q$s1_old\E/$s1_new/;

my $s2_old = "      {step < 3 && (\n        <div className=\"w-full max-w-sm\">";
my $s2_new = "      {step < 3 && (\n        <div className=\"relative z-10 w-full max-w-sm\">";
$c = () = $s =~ /\Q$s2_old\E/g; die "step<3 anchor: $c\n" unless $c==1;
$s =~ s/\Q$s2_old\E/$s2_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "ProfileSetupClient.tsx: header + container elevated.\n";
PERL
perl "$PL" "$F"; rm -f "$PL"

echo
echo "Verify:"
grep -c "Dollars that move like messages" "$F" | sed 's/^/  tagline present: /'
grep -c "relative z-10" "$F" | sed 's/^/  z-10 layers: /'
echo
echo "Deploy (web only):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'feat(auth): elevate profile-setup header to match signin' && git push"
