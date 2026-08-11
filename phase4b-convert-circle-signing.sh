# AfriFX — Session Handoff

**Upload this plus a fresh repo zip to the new chat.**

---

## Where we are

Re-engineering AfriFX from wallet-connect to a Web2-first product on Circle
user-controlled wallets. Target rename: Nexum (deferred until after the
re-engineering, decision D5).

**Working end to end, verified in the browser:** sign in with Google or an email
code → Circle SCA wallet provisioned automatically → profile setup → dashboard
with live balance → **Send USDC on Arc, with tx hash and explorer link.**

---

## Delivered (in run order)

| Script | What it did |
|---|---|
| `payroll-multichain.sh` | Payroll pays out on any Gateway chain, not just Arc |
| `phase0-dispute-duty-fix.sh` | Closed 3 privilege bypasses letting off-duty admins settle disputes |
| `phase0-migrations-and-tests.sh` | Versioned migration runner + reconstructed missing baselines; first tests |
| `phase1-identity.sh` | `accounts` + `account_sessions`, Circle-backed auth |
| `phase1-frontend.sh` | Sign-in screens, Circle Web SDK wiring |
| `phase2-wallets.sh` | Wallet provisioning handshake on sign-up |
| `phase3-cutover.sh` | Removed "connect wallet"; 35 files → `useAccountAddress` |
| `fix-payroll-hook.sh` | Fixed a regression the cutover caused |
| `phase3b-single-signin.sh` | Deleted sign-up; one `/signin` door |
| `fix-google-redirect.sh` | Google returns to `/signin`, not the landing page |
| `browse-without-signin.sh` | App browsable signed out |
| `capture-email-on-signin.sh` | Email + name from Google OAuth; welcome mail once |
| `phase4a-send-circle-signing.sh` | **Send signs via Circle challenges** |
| `fix-send-confirmation.sh` | Fixed tx lookup (challengeId ≠ transaction id) |
| `phase4b-convert-circle-signing.sh` | `/convert` via Circle (on-chain Memo dropped) |

Migrations `0001`–`0016`. 85 tests passing (`cd afrifx-api && npm test`).

---

## How signing works now

```
1. server builds it   POST /auth/wallet/tx/transfer  -> challengeId
2. user approves it   sdk.execute(challengeId) on their device
3. server finds it    GET  /auth/wallet/tx/find      -> txHash
```

Nothing is signed on the server. Key files:
- `afrifx-api/src/services/circleWallets.ts` — `createTransfer`, `findRecentTransfer`, `getTokenId`, `pickPrimaryWallet`
- `afrifx-api/src/routes/auth.ts` — all `/auth/*` routes
- `afrifx-web/hooks/useCircleTx.ts` — `sendUsdc`, `NeedsReauthError`

**Three non-obvious things, learned the hard way:**
1. The transfer endpoint returns a **`challengeId`, not a transaction id.** Polling `/transactions/{challengeId}` never resolves — poll the transaction *list* instead.
2. Circle's `userToken` lasts **60 minutes** and every signature needs one, but our session lasts 30 days. Kept in `sessionStorage`; `NeedsReauthError` when expired. Users will need to re-authenticate to sign. This is inherent to user-controlled wallets, not a bug.
3. "Approved but not yet confirmed" is a **normal state**, not an error. UI must say something true in it or it reads as failure while the money has already moved.

---

## Next: Bridge

Still on wagmi: `useBridge`, `useCompleteBridge`, `useGatewaySend`,
`useGatewayDeposit`, `useCorridorSwap`, `useP2P`, `pay/[ref]`,
`PayrollExecuteContent`.

Needs a new **`contractExecution`** capability
(`POST /v1/w3s/user/transactions/contractExecution` with `walletId`,
`contractAddress`, `abiFunctionSignature`, `abiParameters`). That single
addition also unblocks escrow, payroll and invoices — build it once, carefully.

### ⚠ Verify before designing — do not trust training data

Existing wallets are provisioned on **Arc only**
(`initializeUserWallet` passes `blockchains: [PRIMARY_BLOCKCHAIN]`). Circle
won't execute on a chain where the wallet doesn't exist.

**Fetch these live and confirm:**
- `developers.circle.com/wallets/unified-wallet-addressing-evm`
- `developers.circle.com/wallets/account-types`

Specifically check: (1) `/user/initialize` accepts multiple `blockchains`;
(2) user-controlled wallets get unified EVM addressing **automatically** via the
user JWT (the `walletSetId`/`refId` work is developer-controlled only);
(3) whether **Gateway** — already integrated here, and which added ERC-1271
support for smart accounts on 4 Aug 2026 — is a better fit than raw CCTP.
Circle's own multichain guide uses Gateway rather than per-chain minting.

Existing Arc-only wallets would need backfilling onto other chains.

---

## Working agreement

- **All changes as a single bash script** placed in the repo root, writing whole
  files. Then: `npx tsc --noEmit` → `npm run build` → `git add -A && git commit && git push`.
- **Verify byte-for-byte** against a clean unzip of the repo before delivering.
- **Run the API typecheck too** (`cd afrifx-api && npx tsc --noEmit`) — the local
  routine only covers `afrifx-web`, and an `import.meta` error slipped through once.
- **`rm -rf .next`** whenever a route is deleted, or stale generated types break `tsc`.
- ⚠ **Working copies drift.** A whole-file overwrite generated from a stale copy
  silently reverted the payroll multichain work once. Re-check against the
  user's current zip before overwriting any file with prior history.

---

## Naming — don't conflate these

- **Trade** (nav label) currently points at `/convert`. It will eventually point
  at the **fiat on-ramp / off-ramp**, not yet built.
- **Bridge** is the **Circle CCTP bridge**.
- There is no feature called "Trade/Convert".

---

## Open, not blocking

- **Payroll custody (D3)** — platform-held disbursement has real licensing
  weight. Circle's own terms state the developer is solely responsible for
  licensing. An allowance-based design may avoid custody entirely. Needs a
  lawyer before Phase 4 touches payroll.
- **Arc mainnet** not on Circle Wallets' supported list (testnet only). Chain is
  env-configurable (`CIRCLE_BLOCKCHAIN`) so Base is a cheap fallback.
- **Cross-chain Send** still on `useGatewaySend`.
- **Account recovery** never designed. Highest-risk gap before real money.
- **No frontend tests.** 85 tests are all backend.
