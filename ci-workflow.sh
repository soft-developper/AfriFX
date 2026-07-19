#!/bin/bash
# ============================================================
# AfriFX Production Layer 2/4: CI/CD PIPELINE (GitHub Actions)
#
# Before this, NOTHING stood between a bad commit and production -- Vercel and
# Render deploy whatever lands on main. This adds a gate: every push and PR to
# main runs typecheck + build for BOTH apps. If either fails, the run goes red
# (and a PR can be blocked from merging).
#
# Several of the type errors we hit this session would have been caught here
# BEFORE deploy instead of after.
#
# TWO PARALLEL JOBS:
#   api  -> npm ci, tsc --noEmit, npm run build   (build is `tsc`)
#   web  -> npm ci, tsc --noEmit, next lint, next build
#
# Verified locally: both jobs pass on the current tree (0 type errors, both
# builds compile, API emits dist/index.js).
#
# NOTES BAKED IN:
#   * npm ci (not npm install) -- installs EXACT locked versions and fails if
#     package.json and the lockfile disagree. This means the updated
#     package-lock.json from the helmet step MUST be committed, or CI's npm ci
#     will fail. (It's already in your tree if you ran security-headers.sh.)
#   * Node pinned to 20 for reproducibility (repo had no .nvmrc).
#   * Web build-time NEXT_PUBLIC_* vars are set to placeholders in the workflow
#     -- the app code has '' fallbacks, so CI needs NO real secrets.
#   * `next lint` is continue-on-error for now (existing warnings shouldn't
#     block). Flip that to false once lint is clean.
#   * concurrency cancels stale runs when you push again quickly.
#
# Run from ~/AfriFX:  bash ci-workflow.sh
# ============================================================
set -e
echo ""
echo "Adding GitHub Actions CI workflow..."
echo ""

mkdir -p ".github/workflows"
cat > ".github/workflows/ci.yml" << 'AFX_EOF'
name: CI

# Run on every push and PR to main, so a broken commit is caught before it
# reaches Vercel/Render (both of which deploy whatever lands on main).
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

# If you push again while CI is still running on an older commit, cancel the
# stale run — no point building a commit you've already superseded.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  api:
    name: API — typecheck & build
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: afrifx-api
    steps:
      - uses: actions/checkout@v4

      - name: Use Node 20
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: afrifx-api/package-lock.json

      # npm ci is the CI-correct install: it's faster and installs EXACTLY the
      # locked versions, failing if package.json and the lockfile disagree.
      - name: Install
        run: npm ci

      - name: Typecheck
        run: npx tsc --noEmit

      - name: Build
        run: npm run build

  web:
    name: Web — typecheck, lint & build
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: afrifx-web
    # Build-time NEXT_PUBLIC_* vars all have '' fallbacks in code, so the build
    # compiles with placeholders — CI needs no real secrets. Set here so any
    # future strict check has non-empty values to work with.
    env:
      NEXT_PUBLIC_API_URL: https://afrifx-api.onrender.com
      NEXT_PUBLIC_WEB3AUTH_CLIENT_ID: ci-placeholder
      NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID: ci-placeholder
      NEXT_PUBLIC_ARC_RPC_URL: https://rpc.example.invalid
      NEXT_PUBLIC_AFRIFX_EXCHANGE: '0x0000000000000000000000000000000000000000'
      NEXT_PUBLIC_AFRIFX_VAULT: '0x0000000000000000000000000000000000000000'
    steps:
      - uses: actions/checkout@v4

      - name: Use Node 20
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: afrifx-web/package-lock.json

      - name: Install
        run: npm ci

      - name: Typecheck
        run: npx tsc --noEmit

      # Lint is allowed to fail without failing the build for now — flip
      # continue-on-error to false once the existing lint warnings are cleared.
      - name: Lint
        run: npm run lint
        continue-on-error: true

      - name: Build
        run: npm run build
AFX_EOF
echo "  .github/workflows/ci.yml"

echo ""
echo "Done. Now commit and push:"
echo ""
echo "  git add -A"
echo "  git commit -m 'CI: typecheck + build both apps on push/PR'"
echo "  git push"
echo ""
echo "  IMPORTANT: make sure package-lock.json for BOTH apps is committed"
echo "  (git status should show them clean/committed). CI uses 'npm ci', which"
echo "  fails if a lockfile is missing or out of sync with package.json."
echo ""
echo "  ===== AFTER PUSH =====" 
echo "  Open your repo on GitHub -> the 'Actions' tab. You'll see the CI run"
echo "  for your commit. Both jobs (api, web) should go green."
echo ""
echo "  OPTIONAL (recommended): GitHub -> Settings -> Branches -> add a branch"
echo "  protection rule for 'main' requiring the CI checks to pass before merge."
echo "  That's what turns CI from advisory into an actual gate."
