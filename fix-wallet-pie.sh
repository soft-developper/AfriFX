#!/bin/bash
# Run from ~/AfriFX:  bash fix-wallet-pie.sh
set -e

cat > /tmp/fix_wallet_pie.py << 'EOF'
import os, sys

path = os.path.expanduser(
    '~/AfriFX/afrifx-web/app/(app)/wallet/WalletContent.tsx'
)
if not os.path.exists(path):
    print(f"❌  File not found: {path}")
    sys.exit(1)

with open(path) as f:
    content = f.read()

# ── Fix 1: pieData with local currency slices ────────────────────
old1 = """  const totalUSD  = (data?.tokens ?? []).reduce((s, t) => s + t.usdValue, 0)
  const escrowUSD = data?.escrow.locked ?? 0
  const grandTotal = totalUSD + escrowUSD

  // Pie chart data
  const pieData = [
    ...( data?.tokens ?? []).map(t => ({
      name:  t.symbol,
      value: t.usdValue,
      color: t.color,
    })),
    ...(escrowUSD > 0 ? [{
      name:  'Escrow',
      value: escrowUSD,
      color: '#F59E0B',
    }] : []),
  ].filter(d => d.value > 0)"""

new1 = """  const totalUSD   = (data?.tokens ?? []).reduce((s, t) => s + t.usdValue, 0)
  const escrowUSD  = data?.escrow.locked ?? 0
  const grandTotal = totalUSD + escrowUSD

  // Local currency colors
  const LOCAL_COLORS: Record<string, string> = {
    NGN: '#16A34A', GHS: '#DC2626',
    KES: '#9333EA', ZAR: '#0891B2', EGP: '#C2410C',
  }

  // Local currency slices — USD equivalent (localAmount / rate = usdcBalance)
  const localSlices = (data?.localEquiv ?? [])
    .map(({ currency, amount, rate }) => ({
      name:  currency,
      value: rate > 0 ? parseFloat((amount / rate).toFixed(2)) : 0,
      color: LOCAL_COLORS[currency] ?? '#6366F1',
    }))
    .filter(d => d.value > 0)

  // Full pie: tokens + escrow + local equivalents
  const pieData = [
    ...(data?.tokens ?? []).map(t => ({
      name: t.symbol, value: t.usdValue, color: t.color,
    })),
    ...(escrowUSD > 0 ? [{ name: 'Escrow', value: escrowUSD, color: '#F59E0B' }] : []),
    ...localSlices,
  ].filter(d => d.value > 0)"""

if old1 in content:
    content = content.replace(old1, new1)
    print("✅  pieData — local currency slices added")
else:
    print("⚠️  pieData pattern not matched — trying partial patch")
    # Try to find and patch just the pieData const
    if "const pieData = [" in content and "localSlices" not in content:
        # Inject localSlices before pieData
        insert = """
  const LOCAL_COLORS: Record<string, string> = {
    NGN: '#16A34A', GHS: '#DC2626',
    KES: '#9333EA', ZAR: '#0891B2', EGP: '#C2410C',
  }
  const localSlices = (data?.localEquiv ?? [])
    .map(({ currency, amount, rate }) => ({
      name:  currency,
      value: rate > 0 ? parseFloat((amount / rate).toFixed(2)) : 0,
      color: LOCAL_COLORS[currency] ?? '#6366F1',
    }))
    .filter(d => d.value > 0)

"""
        content = content.replace("  // Pie chart data\n", insert + "  // Pie chart data\n")
        # Add localSlices to pieData array
        content = content.replace(
            "  ].filter(d => d.value > 0)",
            "    ...localSlices,\n  ].filter(d => d.value > 0)",
            1  # only first occurrence (the pieData one)
        )
        print("✅  Partial patch applied")

# ── Fix 2: Tooltip white text + USD label ────────────────────────
old2 = 'formatter={(v: number, name: string) => [`$${formatAmount(v)}`, name]}'
new2 = 'formatter={(v: number, name: string) => [`$${formatAmount(v)} USD`, name]}'
if old2 in content:
    content = content.replace(old2, new2)
    print("✅  Tooltip formatter — USD label added")

# Ensure tooltip has white text
old3 = """                  <Tooltip
                    contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 11 }}"""
new3 = """                  <Tooltip
                    contentStyle={{ background: '#0F1729', border: '1px solid #1B2B4B', borderRadius: 8, fontSize: 11, color: '#E2E8F0' }}
                    labelStyle={{ color: '#E2E8F0' }}
                    itemStyle={{ color: '#E2E8F0' }}"""
if old3 in content:
    content = content.replace(old3, new3)
    print("✅  Tooltip — white text applied")

# ── Fix 3: Scrollable legend + note ─────────────────────────────
old4 = """              <div className="mt-2 space-y-1.5">
                {pieData.map(d => (
                  <div key={d.name} className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <span className="h-2 w-2 rounded-full" style={{ background: d.color }} />
                      <span className="text-[#64748B]">{d.name}</span>
                    </div>
                    <span className="font-mono text-[#E2E8F0]">${formatAmount(d.value)}</span>
                  </div>
                ))}
              </div>"""

new4 = """              <div className="mt-2 max-h-44 overflow-y-auto space-y-1.5 pr-1">
                {pieData.map(d => (
                  <div key={d.name} className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: d.color }} />
                      <span className="text-[#64748B]">{d.name}</span>
                    </div>
                    <span className="font-mono text-[#E2E8F0]">${formatAmount(d.value)}</span>
                  </div>
                ))}
              </div>
              <p className="mt-2 border-t border-[#1B2B4B] pt-2 text-[10px] text-[#64748B]">
                Local currencies show USD equivalent of your USDC holdings
              </p>"""

if old4 in content:
    content = content.replace(old4, new4)
    print("✅  Legend — scrollable + note added")
else:
    print("⚠️  Legend pattern not matched — skipping")

with open(path, 'w') as f:
    f.write(content)

print("\n✅  WalletContent.tsx saved")
EOF

python3 /tmp/fix_wallet_pie.py
rm /tmp/fix_wallet_pie.py

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Wallet pie chart updated!"
echo ""
echo "  Pie chart now shows:"
echo "  🔵 USDC     — actual USD value"
echo "  🟢 EURC     — USD equivalent"
echo "  🟡 Escrow   — USDC locked in P2P"
echo "  🟢 NGN      — USD equivalent of USDC in NGN terms"
echo "  🔴 GHS      — USD equivalent"
echo "  🟣 KES      — USD equivalent"
echo "  🔵 ZAR      — USD equivalent"
echo "  🟠 EGP      — USD equivalent"
echo ""
echo "  Legend is scrollable for all 8 entries"
echo "  Tooltip shows white text + USD label"
echo "  Note clarifies local = USDC equivalent"
echo "══════════════════════════════════════════════════════"
