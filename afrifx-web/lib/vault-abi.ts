export const VAULT_P2P_ABI = [
  {
    type: 'function', name: 'createP2POffer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'usdcAmount',        type: 'uint256' },
      { name: 'localCurrency',     type: 'string'  },
      { name: 'localAmount',       type: 'uint256' },
      { name: 'orderType',         type: 'uint8'   },
      { name: 'makerTimerSeconds', type: 'uint256' },
    ],
    outputs: [{ name: 'offerId', type: 'bytes32' }],
  },
  {
    type: 'function', name: 'acceptP2POffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function', name: 'takerConfirm',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function', name: 'makerConfirm',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function', name: 'makerCancelOffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  {
    type: 'function', name: 'getOffer',
    stateMutability: 'view',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [{
      type: 'tuple',
      components: [
        { name: 'offerId',           type: 'bytes32' },
        { name: 'maker',             type: 'address' },
        { name: 'taker',             type: 'address' },
        { name: 'usdcAmount',        type: 'uint256' },
        { name: 'localCurrency',     type: 'string'  },
        { name: 'localAmount',       type: 'uint256' },
        { name: 'rateOffered',       type: 'uint256' },
        { name: 'orderType',         type: 'uint8'   },
        { name: 'makerTimerSeconds', type: 'uint256' },
        { name: 'status',            type: 'uint8'   },
        { name: 'makerConfirmed',    type: 'bool'    },
        { name: 'takerConfirmed',    type: 'bool'    },
      ],
    }],
  },
  {
    type: 'event', name: 'OfferCreated',
    inputs: [
      { name: 'offerId',           type: 'bytes32', indexed: true  },
      { name: 'maker',             type: 'address', indexed: true  },
      { name: 'usdcAmount',        type: 'uint256', indexed: false },
      { name: 'localCurrency',     type: 'string',  indexed: false },
      { name: 'localAmount',       type: 'uint256', indexed: false },
      { name: 'orderType',         type: 'uint8',   indexed: false },
      { name: 'makerTimerSeconds', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event', name: 'OfferAccepted',
    inputs: [
      { name: 'offerId', type: 'bytes32', indexed: true },
      { name: 'taker',   type: 'address', indexed: true },
    ],
  },
  {
    type: 'event', name: 'OfferReleased',
    inputs: [
      { name: 'offerId', type: 'bytes32', indexed: true  },
      { name: 'taker',   type: 'address', indexed: true  },
      { name: 'amount',  type: 'uint256', indexed: false },
    ],
  },
] as const
