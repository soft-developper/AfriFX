#!/usr/bin/env bash
# ============================================================================
# Phase 5a — Multi-chain wallet provisioning at sign-up
#
# WHY
#   A CCTP bridge burns USDC on the source chain and MINTS it on the
#   destination chain. The mint is a contract call the user's Circle wallet
#   has to sign ON THE DESTINATION CHAIN, so the wallet must already exist
#   there. Circle user-controlled (SCA) wallets share ONE address across EVM
#   chains — unified addressing is automatic when the user token is passed —
#   but each chain still has to be added once before the wallet can act on it.
#
#   Today sign-up only creates the wallet on Arc. This phase adds the CCTP
#   bridge chains (Base/Eth/Arbitrum/Polygon sepolias) right after the Arc
#   wallet is created, so a later bridge can mint without pausing to add a
#   chain mid-transfer. This is the prerequisite for the Bridge migration
#   (Phase 5b); it ships and is tested on its own first.
#
# WHAT IT CHANGES  (3 files)
#   afrifx-api/src/services/circleWallets.ts
#       + CCTP_BRIDGE_CHAINS constant (env-overridable)
#       + missingBridgeChains()      (pure, testable)
#       + addUserWalletChains()      (POST /v1/w3s/user/wallets, batch)
#   afrifx-api/src/routes/auth.ts
#       + import addUserWalletChains
#       + POST /auth/wallet/add-chains  route
#   afrifx-web/hooks/useWalletProvisioning.ts
#       + addBridgeChains() helper
#       + call it after the wallet syncs (best-effort, non-fatal)
#
# SAFETY
#   Idempotent: re-running detects the markers and skips. Verifies each edit
#   landed. Then typechecks both apps and runs the web build. Nothing is
#   recorded on the account by the new route; a failure to add chains leaves
#   the Arc wallet fully usable, so sign-in never breaks.
#
# USAGE
#   bash phase5a-multichain-provisioning.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$ROOT/afrifx-api"
WEB="$ROOT/afrifx-web"

SVC="$API/src/services/circleWallets.ts"
AUTH="$API/src/routes/auth.ts"
PROV="$WEB/hooks/useWalletProvisioning.ts"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  ~\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

for f in "$SVC" "$AUTH" "$PROV"; do
  [ -f "$f" ] || die "Expected file not found: $f (run this from the repo root)"
done

# Python does the edits: exact-anchor string replacement, so it can't drift and
# is safe to re-run. Each edit checks for its own marker and no-ops if present.
python3 - "$SVC" "$AUTH" "$PROV" <<'PYEOF'
import io, sys

svc_path, auth_path, prov_path = sys.argv[1], sys.argv[2], sys.argv[3]

def read(p):
    with io.open(p, encoding='utf-8') as f:
        return f.read()

def write(p, s):
    with io.open(p, 'w', encoding='utf-8') as f:
        f.write(s)

def apply(path, marker, anchor, replacement, label):
    s = read(path)
    if marker in s:
        print("  ~ %s (already applied)" % label)
        return
    if anchor not in s:
        sys.exit("  x %s: anchor not found — file differs from expected baseline" % label)
    if s.count(anchor) != 1:
        sys.exit("  x %s: anchor matched %d times, expected 1" % (label, s.count(anchor)))
    write(path, s.replace(anchor, replacement))
    print("  + %s" % label)

# ── 1. circleWallets.ts: CCTP_BRIDGE_CHAINS constant ────────────────────────
svc_anchor_const = (
    "export const PRIMARY_BLOCKCHAIN = process.env.CIRCLE_BLOCKCHAIN ?? 'ARC-TESTNET'\n"
    "\n"
    "/** Circle's code for \"this user already has a wallet\". Not an error for us. */\n"
    "const ALREADY_INITIALIZED = 155106"
)
svc_repl_const = (
    "export const PRIMARY_BLOCKCHAIN = process.env.CIRCLE_BLOCKCHAIN ?? 'ARC-TESTNET'\n"
    "\n"
    "/**\n"
    " * The extra chains a wallet needs beyond its primary (Arc) one so that\n"
    " * CCTP bridging can MINT on the destination.\n"
    " *\n"
    " * WHY THIS EXISTS\n"
    " * A bridge burns on the source chain and mints on the destination. The mint\n"
    " * is a contract call the user's wallet has to sign ON THE DESTINATION CHAIN,\n"
    " * so the wallet must exist there first. Circle user-controlled wallets share\n"
    " * ONE address across EVM chains (unified addressing is automatic when the\n"
    " * user token is passed), but each chain still has to be added once before\n"
    " * the wallet can act on it.\n"
    " *\n"
    " * We add them all at sign-up so bridging is seamless later, rather than\n"
    " * deriving a chain mid-bridge while the user waits. Arc itself is created by\n"
    " * initializeUserWallet and is deliberately NOT repeated here.\n"
    " *\n"
    " * Testnet chain codes are Circle's own enum values (note Polygon Amoy is\n"
    " * MATIC-AMOY, not \"polygon\"). Override via env for mainnet without a code\n"
    " * change.\n"
    " */\n"
    "export const CCTP_BRIDGE_CHAINS: string[] =\n"
    "  (process.env.CIRCLE_BRIDGE_CHAINS ?? 'BASE-SEPOLIA,ETH-SEPOLIA,ARB-SEPOLIA,MATIC-AMOY')\n"
    "    .split(',')\n"
    "    .map(s => s.trim().toUpperCase())\n"
    "    .filter(Boolean)\n"
    "\n"
    "/** Circle's code for \"this user already has a wallet\". Not an error for us. */\n"
    "const ALREADY_INITIALIZED = 155106"
)
apply(svc_path, "CCTP_BRIDGE_CHAINS", svc_anchor_const, svc_repl_const,
      "circleWallets.ts: CCTP_BRIDGE_CHAINS constant")

# ── 2. circleWallets.ts: missingBridgeChains + addUserWalletChains ──────────
# Anchor on the close of pickPrimaryWallet only (no box-drawing chars, whose
# exact glyph count is easy to mismatch); insert the new functions right after.
svc_anchor_fns = (
    "  const onChain = usable.find(\n"
    "    w => String(w.blockchain).toUpperCase() === blockchain.toUpperCase())\n"
    "  return onChain ?? usable[0]\n"
    "}\n"
)
svc_repl_fns = (
    "  const onChain = usable.find(\n"
    "    w => String(w.blockchain).toUpperCase() === blockchain.toUpperCase())\n"
    "  return onChain ?? usable[0]\n"
    "}\n"
    "\n"
    "/**\n"
    " * Which of the CCTP bridge chains this user does NOT yet have a wallet on.\n"
    " *\n"
    " * Pure and exported so it can be tested without touching the network. Only\n"
    " * chains missing from the user's current wallet list are returned, so calling\n"
    " * addUserWalletChains repeatedly (e.g. a signup that was retried) never asks\n"
    " * Circle to recreate chains that already exist.\n"
    " */\n"
    "export function missingBridgeChains(\n"
    "  wallets: CircleWallet[], want: string[] = CCTP_BRIDGE_CHAINS,\n"
    "): string[] {\n"
    "  const have = new Set(wallets.map(w => String(w.blockchain).toUpperCase()))\n"
    "  return want.map(c => c.toUpperCase()).filter(c => !have.has(c))\n"
    "}\n"
    "\n"
    "/**\n"
    " * Add the CCTP bridge chains to an already-initialized user's wallet.\n"
    " *\n"
    " * Returns a challengeId the browser must execute (the user approves once,\n"
    " * as with any wallet action), or null when every chain already exists so the\n"
    " * caller can skip straight past it.\n"
    " *\n"
    " * Circle creates the same address on each EVM chain automatically because we\n"
    " * pass the user token; we only list the chains still missing.\n"
    " */\n"
    "export async function addUserWalletChains(userToken: string): Promise<\n"
    "  { challengeId: string } | { challengeId: null }\n"
    "> {\n"
    "  const existing = await listUserWallets(userToken)\n"
    "  const missing  = missingBridgeChains(existing)\n"
    "  if (!missing.length) return { challengeId: null }\n"
    "\n"
    "  const data = await circleFetch('/v1/w3s/user/wallets', userToken, {\n"
    "    method: 'POST',\n"
    "    body:   JSON.stringify({\n"
    "      idempotencyKey: randomUUID(),\n"
    "      accountType:    'SCA',\n"
    "      blockchains:    missing,\n"
    "    }),\n"
    "  })\n"
    "  const challengeId = data?.challengeId\n"
    "  // No challengeId can come back if Circle decides there is nothing to do;\n"
    "  // treat that the same as \"already present\" rather than failing.\n"
    "  return challengeId ? { challengeId: String(challengeId) } : { challengeId: null }\n"
    "}\n"
)
apply(svc_path, "export async function addUserWalletChains", svc_anchor_fns, svc_repl_fns,
      "circleWallets.ts: missingBridgeChains + addUserWalletChains")

# ── 3. auth.ts: import addUserWalletChains ─────────────────────────────────
auth_anchor_imp = (
    "import {\n"
    "  initializeUserWallet, listUserWallets, pickPrimaryWallet,\n"
    "  getPrimaryWalletId, getTokenId, createTransfer, getTransaction, findRecentTransfer,\n"
    "} from '../services/circleWallets'"
)
auth_repl_imp = (
    "import {\n"
    "  initializeUserWallet, listUserWallets, pickPrimaryWallet, addUserWalletChains,\n"
    "  getPrimaryWalletId, getTokenId, createTransfer, getTransaction, findRecentTransfer,\n"
    "} from '../services/circleWallets'"
)
apply(auth_path, "addUserWalletChains,", auth_anchor_imp, auth_repl_imp,
      "auth.ts: import addUserWalletChains")

# ── 4. auth.ts: /wallet/add-chains route ───────────────────────────────────
# Anchor on the close of the /wallet/sync handler (the 'read your wallet'
# catch is unique); insert the new route right after, before the box-drawn
# TRANSACTIONS header, which we leave untouched.
auth_anchor_route = (
    "    const e = err as CircleAuthError\n"
    "    res.status(e.status ?? 502).json({ error: e.message ?? 'Could not read your wallet' })\n"
    "  }\n"
    "})\n"
)
auth_repl_route = (
    "    const e = err as CircleAuthError\n"
    "    res.status(e.status ?? 502).json({ error: e.message ?? 'Could not read your wallet' })\n"
    "  }\n"
    "})\n"
    "\n"
    "// POST /auth/wallet/add-chains   { userToken }   (signed in)\n"
    "//\n"
    "// Adds the CCTP bridge chains to the user's wallet so a bridge can MINT on\n"
    "// the destination. Returns a challengeId the browser executes (one approval),\n"
    "// or challengeId: null when every chain already exists. This is provisioning\n"
    "// only - it records nothing on the account and the wallet stays usable on Arc\n"
    "// whether or not it succeeds.\n"
    "router.post('/wallet/add-chains', requireAccount, async (req, res) => {\n"
    "  const { userToken } = req.body ?? {}\n"
    "  if (!userToken) return res.status(400).json({ error: 'userToken is required' })\n"
    "\n"
    "  try {\n"
    "    const result = await addUserWalletChains(String(userToken))\n"
    "    res.json(result)\n"
    "  } catch (err: any) {\n"
    "    const e = err as CircleAuthError\n"
    "    res.status(e.status ?? 502).json({ error: e.message })\n"
    "  }\n"
    "})\n"
)
apply(auth_path, "/wallet/add-chains", auth_anchor_route, auth_repl_route,
      "auth.ts: /wallet/add-chains route")

# ── 5. useWalletProvisioning.ts: call addBridgeChains after sync ───────────
prov_anchor_call = (
    "    if (res.ok && data.ready) {\n"
    "      const token = getToken()\n"
    "      if (token) persistSession(token, data.account as Account)\n"
    "      return { account: data.account as Account, blockchain: data.blockchain }\n"
    "    }"
)
prov_repl_call = (
    "    if (res.ok && data.ready) {\n"
    "      const token = getToken()\n"
    "      if (token) persistSession(token, data.account as Account)\n"
    "\n"
    "      // Add the CCTP bridge chains so a future bridge can mint on the\n"
    "      // destination. Best-effort: the Arc wallet is already live and the\n"
    "      // account is active, so a hiccup here must NOT block sign-in. Bridging\n"
    "      // can add any missing chain on demand later.\n"
    "      await addBridgeChains(userToken, encryptionKey, onStep).catch(() => {})\n"
    "\n"
    "      return { account: data.account as Account, blockchain: data.blockchain }\n"
    "    }"
)
apply(prov_path, "await addBridgeChains(", prov_anchor_call, prov_repl_call,
      "useWalletProvisioning.ts: call addBridgeChains after sync")

# ── 6. useWalletProvisioning.ts: addBridgeChains helper ────────────────────
prov_anchor_fn = (
    "  throw new Error(\n"
    "    'Your wallet is taking longer than usual to appear. It may still be created \\u2014 sign in again in a moment to check.',\n"
    "  )\n"
    "}"
)
prov_repl_fn = (
    "  throw new Error(\n"
    "    'Your wallet is taking longer than usual to appear. It may still be created \\u2014 sign in again in a moment to check.',\n"
    "  )\n"
    "}\n"
    "\n"
    "/**\n"
    " * Add the CCTP bridge chains to the freshly created wallet.\n"
    " *\n"
    " * A bridge mints on the DESTINATION chain, which the user's wallet must\n"
    " * already exist on. Circle gives every EVM chain the same address, but each\n"
    " * one is added once - we do that here, at sign-up, so bridging is seamless\n"
    " * later instead of pausing mid-transfer to add a chain.\n"
    " *\n"
    " * One extra device approval: the server asks Circle to add the chains and\n"
    " * returns a challengeId, the user confirms it in the window, done. When every\n"
    " * chain already exists (a repeated sign-in) the server returns no challenge\n"
    " * and we return immediately.\n"
    " *\n"
    " * Deliberately allowed to throw - the caller treats any failure as non-fatal,\n"
    " * because the Arc wallet already works and missing chains can be added on\n"
    " * demand at bridge time.\n"
    " */\n"
    "export async function addBridgeChains(\n"
    "  userToken: string,\n"
    "  encryptionKey: string,\n"
    "  onStep?: (message: string) => void,\n"
    "): Promise<void> {\n"
    "  const res = await apiFetch('/auth/wallet/add-chains', {\n"
    "    method: 'POST',\n"
    "    body:   JSON.stringify({ userToken }),\n"
    "  })\n"
    "  const data = await res.json().catch(() => ({}))\n"
    "  if (!res.ok) throw new Error(data.error ?? 'Could not add bridge chains')\n"
    "\n"
    "  // No challenge means every chain already exists; nothing to approve.\n"
    "  if (data.challengeId) {\n"
    "    onStep?.('Confirm in the window to enable bridging')\n"
    "    await executeChallenge(data.challengeId, userToken, encryptionKey)\n"
    "  }\n"
    "}"
)
apply(prov_path, "export async function addBridgeChains", prov_anchor_fn, prov_repl_fn,
      "useWalletProvisioning.ts: addBridgeChains helper")

print("edits: done")
PYEOF

say "Verifying markers landed"
grep -q "CCTP_BRIDGE_CHAINS"                 "$SVC"  || die "missing CCTP_BRIDGE_CHAINS in circleWallets.ts"
grep -q "addUserWalletChains"               "$SVC"  || die "missing addUserWalletChains in circleWallets.ts"
grep -q "missingBridgeChains"               "$SVC"  || die "missing missingBridgeChains in circleWallets.ts"
grep -q "/wallet/add-chains"                "$AUTH" || die "missing /wallet/add-chains route in auth.ts"
grep -q "addUserWalletChains,"              "$AUTH" || die "missing addUserWalletChains import in auth.ts"
grep -q "export async function addBridgeChains" "$PROV" || die "missing addBridgeChains in useWalletProvisioning.ts"
grep -q "await addBridgeChains("            "$PROV" || die "addBridgeChains not called in useWalletProvisioning.ts"
ok "all markers present"

# ── Typecheck + build ──────────────────────────────────────────────────────
say "API: npm install + tsc --noEmit"
( cd "$API" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) \
  && ok "afrifx-api typechecks" || die "afrifx-api tsc failed"

say "WEB: npm install + tsc --noEmit + next build"
( cd "$WEB" && npm install --no-audit --no-fund --loglevel=error >/dev/null 2>&1 && npx tsc --noEmit ) \
  && ok "afrifx-web typechecks" || die "afrifx-web tsc failed"
( cd "$WEB" && npm run build >/dev/null 2>&1 ) \
  && ok "afrifx-web builds" || die "afrifx-web build failed"

say "Phase 5a applied and verified."
cat <<'NOTE'

  What shipped
    • Sign-up now adds Base/Eth/Arbitrum/Polygon (sepolia) to the wallet
      after the Arc wallet is created — one extra approval in the Circle
      window. Same address on every chain.
    • New endpoint: POST /auth/wallet/add-chains  { userToken } -> { challengeId | null }
    • Adding chains is best-effort: if it fails, the Arc wallet still works
      and sign-in still completes.

  Configure (optional)
    • CIRCLE_BRIDGE_CHAINS  (api)  default: BASE-SEPOLIA,ETH-SEPOLIA,ARB-SEPOLIA,MATIC-AMOY

  Test locally before pushing
    1. Sign up a brand-new user (Google or email).
    2. Approve BOTH Circle windows (wallet PIN, then the add-chains challenge).
    3. In the Circle console (or GET /v1/w3s/wallets with the user token),
       confirm the user now has wallets on Arc + the four bridge chains,
       all sharing one address.
    4. Sign in again with the same user: no second add-chains prompt should
       appear (every chain already exists -> challengeId null).

  Next: Phase 5b — migrate useBridge / useCompleteBridge to Circle
        contractExecution (burn on source, mint on destination), now that
        the destination wallet is guaranteed to exist.
NOTE
