// Circle App Kit Unified Balance (Phase 2+)
// Enables USDC bridging from Ethereum/Base → Arc in one UX step.
// Docs: https://docs.arc.io/app-kit/unified-balance

// TODO: install @circle-fin/app-kit and @circle-fin/adapter-viem-v2 for Phase 2
// import { AppKit } from '@circle-fin/app-kit'
// import { viemAdapter } from '@circle-fin/adapter-viem-v2'

export const UNIFIED_BALANCE_PLACEHOLDER = true

/*
Example usage (Phase 2):

const kit = new AppKit()

export async function depositFromBase(walletClient: any, amount: string) {
  return kit.unifiedBalance.deposit({
    from: { adapter: viemAdapter(walletClient), chain: 'Base_Sepolia' },
    amount,
    token: 'USDC',
  })
}

export async function spendOnArc(walletClient: any, recipient: string, amount: string) {
  return kit.unifiedBalance.spend({
    amount,
    from: { adapter: viemAdapter(walletClient) },
    to: {
      adapter: viemAdapter(walletClient),
      chain: 'Arc_Testnet',
      recipientAddress: recipient,
    },
  })
}
*/
