#!/bin/bash
# ============================================================
# AfriFX -- bridge polish: manual chain switch, light-mode contrast, em-dashes
#
# 1) MANUAL CHAIN SELECTION
#    You were right that auto-switch is unreliable. Two fixes:
#      * A VISIBLE PROMPT + BUTTON on the bridge card whenever your wallet
#        isn't on the selected source chain, so you can fix it BEFORE starting
#        rather than discovering it mid-transfer.
#      * The hook now VERIFIES the switch actually took effect. Some wallets
#        RESOLVE switchChain without changing network, so trusting the promise
#        wasn't enough. If it silently didn't take, you get a clear "select
#        <chain> manually" message instead of a confusing downstream failure.
#      * The destination-switch error now also says your funds are safe and the
#        mint is still owed, because that failure happens AFTER the burn.
#
# 2) LIGHT-MODE CONTRAST
#    "Funds are burned and recorded..." used text-amber-200/70, which is a
#    light-on-dark shade and washed out on light backgrounds. Fixed there and in
#    NINE other places with the same problem (amber/red/emerald 200-300 shades
#    across the bridge and treasury components) by pairing each with a darker
#    light-mode value and keeping the original under dark:.
#
# 3) EM-DASHES -- MY FAULT
#    I reintroduced 94 of them across the Gateway and bridge work, despite the
#    earlier cleanup. All removed using the SAME rules we agreed:
#      placeholders -> hyphen, sentence punctuation -> comma, comments -> space.
#    Also repaired one sentence the removal left reading badly.
#
# 35 files. Delivered as a checksummed tarball because the em-dash sweep
# touches too many files for a paste-in script.
#
# Run from ~/AfriFX with bridge-polish.tar.gz in the same folder:
#     bash bridge-polish.sh
# ============================================================
set -e
EXPECTED="71d9a73e54892c05b4d4dab1e8adb5ed9426b016ed5cbf9d242bd4589411b6f0"
if [ ! -f bridge-polish.tar.gz ]; then
  echo "ERROR: bridge-polish.tar.gz not found in $(pwd)"; exit 1
fi
ACTUAL=$(sha256sum bridge-polish.tar.gz | cut -d' ' -f1)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "ERROR: checksum mismatch (download corrupted)."; exit 1
fi
echo "Checksum OK. Extracting 35 files..."
tar -xzf bridge-polish.tar.gz
echo ""
echo "Done. Verify and deploy:"
echo "  grep -rn '\u2014' afrifx-web --include='*.tsx' --exclude-dir=node_modules | wc -l   # expect 0"
echo "  cd afrifx-web && npx tsc --noEmit && npm run build"
echo "  cd .. && git add -A && git commit -m 'Bridge polish: manual switch, contrast, em-dashes'"
echo "  git push"
