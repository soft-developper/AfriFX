#!/usr/bin/env bash
# ============================================================
# fix-createoffer-and-part3.sh
#   FIX A: Create Offer button "does nothing" — handleCreate had `catch (_e) {}`
#          which SWALLOWED errors (incl. Circle NeedsReauthError when the signing
#          session expired). Now surfaces the error like the Send page does, so a
#          failure shows a message + a "Sign in again" path instead of silence.
#   PART 3: marketplace FILTER goes global — replace the 14-currency chip row with
#          the searchable CurrencyCombobox (+ "All"), and show correct flags per
#          offer from the ISO registry instead of the old 14-entry map.
#
# Requires Parts 1 & 2 deployed (lib/currencies.ts, CurrencyCombobox).
# Idempotent. Run from repo root:  cd ~/AfriFX && bash fix-createoffer-and-part3.sh
# ============================================================
set -euo pipefail
ROOT="$(pwd)"
WEB="$ROOT/nexum-web"; [ -d "$WEB" ] || WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from repo root"; exit 1; }
cd "$WEB"
CO="app/(app)/marketplace/create/CreateOfferClient.tsx"
MP="app/(app)/marketplace/page.tsx"
[ -f "$CO" ] && [ -f "$MP" ] || { echo "ERROR: marketplace files not found"; exit 1; }
[ -f lib/currencies.ts ] || { echo "ERROR: run Parts 1 & 2 first"; exit 1; }

echo "→ FIX A  Stop handleCreate from swallowing the error…"
if grep -q "catch (_e) {}" "$CO"; then
  # Surface the error. createOffer already setError()s internally, but make the
  # swallow explicit + add a reauth redirect path so an expired Circle session
  # sends the user to re-authenticate (with returnTo back to this page).
  PLA="$(mktemp --suffix=.pl)"
  cat > "$PLA" <<'PERLA'
local $/; my $s=<>;
my $old = "    } catch (_e) {}";
my $new = join("\n",
  "    } catch (err: any) {",
  "      // Do NOT swallow - an expired Circle signing session throws NeedsReauthError.",
  "      // createOffer already sets the visible error; if it is a reauth, guide the",
  "      // user to sign in again and come back to finish creating the offer.",
  "      if (err instanceof NeedsReauthError) {",
  "        router.push('/signin?returnTo=/marketplace/create')",
  "      }",
  "    }");
$s =~ s/\Q$old\E/$new/ or die "handleCreate catch not matched";
print $s;
PERLA
  perl "$PLA" "$CO" > "$CO.tmp" && mv "$CO.tmp" "$CO"; rm -f "$PLA"
  # ensure NeedsReauthError is imported
  if ! grep -q "NeedsReauthError" "$CO"; then
    perl -0pi -e "s{(import \{ useP2P, type OrderType \} from '\@/hooks/useP2P'\n)}{\$1import { NeedsReauthError } from '\@/hooks/useCircleTx'\n}" "$CO"
  fi
  grep -q "instanceof NeedsReauthError" "$CO" && echo "  ✓ errors surfaced + reauth redirect added" || { echo "  ✗ handleCreate anchor not matched"; exit 1; }
else
  echo "  • handleCreate already fixed (skip)"
fi

echo "→ PART 3a  Marketplace filter → searchable combobox…"
if grep -q "CurrencyCombobox" "$MP"; then
  echo "  • filter already uses combobox (skip)"
else
  # import combobox + registry
  perl -0pi -e "s{(import \{ LOCAL_CURRENCIES, CURRENCY_FLAG \} from '\@/lib/corridor'\n)}{import { CurrencyCombobox } from '\@/components/marketplace/CurrencyCombobox'\nimport { CURRENCY_BY_CODE } from '\@/lib/currencies'\n}" "$MP"

  # replace the chip row with: an "All" toggle + the combobox
  PL="$(mktemp --suffix=.pl)"
  cat > "$PL" <<'PERL'
local $/; my $s=<>;
my $old = <<'OLD';
        {['all', ...LOCAL_CURRENCIES].map(c => (
          <button key={c} onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-app-accent text-app-on-accent'
                : 'border border-app-border text-app-muted hover:text-app-text'}`}>
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c as Currency]} ${c}`}
          </button>
        ))}
OLD
my $new = <<'NEW';
        <button onClick={() => setCurrency('all')}
          className={`rounded-full px-3 py-1 text-xs transition-colors
            ${currency === 'all'
              ? 'bg-app-accent text-app-on-accent'
              : 'border border-app-border text-app-muted hover:text-app-text'}`}>
          All
        </button>
        <div className="w-56">
          <CurrencyCombobox value={currency === 'all' ? '' : currency} onChange={setCurrency} />
        </div>
        {currency !== 'all' && (
          <button onClick={() => setCurrency('all')}
            className="rounded-full border border-app-border px-3 py-1 text-xs text-app-muted hover:text-app-text">
            Clear
          </button>
        )}
NEW
$s =~ s/\Q$old\E/$new/ or die "filter chip block not matched";
print $s;
PERL
  perl "$PL" "$MP" > "$MP.tmp" && mv "$MP.tmp" "$MP"; rm -f "$PL"
  grep -q "CurrencyCombobox value={currency" "$MP" && echo "  ✓ filter replaced with combobox + All/Clear" || { echo "  ✗ filter block not matched"; exit 1; }
fi

echo "→ PART 3b  Correct per-offer flags from the registry…"
if grep -q "CURRENCY_BY_CODE\[offer.local_currency" "$MP"; then
  echo "  • offer flags already from registry (skip)"
else
  perl -0pi -e "s{CURRENCY_FLAG\[offer\.local_currency as Currency\] \?\? '🌍'}{CURRENCY_BY_CODE[offer.local_currency]?.flag ?? '🌍'}" "$MP"
  echo "  ✓ per-offer flags now use the global registry"
fi

echo
echo "→ Verify:"
grep -n "instanceof NeedsReauthError" "$CO" | head -1
grep -n "CurrencyCombobox value={currency" "$MP" | head -1
grep -n "CURRENCY_BY_CODE\[offer.local_currency" "$MP" | head -1
echo "  (LOCAL_CURRENCIES/CURRENCY_FLAG may now be unused in $MP — harmless w/o noUnusedLocals)"

echo
echo "Done. Next:"
echo "  cd $(basename "$WEB") && rm -rf .next && npx tsc --noEmit && npm run build && cd .."
echo "  # test: expired session → Create Offer now redirects to sign in (not silent)."
echo "  #       marketplace filter → search any country/currency; offers show right flags."
echo "  git add -A && git commit -m 'fix(p2p): surface create-offer errors + global marketplace filter (part 3)' && git push"
