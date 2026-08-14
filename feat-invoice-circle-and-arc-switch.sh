#!/usr/bin/env bash
# ============================================================
# feat-invoice-circle-and-arc-switch.sh
#
# THREE additions to the public invoice pay page, all reusing PROVEN code:
#
#  A) Auto add/switch to Arc for external (MetaMask/injected) payers.
#     Before the USDC transfer, ensure the wallet is on Arc (5042002).
#     Uses wagmi useSwitchChain; if the chain is unknown, wagmi falls back
#     to wallet_addEthereumChain from the arcTestnet definition. This removes
#     the manual "add Arc chain" step you hit.
#
#  B) A second pay option: "Pay with AfriFX (Circle) wallet".
#     Reuses sendUsdc() from useCircleTx — the SAME primitive Send/P2P/Bridge
#     use. Plain USDC transfer (NO memo): a Circle wallet is a smart-contract
#     account, and Arc's Memo precompile reverts when called from an SCA
#     (verified on-chain in the P2P migration). The ref/memo metadata is still
#     persisted to the API via the existing /pay PATCH + createPayment, so
#     nothing operational is lost — only the on-chain annotation.
#     If there's no live Circle session, we send the payer to /signin with a
#     returnTo back to this invoice (new users get an account+wallet made
#     automatically, as sign-in already does).
#
#  C) /signin honors ?returnTo= so an invoice payer returns to the invoice
#     (instead of the dashboard) after signing in. New users are nudged to
#     finish profile setup AFTER paying, not before.
#
# Depends on feat-public-invoice-qr.sh + fix-invoice-connect-button.sh having run.
# Run from repo root:  cd ~/AfriFX && bash feat-invoice-circle-and-arc-switch.sh
# ============================================================
set -euo pipefail

ROOT="$(pwd)"; WEB="$ROOT/afrifx-web"
[ -d "$WEB" ] || { echo "ERROR: run from AfriFX repo root"; exit 1; }
cd "$WEB"

INNER="components/invoice/InvoicePayInner.tsx"
SIGNIN="app/(auth)/signin/page.tsx"
for f in "$INNER" "$SIGNIN" hooks/useCircleTx.ts lib/arc-chain.ts; do
  [ -f "$f" ] || { echo "ERROR: missing $f (run the earlier scripts first)"; exit 1; }
done

# ---------------------------------------------------------------
# A) Arc-switch helper (new module)
# ---------------------------------------------------------------
echo "→ 1/5  Adding ensureArcChain helper…"
if [ ! -f lib/ensure-arc-chain.ts ]; then
cat > lib/ensure-arc-chain.ts <<'TS'
'use client'
// Ensure an external (wagmi/injected) wallet is on Arc before an on-chain action.
// Circle wallets don't need this — the backend runs each call on the named chain —
// so this is only for the MetaMask/injected path.
import type { Config } from 'wagmi'
import { switchChain } from 'wagmi/actions'
import { arcTestnet } from '@/lib/arc-chain'

// wagmi's switchChain asks the wallet to switch; when the chain is unknown to
// the wallet, wagmi issues wallet_addEthereumChain using the chain definition
// registered in wagmiConfig (arcTestnet). So a single call both ADDS and
// SWITCHES — the payer no longer has to add Arc manually.
export async function ensureArcChain(config: Config, currentChainId?: number): Promise<void> {
  if (currentChainId === arcTestnet.id) return
  await switchChain(config, { chainId: arcTestnet.id })
}
TS
echo "  ✓ lib/ensure-arc-chain.ts"
else
echo "  • lib/ensure-arc-chain.ts exists (skip)"
fi

# ---------------------------------------------------------------
# B) Wire Arc-switch into the external-wallet handlePay
# ---------------------------------------------------------------
echo "→ 2/5  Wiring Arc auto-switch into the external-wallet pay path…"
if ! grep -q "ensureArcChain" "$INNER"; then
  # import (after the arc-chain import which we know exists)
  perl -0pi -e "s/(import \{ arcTestnet \} from '\@\/lib\/arc-chain'\n)/\$1import { ensureArcChain } from '\@\/lib\/ensure-arc-chain'\n/s" "$INNER"
  # add useConfig + useChainId to the EXISTING wagmi import (no duplicate import line)
  perl -0pi -e "s/import \{ useAccount, useWriteContract, usePublicClient \} from 'wagmi'/import { useAccount, useWriteContract, usePublicClient, useConfig, useChainId } from 'wagmi'/s" "$INNER"
  # hooks inside the component: add config + chainId next to the existing wagmi hooks
  perl -0pi -e "s/(const \{ writeContractAsync \}\s+= useWriteContract\(\)\n)/\$1  const wagmiConfig                      = useConfig()\n  const currentChainId                   = useChainId()\n/s" "$INNER"
  # ensure Arc right after entering the try in handlePay (before parseUnits)
  perl -0pi -e "s/(let hash: \`0x\\\$\{string\}\` \| null = null\n\n    try \{\n)/\$1      \/\/ Make sure the external wallet is on Arc (adds the chain if missing).\n      await ensureArcChain(wagmiConfig, currentChainId)\n\n/s" "$INNER"
  if grep -q "ensureArcChain(wagmiConfig" "$INNER"; then echo "  ✓ Arc switch wired into handlePay"; else echo "  ✗ handlePay anchor not matched"; exit 1; fi
else
  echo "  • Arc switch already wired (skip)"
fi

# ---------------------------------------------------------------
# C) Circle-pay handler module (keeps the big component lean)
# ---------------------------------------------------------------
echo "→ 3/5  Adding useInvoiceCirclePay hook (reuses sendUsdc)…"
if [ ! -f hooks/useInvoiceCirclePay.ts ]; then
cat > hooks/useInvoiceCirclePay.ts <<'TS'
'use client'
// Pay an invoice from the user's CIRCLE (user-controlled) wallet.
// Reuses sendUsdc (challenge → device approval → on-chain confirm) — the same
// primitive Send/P2P/Bridge use. Plain transfer, no memo (Circle SCA can't use
// Arc's Memo precompile). Ref metadata is persisted to the API by the caller.
import { useState } from 'react'
import { getSigningSession, sendUsdc, NeedsReauthError } from '@/hooks/useCircleTx'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface CirclePayResult { txHash?: string; state: string }

export function hasCircleSession(): boolean {
  return !!getSigningSession()
}

export function useInvoiceCirclePay() {
  const [step, setStep] = useState<string | null>(null)

  // Returns { needsSignin: true } when there is no live Circle session, so the
  // caller can redirect to /signin?returnTo=<invoice>. Otherwise runs the pay.
  async function payWithCircle(
    to: string,
    usdcAmount: number,
  ): Promise<{ needsSignin: true } | { needsSignin: false; result: CirclePayResult }> {
    if (!hasCircleSession()) return { needsSignin: true }
    try {
      const result = await sendUsdc(
        { to, amount: usdcAmount.toFixed(6) },
        (m) => setStep(m),
      )
      return { needsSignin: false, result }
    } catch (e) {
      if (e instanceof NeedsReauthError) return { needsSignin: true }
      throw e
    } finally {
      setStep(null)
    }
  }

  return { payWithCircle, step }
}
TS
echo "  ✓ hooks/useInvoiceCirclePay.ts"
else
echo "  • hooks/useInvoiceCirclePay.ts exists (skip)"
fi

# ---------------------------------------------------------------
# D) /signin returnTo support
# ---------------------------------------------------------------
echo "→ 4/5  Teaching /signin to honor ?returnTo=…"
if ! grep -q "returnTo" "$SIGNIN"; then
  # import useSearchParams alongside useRouter
  perl -0pi -e "s/import \{ useRouter \} from 'next\/navigation'/import { useRouter, useSearchParams } from 'next\/navigation'/s" "$SIGNIN"
  # read the param inside the component (right after const router = useRouter())
  perl -0pi -e "s/(const router = useRouter\(\)\n)/\$1  const returnTo = useSearchParams().get('returnTo') || '\/dashboard'\n/s" "$SIGNIN"
  # already-signed-in redirect: honor returnTo
  perl -0pi -e "s/if \(!loading && account\) router\.replace\('\/dashboard'\)/if (!loading \&\& account) router.replace(returnTo)/s" "$SIGNIN"
  # success redirect: honor returnTo
  perl -0pi -e "s/(\/\/ ProfileGuard sends anyone without a profile to \/profile\/setup,\n\s*\/\/ so the dashboard is the right destination either way\.\n\s*)router\.push\('\/dashboard'\)/\$1router.push(returnTo)/s" "$SIGNIN"
  # verify all three
  if grep -q "returnTo = useSearchParams" "$SIGNIN" && grep -q "router.replace(returnTo)" "$SIGNIN" && grep -q "router.push(returnTo)" "$SIGNIN"; then
    echo "  ✓ /signin honors returnTo (already-authed + post-signin)"
    # useSearchParams() requires a Suspense boundary or `next build` fails.
    # Rename the page component to SignInInner and wrap it in Suspense.
    if ! grep -q "function SignInInner" "$SIGNIN"; then
      perl -0pi -e "s/import \{ useState, useEffect, useCallback \} from 'react'/import { useState, useEffect, useCallback, Suspense } from 'react'/s" "$SIGNIN"
      perl -0pi -e "s/export default function SignInPage\(\) \{/function SignInInner() {/s" "$SIGNIN"
      cat >> "$SIGNIN" <<'TSX'

export default function SignInPage() {
  return (
    <Suspense fallback={null}>
      <SignInInner />
    </Suspense>
  )
}
TSX
      if grep -q "function SignInInner" "$SIGNIN" && grep -q "export default function SignInPage" "$SIGNIN"; then
        echo "  ✓ /signin wrapped in Suspense (build-safe useSearchParams)"
      else
        echo "  ✗ Suspense wrap failed — review $SIGNIN"; exit 1
      fi
    else
      echo "  • /signin already Suspense-wrapped (skip)"
    fi
  else
    echo "  ✗ one or more /signin anchors did not match — review $SIGNIN"; exit 1
  fi
else
  echo "  • /signin already has returnTo (skip)"
fi

echo "→ 5/6  (Circle pay UI is inserted in step 6 below.)"

echo
echo "──────────────────────────────────────────────"
echo "Applied. Files touched:"
echo "  NEW : lib/ensure-arc-chain.ts"
echo "  NEW : hooks/useInvoiceCirclePay.ts"
echo "  EDIT: $INNER   (Arc auto-switch)"
echo "  EDIT: $SIGNIN  (returnTo)"
echo
echo "  (Circle-pay UI auto-inserted in step 6 — verify with tsc/build.)"

# ---------------------------------------------------------------
# E) Insert the Circle-pay UI + handler into InvoicePayInner (verified edit)
# ---------------------------------------------------------------
echo
echo "→ 6/6  Inserting the 'Pay with AfriFX (Circle) wallet' option…"
if ! grep -q "useInvoiceCirclePay" "$INNER"; then
  # imports: hook + router
  perl -0pi -e "s/(import \{ useParams \} from 'next\/navigation'\n)/import { useParams, useRouter } from 'next\/navigation'\n/s" "$INNER"
  perl -0pi -e "s/(import \{ ensureArcChain \} from '\@\/lib\/ensure-arc-chain'\n)/\$1import { useInvoiceCirclePay, hasCircleSession } from '\@\/hooks\/useInvoiceCirclePay'\n/s" "$INNER"

  # hooks inside component: router + circle pay
  perl -0pi -e "s/(const \{ ref \}\s+= useParams\(\)\n)/\$1  const router                          = useRouter()\n  const { payWithCircle, step: circleStep } = useInvoiceCirclePay()\n/s" "$INNER"

  # handler: add handlePayWithCircle right before the return statement of PayContent.
  # Anchor on the closing of handlePay + the JSX return. We insert after handlePay's
  # final closing brace, which is immediately before "  return (".
  perl -0pi -e "s/(\n  return \(\n    <div className=\"mx-auto max-w-lg\">)/\n  async function handlePayWithCircle() {\n    if (!invoice || usdcAmount <= 0) return\n    setStatus('submitting'); setErrMsg(null); setTxHash(null)\n    try {\n      const target = invoice.creator_address as string\n      const outcome = await payWithCircle(target, usdcAmount)\n      if (outcome.needsSignin) {\n        \/\/ No live Circle session: send them to sign in, then back here.\n        router.push('\/signin?returnTo=' + encodeURIComponent('\/pay\/' + invoice.memo_ref))\n        return\n      }\n      const hash = outcome.result.txHash as \`0x\\\${string}\` | undefined\n      if (hash) setTxHash(hash)\n      \/\/ Persist invoice-paid + payment record (same as the external path).\n      await fetch(\`\\\${API}\/invoices\/ref\/\\\${invoice.memo_ref}\/pay\`, {\n        method: 'PATCH', headers: { 'Content-Type': 'application\/json' },\n        body: JSON.stringify({ txHash: hash ?? null, payerAddress: null, usdcAmount }),\n      }).catch(() => {})\n      await createPayment.mutateAsync({\n        recipientAddress: invoice.creator_address,\n        amount: usdcAmount, currency: 'USDC',\n        description: invoice.description ?? invoice.memo_ref,\n        invoiceRef: invoice.memo_ref, arcTxHash: hash,\n      } as any).catch(() => {})\n      setStatus('success')\n    } catch (err: any) {\n      setStatus('error'); setErrMsg(err?.shortMessage ?? err?.message ?? 'Circle payment failed')\n    }\n  }\n\$1/s" "$INNER"
  if grep -q "handlePayWithCircle" "$INNER"; then echo "  ✓ Circle handler inserted"; else echo "  ✗ handler anchor not matched"; exit 1; fi

  # UI: add a Circle button + divider into the !isConnected branch, after the
  # external-wallet helper text's closing </p>. Anchor on the unique sub-text.
  perl -0pi -e "s{(MetaMask, WalletConnect or any injected wallet holding USDC on Arc\. No account needed\.\s*</p>)}{\$1\n            <div className=\"my-3 flex items-center gap-2\">\n              <div className=\"h-px flex-1 bg-app-border\" />\n              <span className=\"text-[10px] text-app-muted\">or</span>\n              <div className=\"h-px flex-1 bg-app-border\" />\n            </div>\n            <Button variant=\"secondary\" className=\"w-full\" onClick={handlePayWithCircle}>\n              {hasCircleSession() ? 'Pay with your AfriFX wallet' : 'Sign in to pay with AfriFX wallet'}\n            </Button>\n            <p className=\"mt-2 text-[10px] text-app-muted\">\n              Use your Circle-powered AfriFX wallet. New here? Signing in creates one for you.\n            </p>}s" "$INNER"
  if grep -q "Pay with your AfriFX wallet" "$INNER"; then echo "  ✓ Circle pay button added to the pay page"; else echo "  ✗ UI anchor not matched"; exit 1; fi
else
  echo "  • Circle pay UI already present (skip)"
fi

echo
echo "Done with Circle UI. Re-run of the standard build/verify still required."
