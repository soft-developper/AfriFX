#!/usr/bin/env bash
# ============================================================
# 3-invoice-currency-combobox.sh   (run once, then deploy web)
#
# Replaces the hardcoded 6-item currency <select> on Create Invoice
# (USDC,NGN,GHS,KES,ZAR,EGP) with the SAME searchable CurrencyCombobox used
# on Create P2P Offer — so invoices can be denominated in any live-rate
# currency, searchable by code or country. USDC stays the DEFAULT (already
# useState('USDC')) and must appear in the list.
#
# THE ONE REAL SUBTLETY (handled):
#   CurrencyCombobox only lists currencies present in the live FX feed
#   (liveCodes). USDC is the base unit — there is no USDC/USDC pair — so it
#   would NOT appear on its own. Invoices need USDC as the primary choice,
#   so we add an OPT-IN `includeUsdc` prop that prepends a synthetic USDC
#   entry. P2P keeps its current behaviour (no prop = unchanged), because a
#   USDC-denominated P2P "local currency" makes no sense there.
#
# TOUCHES:
#   web components/marketplace/CurrencyCombobox.tsx  (add includeUsdc prop)
#   web app/(app)/invoices/create/page.tsx           (swap select -> combobox)
# ============================================================
set -euo pipefail

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "$HOME/AfriFX/nexum-web" ]; then WEB="$HOME/AfriFX/nexum-web"
else echo "ERROR: run from repo root or ~/AfriFX"; exit 1; fi

COMBO="$WEB/components/marketplace/CurrencyCombobox.tsx"
INVOICE="$WEB/app/(app)/invoices/create/page.tsx"
[ -f "$COMBO" ]   || { echo "ERROR: $COMBO not found"; exit 1; }
[ -f "$INVOICE" ] || { echo "ERROR: $INVOICE not found"; exit 1; }

# ---------- (1) add includeUsdc prop to CurrencyCombobox ----------
PL1="$(mktemp /tmp/combo.XXXXXX.pl)"
cat > "$PL1" <<'PERL'
use strict; use warnings; use utf8;
# Read/write as UTF-8 so the multibyte chars we emit (emoji) and any existing
# non-ASCII in the file (the ellipsis default) round-trip correctly.
local $/; my $f = shift;
open my $fh,'<:encoding(UTF-8)',$f or die $!; my $s=<$fh>; close $fh;

# 1a. add includeUsdc to the prop signature.
# Anchor on the ASCII tail of the destructure + type (avoids the non-ASCII
# ellipsis in the placeholder default, which byte-mode perl won't match).
my $sig_old = "}: {\n  value: string\n  onChange: (code: string) => void\n  placeholder?: string\n}) {";
my $sig_new = "  includeUsdc = false,\n}: {\n  value: string\n  onChange: (code: string) => void\n  placeholder?: string\n  includeUsdc?: boolean\n}) {";
my $c = () = $s =~ /\Q$sig_old\E/g; die "combobox signature anchor: found $c\n" unless $c==1;
$s =~ s/\Q$sig_old\E/$sig_new/;

# 1b. include USDC in liveCodes when opted in (USDC has no FX pair of its own)
my $lc_old = "    for (const r of rates ?? []) {\n      const code = r.pair.split('/')[0]\n      if (code) set.add(code)\n    }\n    return set\n  }, [rates])";
my $lc_new = "    for (const r of rates ?? []) {\n      const code = r.pair.split('/')[0]\n      if (code) set.add(code)\n    }\n    if (includeUsdc) set.add('USDC')\n    return set\n  }, [rates, includeUsdc])";
$c = () = $s =~ /\Q$lc_old\E/g; die "liveCodes anchor: found $c\n" unless $c==1;
$s =~ s/\Q$lc_old\E/$lc_new/;

# 1c. give searchCurrencies results a synthetic USDC entry so it can render.
#     Prepend USDC to results when opted in and it matches the query.
my $res_old = "  const results = useMemo(() => {\n    const matches = searchCurrencies(query)\n    return matches.filter(m => liveCodes.has(m.code))\n  }, [query, liveCodes])";
my $res_new = "  const USDC_META: CurrencyMeta = {\n    code: 'USDC', name: 'USD Coin', country: 'Stablecoin', flag: '\x{1F4B5}', countries: ['USDC'],\n  }\n\n  const results = useMemo(() => {\n    const matches = searchCurrencies(query)\n    const base = matches.filter(m => liveCodes.has(m.code))\n    if (!includeUsdc) return base\n    const q = query.trim().toLowerCase()\n    const usdcMatches = !q || 'usdc'.includes(q) || 'usd coin'.includes(q) || 'stablecoin'.includes(q)\n    // USDC first, and never duplicated if the registry ever adds it.\n    const withoutUsdc = base.filter(m => m.code !== 'USDC')\n    return usdcMatches ? [USDC_META, ...withoutUsdc] : withoutUsdc\n  }, [query, liveCodes, includeUsdc])";
$c = () = $s =~ /\Q$res_old\E/g; die "results anchor: found $c\n" unless $c==1;
$s =~ s/\Q$res_old\E/$res_new/;

# 1d. selected lookup: fall back to synthetic USDC when registry lacks it
my $sel_old = "  const selected: CurrencyMeta | undefined = CURRENCY_BY_CODE[value]";
my $sel_new = "  const selected: CurrencyMeta | undefined =\n    CURRENCY_BY_CODE[value] ?? (value === 'USDC' ? USDC_META : undefined)";
$c = () = $s =~ /\Q$sel_old\E/g; die "selected anchor: found $c\n" unless $c==1;
$s =~ s/\Q$sel_old\E/$sel_new/;

open my $out,'>:encoding(UTF-8)',$f or die $!; print $out $s; close $out;
print "CurrencyCombobox.tsx: includeUsdc prop added.\n";
PERL
perl "$PL1" "$COMBO"; rm -f "$PL1"

# ---------- (2) swap the invoice <select> for the combobox ----------
PL2="$(mktemp /tmp/invoice.XXXXXX.pl)"
cat > "$PL2" <<'PERL'
use strict; use warnings;
local $/; my $f = shift; open my $fh,'<',$f or die $!; my $s=<$fh>; close $fh;

# 2a. import the combobox (after the lucide-react import line)
my $imp_old = "import { ArrowLeft, FileText, Loader2 } from 'lucide-react'";
my $imp_new = $imp_old . "\nimport { CurrencyCombobox } from '\@/components/marketplace/CurrencyCombobox'";
my $c = () = $s =~ /\Q$imp_old\E/g; die "invoice import anchor: found $c\n" unless $c==1;
$s =~ s/\Q$imp_old\E/$imp_new/;

# 2b. replace the currency <select> block with the combobox.
#     Widen the currency column so the searchable picker has room.
my $sel_old = "                <div className=\"w-32\">\n                  <label className=\"mb-1 block text-xs text-app-muted\">Currency</label>\n                  <select value={currency} onChange={e => setCurrency(e.target.value)}\n                    className=\"w-full rounded-lg border border-app-border bg-app-surface px-3 py-2 text-sm text-app-text outline-none\">\n                    {['USDC','NGN','GHS','KES','ZAR','EGP'].map(c => (\n                      <option key={c} value={c}>{c}</option>\n                    ))}\n                  </select>\n                </div>";
my $sel_new = "                <div className=\"w-44\">\n                  <label className=\"mb-1 block text-xs text-app-muted\">Currency</label>\n                  <CurrencyCombobox value={currency} onChange={setCurrency} includeUsdc />\n                </div>";
$c = () = $s =~ /\Q$sel_old\E/g; die "invoice select anchor: found $c\n" unless $c==1;
$s =~ s/\Q$sel_old\E/$sel_new/;

open my $out,'>',$f or die $!; print $out $s; close $out;
print "create invoice page: select -> CurrencyCombobox (USDC default).\n";
PERL
perl "$PL2" "$INVOICE"; rm -f "$PL2"

echo
echo "Verify:"
grep -n "includeUsdc" "$COMBO" | sed 's/^/  combobox: /'
grep -n "CurrencyCombobox" "$INVOICE" | sed 's/^/  invoice:  /'
if grep -q "<select" "$INVOICE"; then echo "  !! a <select> still remains in invoice page"; else echo "  no <select> left in invoice page."; fi
echo
echo "Deploy:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'feat(invoice): searchable currency picker, USDC default' && git push"
