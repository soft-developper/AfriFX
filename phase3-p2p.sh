#!/bin/bash
# ============================================================
# AfriFX Phase 3 — P2P FX Marketplace (Option C)
# Platform-controlled USDC release
# Run from ~/AfriFX:  bash phase3-p2p.sh
# ============================================================
set -e
echo ""
echo "🤝  Building Phase 3 — P2P Marketplace..."
echo ""

# ============================================================
# 1 — Smart contract: add P2P functions to AfriFXVault
# ============================================================
cat > afrifx-contracts/contracts/AfriFXVault.sol << '__EOF__'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IUSDC.sol";

/**
 * @title AfriFXVault
 * @notice Handles two flows:
 *   1. FX conversion — user deposits USDC, backend processes fiat payout
 *   2. P2P marketplace — maker locks USDC in escrow, platform releases to taker
 *
 * P2P flow (Option C — platform controlled):
 *   maker calls createP2POffer()  → USDC locked in contract
 *   taker calls acceptP2POffer()  → offer marked accepted
 *   both confirm off-chain via app UI
 *   platform wallet calls releaseP2POffer() → USDC sent to taker
 *   if dispute: platform calls cancelP2POffer() → USDC returned to maker
 *
 * Arc Testnet:
 *   USDC: 0x3600000000000000000000000000000000000000 (6 decimals ERC-20)
 *   Chain ID: 5042002
 */
contract AfriFXVault is Ownable, ReentrancyGuard, Pausable {

    IUSDC public immutable usdc;

    uint256 public spreadBps = 50;
    uint256 public constant MAX_SPREAD_BPS = 200;

    // ── P2P Offer ────────────────────────────────────────────
    enum OfferStatus { Open, Accepted, Released, Cancelled }

    struct P2POffer {
        bytes32     offerId;
        address     maker;           // who locked USDC
        address     taker;           // who accepted (address(0) if open)
        uint256     usdcAmount;      // USDC locked in escrow (6 decimals)
        string      localCurrency;   // e.g. "NGN"
        uint256     localAmount;     // how much local currency taker sends maker
        uint256     rateOffered;     // USDC per local unit * 1e6
        uint256     expiresAt;       // unix timestamp — auto-cancel after this
        OfferStatus status;
        bool        makerConfirmed;
        bool        takerConfirmed;
    }

    mapping(bytes32 => P2POffer) public offers;
    bytes32[] public openOfferIds;

    uint256 public offerTimeout = 30 minutes;
    uint256 public p2pFeeBps    = 30; // 0.3% platform fee on P2P

    // Events
    event OfferCreated(
        bytes32 indexed offerId,
        address indexed maker,
        uint256 usdcAmount,
        string  localCurrency,
        uint256 localAmount,
        uint256 expiresAt
    );
    event OfferAccepted(bytes32 indexed offerId, address indexed taker);
    event MakerConfirmed(bytes32 indexed offerId);
    event TakerConfirmed(bytes32 indexed offerId);
    event OfferReleased(bytes32 indexed offerId, address indexed taker, uint256 amount);
    event OfferCancelled(bytes32 indexed offerId, string reason);
    event ConversionRequested(address indexed user, uint256 amount, string currency, uint256 ts);
    event FundsWithdrawn(address indexed to, uint256 amount);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IUSDC(_usdc);
    }

    // ── FX Conversion ────────────────────────────────────────

    function requestConversion(
        uint256 amount,
        string calldata targetCurrency
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        usdc.transferFrom(msg.sender, address(this), amount);
        emit ConversionRequested(msg.sender, amount, targetCurrency, block.timestamp);
    }

    // ── P2P Marketplace ──────────────────────────────────────

    /**
     * @notice Maker creates a P2P offer by locking USDC in escrow.
     * @param usdcAmount    USDC to lock (6 decimals)
     * @param localCurrency ISO code e.g. "NGN"
     * @param localAmount   Local currency amount maker wants in return
     */
    function createP2POffer(
        uint256 usdcAmount,
        string calldata localCurrency,
        uint256 localAmount
    ) external nonReentrant whenNotPaused returns (bytes32 offerId) {
        require(usdcAmount > 0, "Amount must be > 0");
        require(localAmount > 0, "Local amount must be > 0");
        require(bytes(localCurrency).length > 0, "Currency required");

        // Pull USDC from maker into vault escrow
        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        // Generate unique offer ID
        offerId = keccak256(abi.encodePacked(
            msg.sender, usdcAmount, localCurrency, block.timestamp, block.prevrandao
        ));

        uint256 rate      = (usdcAmount * 1e6) / localAmount;
        uint256 expiresAt = block.timestamp + offerTimeout;

        offers[offerId] = P2POffer({
            offerId:        offerId,
            maker:          msg.sender,
            taker:          address(0),
            usdcAmount:     usdcAmount,
            localCurrency:  localCurrency,
            localAmount:    localAmount,
            rateOffered:    rate,
            expiresAt:      expiresAt,
            status:         OfferStatus.Open,
            makerConfirmed: false,
            takerConfirmed: false
        });

        openOfferIds.push(offerId);

        emit OfferCreated(offerId, msg.sender, usdcAmount, localCurrency, localAmount, expiresAt);
    }

    /**
     * @notice Taker accepts an open offer.
     */
    function acceptP2POffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Open,       "Offer not open");
        require(offer.maker  != msg.sender,             "Cannot accept own offer");
        require(block.timestamp < offer.expiresAt,      "Offer expired");

        offer.taker  = msg.sender;
        offer.status = OfferStatus.Accepted;

        emit OfferAccepted(offerId, msg.sender);
    }

    /**
     * @notice Maker confirms they sent local currency to taker.
     */
    function makerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.maker  == msg.sender,           "Not the maker");
        offer.makerConfirmed = true;
        emit MakerConfirmed(offerId);
    }

    /**
     * @notice Taker confirms they received local currency from maker.
     */
    function takerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  == msg.sender,           "Not the taker");
        offer.takerConfirmed = true;
        emit TakerConfirmed(offerId);
    }

    /**
     * @notice Platform releases USDC to taker after both confirm.
     *         Only callable by contract owner (platform wallet).
     */
    function releaseP2POffer(bytes32 offerId) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  != address(0),           "No taker");

        // Calculate platform fee
        uint256 fee    = (offer.usdcAmount * p2pFeeBps) / 10_000;
        uint256 payout = offer.usdcAmount - fee;

        offer.status = OfferStatus.Released;

        // Send USDC to taker minus platform fee
        usdc.transfer(offer.taker, payout);

        emit OfferReleased(offerId, offer.taker, payout);
    }

    /**
     * @notice Platform cancels offer and returns USDC to maker.
     *         Used for disputes, timeouts, or fraud.
     */
    function cancelP2POffer(
        bytes32 offerId,
        string calldata reason
    ) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(
            offer.status == OfferStatus.Open ||
            offer.status == OfferStatus.Accepted,
            "Cannot cancel"
        );

        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);

        emit OfferCancelled(offerId, reason);
    }

    /**
     * @notice Auto-expire an offer that passed its deadline.
     *         Anyone can call this to clean up expired offers.
     */
    function expireOffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status   == OfferStatus.Open, "Not open");
        require(block.timestamp > offer.expiresAt,  "Not expired yet");

        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);

        emit OfferCancelled(offerId, "Expired");
    }

    /**
     * @notice Get offer details by ID.
     */
    function getOffer(bytes32 offerId) external view returns (P2POffer memory) {
        return offers[offerId];
    }

    // ── Admin ─────────────────────────────────────────────────

    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        usdc.transfer(to, amount);
        emit FundsWithdrawn(to, amount);
    }

    function setSpreadBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_SPREAD_BPS, "Too high");
        spreadBps = _bps;
    }

    function setP2PFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= 100, "Max 1%");
        p2pFeeBps = _bps;
    }

    function setOfferTimeout(uint256 _seconds) external onlyOwner {
        require(_seconds >= 5 minutes, "Min 5 minutes");
        offerTimeout = _seconds;
    }

    function calcSpread(uint256 amount) public view returns (uint256) {
        return (amount * spreadBps) / 10_000;
    }

    function vaultBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }
}
__EOF__
echo "✅  AfriFXVault.sol — P2P functions added"

# ============================================================
# 2 — Add P2P ABI to frontend
# ============================================================
cat > afrifx-web/lib/vault-abi.ts << '__EOF__'
// AfriFXVault ABI — P2P functions only
// Full ABI generated after: npx hardhat compile

export const VAULT_P2P_ABI = [
  // createP2POffer
  {
    type: 'function',
    name: 'createP2POffer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'usdcAmount',    type: 'uint256' },
      { name: 'localCurrency', type: 'string'  },
      { name: 'localAmount',   type: 'uint256' },
    ],
    outputs: [{ name: 'offerId', type: 'bytes32' }],
  },
  // acceptP2POffer
  {
    type: 'function',
    name: 'acceptP2POffer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  // makerConfirm
  {
    type: 'function',
    name: 'makerConfirm',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  // takerConfirm
  {
    type: 'function',
    name: 'takerConfirm',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [],
  },
  // getOffer
  {
    type: 'function',
    name: 'getOffer',
    stateMutability: 'view',
    inputs: [{ name: 'offerId', type: 'bytes32' }],
    outputs: [{
      type: 'tuple',
      components: [
        { name: 'offerId',        type: 'bytes32'  },
        { name: 'maker',          type: 'address'  },
        { name: 'taker',          type: 'address'  },
        { name: 'usdcAmount',     type: 'uint256'  },
        { name: 'localCurrency',  type: 'string'   },
        { name: 'localAmount',    type: 'uint256'  },
        { name: 'rateOffered',    type: 'uint256'  },
        { name: 'expiresAt',      type: 'uint256'  },
        { name: 'status',         type: 'uint8'    },
        { name: 'makerConfirmed', type: 'bool'     },
        { name: 'takerConfirmed', type: 'bool'     },
      ],
    }],
  },
  // Events
  {
    type: 'event',
    name: 'OfferCreated',
    inputs: [
      { name: 'offerId',       type: 'bytes32', indexed: true  },
      { name: 'maker',         type: 'address', indexed: true  },
      { name: 'usdcAmount',    type: 'uint256', indexed: false },
      { name: 'localCurrency', type: 'string',  indexed: false },
      { name: 'localAmount',   type: 'uint256', indexed: false },
      { name: 'expiresAt',     type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'OfferAccepted',
    inputs: [
      { name: 'offerId', type: 'bytes32', indexed: true },
      { name: 'taker',   type: 'address', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'OfferReleased',
    inputs: [
      { name: 'offerId', type: 'bytes32', indexed: true  },
      { name: 'taker',   type: 'address', indexed: true  },
      { name: 'amount',  type: 'uint256', indexed: false },
    ],
  },
] as const
__EOF__
echo "✅  lib/vault-abi.ts — P2P ABI"

# ============================================================
# 3 — Backend: offers table schema
# ============================================================
cat > afrifx-api/src/db/schema.ts << '__EOF__'
import { sqliteTable, text, integer, real } from 'drizzle-orm/sqlite-core'

export const transactions = sqliteTable('transactions', {
  id:            text('id').primaryKey(),
  walletAddress: text('wallet_address').notNull(),
  fromCurrency:  text('from_currency').notNull(),
  toCurrency:    text('to_currency').notNull(),
  fromAmount:    real('from_amount').notNull(),
  toAmount:      real('to_amount').notNull(),
  spreadFee:     real('spread_fee').notNull(),
  networkFee:    real('network_fee').notNull().default(0.001),
  arcTxHash:     text('arc_tx_hash'),
  memoId:        text('memo_id'),
  reference:     text('reference'),
  corridorId:    text('corridor_id'),
  corridorStep:  integer('corridor_step'),
  status:        text('status').notNull().default('pending'),
  settledAt:     integer('settled_at'),
  createdAt:     integer('created_at').notNull(),
})

export const p2pOffers = sqliteTable('p2p_offers', {
  id:              text('id').primaryKey(),        // bytes32 from contract
  makerAddress:    text('maker_address').notNull(),
  takerAddress:    text('taker_address'),          // null until accepted
  usdcAmount:      real('usdc_amount').notNull(),
  localCurrency:   text('local_currency').notNull(),
  localAmount:     real('local_amount').notNull(),
  rateOffered:     real('rate_offered').notNull(),
  status:          text('status').notNull().default('open'),
  // open | accepted | maker_confirmed | taker_confirmed | released | cancelled
  makerConfirmed:  integer('maker_confirmed').notNull().default(0),
  takerConfirmed:  integer('taker_confirmed').notNull().default(0),
  arcTxHash:       text('arc_tx_hash'),            // createOffer tx
  releaseTxHash:   text('release_tx_hash'),         // release tx
  expiresAt:       integer('expires_at').notNull(),
  createdAt:       integer('created_at').notNull(),
  updatedAt:       integer('updated_at').notNull(),
})

export const fxRates = sqliteTable('fx_rates', {
  id:        integer('id').primaryKey({ autoIncrement: true }),
  pair:      text('pair').notNull(),
  rate:      real('rate').notNull(),
  change24h: real('change_24h').notNull().default(0),
  source:    text('source').notNull(),
  fetchedAt: integer('fetched_at').notNull(),
})

export const users = sqliteTable('users', {
  walletAddress: text('wallet_address').primaryKey(),
  volume30d:     real('volume_30d').notNull().default(0),
  txCount:       integer('tx_count').notNull().default(0),
  createdAt:     integer('created_at').notNull(),
})
__EOF__
echo "✅  db/schema.ts — p2p_offers table added"

# Create p2p_offers table in Turso
echo "  Creating p2p_offers table in Turso..."
turso db shell afrifx "
CREATE TABLE IF NOT EXISTS p2p_offers (
  id              TEXT PRIMARY KEY,
  maker_address   TEXT NOT NULL,
  taker_address   TEXT,
  usdc_amount     REAL NOT NULL,
  local_currency  TEXT NOT NULL,
  local_amount    REAL NOT NULL,
  rate_offered    REAL NOT NULL,
  status          TEXT NOT NULL DEFAULT 'open',
  maker_confirmed INTEGER NOT NULL DEFAULT 0,
  taker_confirmed INTEGER NOT NULL DEFAULT 0,
  arc_tx_hash     TEXT,
  release_tx_hash TEXT,
  expires_at      INTEGER NOT NULL,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);" && echo "  ✅  p2p_offers table created"

# ============================================================
# 4 — Backend: P2P offers routes
# ============================================================
cat > afrifx-api/src/routes/offers.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { p2pOffers } from '../db/schema'
import { eq, desc, sql } from 'drizzle-orm'

const router = Router()

// GET /offers — all open offers (marketplace listing)
router.get('/', async (req, res) => {
  const currency = req.query.currency as string | undefined
  const status   = (req.query.status as string) ?? 'open'
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE status = ${status}
          ${currency ? sql`AND local_currency = ${currency}` : sql``}
          AND expires_at > ${Math.floor(Date.now() / 1000)}
          ORDER BY created_at DESC
          LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows
      : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /offers/my?wallet=0x…  — maker's own offers
router.get('/my', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE LOWER(maker_address) = ${wallet}
             OR LOWER(taker_address) = ${wallet}
          ORDER BY created_at DESC
          LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows
      : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// GET /offers/:id
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows
      : Array.isArray(rows) ? rows : []
    if (!offers.length) return res.status(404).json({ error: 'Not found' })
    res.json(offers[0])
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// POST /offers — record new offer after contract call
router.post('/', async (req, res) => {
  const {
    id, makerAddress, usdcAmount,
    localCurrency, localAmount, rateOffered,
    arcTxHash, expiresAt,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`INSERT INTO p2p_offers
          (id, maker_address, usdc_amount, local_currency, local_amount,
           rate_offered, arc_tx_hash, expires_at, created_at, updated_at)
          VALUES
          (${id}, ${makerAddress.toLowerCase()}, ${usdcAmount},
           ${localCurrency}, ${localAmount}, ${rateOffered},
           ${arcTxHash ?? null}, ${expiresAt}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

// PATCH /offers/:id — update status (accept, confirm, release, cancel)
router.patch('/:id', async (req, res) => {
  const {
    status, takerAddress,
    makerConfirmed, takerConfirmed,
    releaseTxHash,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status          = COALESCE(${status        ?? null}, status),
            taker_address   = COALESCE(${takerAddress  ?? null}, taker_address),
            maker_confirmed = COALESCE(${makerConfirmed ?? null}, maker_confirmed),
            taker_confirmed = COALESCE(${takerConfirmed ?? null}, taker_confirmed),
            release_tx_hash = COALESCE(${releaseTxHash ?? null}, release_tx_hash),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) {
    res.status(500).json({ error: err.message })
  }
})

export default router
__EOF__
echo "✅  routes/offers.ts — full CRUD for P2P offers"

# Register offers route in index.ts
cat > afrifx-api/src/index.ts << '__EOF__'
import express from 'express'
import * as dotenv from 'dotenv'
dotenv.config()

import { corsMiddleware }      from './middleware/cors'
import { rateLimitMiddleware } from './middleware/rateLimit'
import { errorHandler }        from './middleware/errorHandler'
import ratesRouter             from './routes/rates'
import transactionsRouter      from './routes/transactions'
import userRouter              from './routes/user'
import offersRouter            from './routes/offers'
import { startRatePoller }     from './jobs/ratePoller'
import { startEventListener }  from './services/eventListener'

const app  = express()
const PORT = Number(process.env.PORT ?? 4000)

app.use(corsMiddleware)
app.use(express.json())
app.use(rateLimitMiddleware)

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', chain: 'Arc Testnet 5042002', ts: Date.now() })
})

app.use('/rates',        ratesRouter)
app.use('/transactions', transactionsRouter)
app.use('/user',         userRouter)
app.use('/offers',       offersRouter)

app.use(errorHandler)

app.listen(PORT, () => {
  console.log(`\n🚀  AfriFX API running on http://localhost:${PORT}`)
  console.log(`    Chain: Arc Testnet · Chain ID 5042002`)
  startRatePoller()
  startEventListener()
})
__EOF__
echo "✅  index.ts — /offers route registered"

# ============================================================
# 5 — Frontend: useP2P hook
# ============================================================
cat > afrifx-web/hooks/useP2P.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, isAddress } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { VAULT_P2P_ABI } from '@/lib/vault-abi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO = '0x0000000000000000000000000000000000000000'

export function useP2P() {
  const { address } = useAccount()
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)

  const { writeContractAsync } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash: txHash ?? undefined })

  function clearError() { setError(null) }

  // ── Step 1: Approve USDC then create offer ────────────────
  async function createOffer(
    usdcAmount:    number,
    localCurrency: string,
    localAmount:   number,
  ) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }

    setIsLoading(true)
    setError(null)

    try {
      const usdcRaw      = parseUnits(usdcAmount.toFixed(6), USDC_DECIMALS)
      const localRaw     = BigInt(Math.round(localAmount))
      const expiresAt    = Math.floor(Date.now() / 1000) + 1800 // 30 min

      // 1. Approve vault to pull USDC
      await writeContractAsync({
        address:      CONTRACTS.USDC,
        abi:          USDC_ABI,
        functionName: 'approve',
        args:         [vault, usdcRaw],
      })

      // 2. Create offer on-chain — vault pulls USDC into escrow
      const hash = await writeContractAsync({
        address:      vault,
        abi:          VAULT_P2P_ABI,
        functionName: 'createP2POffer',
        args:         [usdcRaw, localCurrency, localRaw],
      })

      setTxHash(hash)

      // 3. Record in backend
      const offerId = `${address}-${Date.now()}` // temp ID until we index event
      await fetch(`${API}/offers`, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id:            offerId,
          makerAddress:  address,
          usdcAmount,
          localCurrency,
          localAmount,
          rateOffered:   usdcAmount / localAmount,
          arcTxHash:     hash,
          expiresAt,
        }),
      })

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Failed'
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  // ── Step 2: Taker accepts offer ───────────────────────────
  async function acceptOffer(offerId: string, onChainId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true)
    setError(null)

    try {
      const hash = await writeContractAsync({
        address:      CONTRACTS.AFRIFX_VAULT,
        abi:          VAULT_P2P_ABI,
        functionName: 'acceptP2POffer',
        args:         [onChainId],
      })

      setTxHash(hash)

      await fetch(`${API}/offers/${offerId}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'accepted', takerAddress: address }),
      })

      return hash
    } catch (err: any) {
      const msg = err?.shortMessage ?? err?.message ?? 'Failed'
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  // ── Step 3a: Maker confirms they sent local currency ──────
  async function makerConfirm(offerId: string, onChainId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true)
    setError(null)
    try {
      const hash = await writeContractAsync({
        address:      CONTRACTS.AFRIFX_VAULT,
        abi:          VAULT_P2P_ABI,
        functionName: 'makerConfirm',
        args:         [onChainId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ makerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  // ── Step 3b: Taker confirms they received local currency ──
  async function takerConfirm(offerId: string, onChainId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true)
    setError(null)
    try {
      const hash = await writeContractAsync({
        address:      CONTRACTS.AFRIFX_VAULT,
        abi:          VAULT_P2P_ABI,
        functionName: 'takerConfirm',
        args:         [onChainId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method:  'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ takerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally {
      setIsLoading(false)
    }
  }

  return {
    createOffer,
    acceptOffer,
    makerConfirm,
    takerConfirm,
    isLoading,
    isSuccess,
    error,
    txHash,
    clearError,
  }
}
__EOF__
echo "✅  hooks/useP2P.ts"

# ============================================================
# 6 — Frontend types: P2POffer
# ============================================================
cat >> afrifx-web/types/index.ts << '__EOF__'

export interface P2POffer {
  id:              string
  maker_address:   string
  taker_address:   string | null
  usdc_amount:     number
  local_currency:  string
  local_amount:    number
  rate_offered:    number
  status:          'open' | 'accepted' | 'released' | 'cancelled'
  maker_confirmed: number
  taker_confirmed: number
  arc_tx_hash:     string | null
  release_tx_hash: string | null
  expires_at:      number
  created_at:      number
  updated_at:      number
}
__EOF__
echo "✅  types/index.ts — P2POffer type added"

# ============================================================
# 7 — Frontend pages: Marketplace
# ============================================================
mkdir -p "afrifx-web/app/(app)/marketplace"
mkdir -p "afrifx-web/app/(app)/marketplace/create"
mkdir -p "afrifx-web/components/p2p"

# Marketplace listing page
cat > "afrifx-web/app/(app)/marketplace/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { useP2P } from '@/hooks/useP2P'
import { Plus, Clock, Zap, ShieldCheck } from 'lucide-react'
import type { P2POffer } from '@/types'

const API      = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function timeLeft(expiresAt: number): string {
  const secs = expiresAt - Math.floor(Date.now() / 1000)
  if (secs <= 0) return 'Expired'
  const mins = Math.floor(secs / 60)
  return mins > 0 ? `${mins}m left` : `${secs}s left`
}

export default function MarketplacePage() {
  const { address }                    = useAccount()
  const [offers,   setOffers]          = useState<P2POffer[]>([])
  const [loading,  setLoading]         = useState(true)
  const [currency, setCurrency]        = useState('all')
  const [accepting, setAccepting]      = useState<string | null>(null)
  const { acceptOffer, error: p2pErr } = useP2P()

  async function load() {
    setLoading(true)
    try {
      const url = currency === 'all'
        ? `${API}/offers`
        : `${API}/offers?currency=${currency}`
      const res  = await fetch(url)
      const data = await res.json()
      setOffers(Array.isArray(data) ? data : [])
    } catch { setOffers([]) }
    finally  { setLoading(false) }
  }

  useEffect(() => { load() }, [currency])

  async function handleAccept(offer: P2POffer) {
    if (!address) return
    setAccepting(offer.id)
    try {
      await acceptOffer(offer.id, offer.id as `0x${string}`)
      await load()
    } catch {}
    finally { setAccepting(null) }
  }

  return (
    <div>
      {/* Header */}
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">P2P Marketplace</h1>
          <p className="text-sm text-[#64748B]">
            Buy USDC directly from other users. USDC held in vault escrow.
          </p>
        </div>
        <Link href="/marketplace/create">
          <Button size="sm">
            <Plus className="h-4 w-4" /> Create offer
          </Button>
        </Link>
      </div>

      {/* Trust badges */}
      <div className="mb-6 flex gap-3">
        {[
          { icon: ShieldCheck, label: 'USDC in escrow' },
          { icon: Zap,         label: 'Arc settlement' },
          { icon: Clock,       label: '30 min timeout' },
        ].map(({ icon: Icon, label }) => (
          <div key={label} className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] bg-[#0F1729] px-3 py-1.5 text-xs text-[#64748B]">
            <Icon className="h-3.5 w-3.5 text-[#378ADD]" />
            {label}
          </div>
        ))}
      </div>

      {/* Currency filter */}
      <div className="mb-4 flex gap-2">
        {['all', 'NGN', 'GHS', 'KES', 'ZAR', 'EGP'].map((c) => (
          <button
            key={c}
            onClick={() => setCurrency(c)}
            className={`rounded-full px-3 py-1 text-xs transition-colors
              ${currency === c
                ? 'bg-[#378ADD] text-white'
                : 'border border-[#1B2B4B] text-[#64748B] hover:text-[#E2E8F0]'}`}
          >
            {c === 'all' ? 'All' : `${CURRENCY_FLAG[c]} ${c}`}
          </button>
        ))}
      </div>

      {/* Offers list */}
      {loading && (
        <div className="space-y-2">
          {[1,2,3].map(i => (
            <div key={i} className="h-24 animate-pulse rounded-xl bg-[#0F1729]" />
          ))}
        </div>
      )}

      {!loading && offers.length === 0 && (
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-10 text-center">
          <p className="text-sm text-[#64748B]">No open offers for this currency.</p>
          <Link href="/marketplace/create">
            <Button variant="outline" className="mt-4" size="sm">
              <Plus className="h-4 w-4" /> Be the first to create one
            </Button>
          </Link>
        </div>
      )}

      <div className="space-y-3">
        {offers.map((offer) => {
          const isOwn    = address?.toLowerCase() === offer.maker_address.toLowerCase()
          const rate     = offer.rate_offered
          const expired  = offer.expires_at < Math.floor(Date.now() / 1000)

          return (
            <div
              key={offer.id}
              className="flex items-center gap-4 rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4"
            >
              {/* Currency */}
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#080D1B] text-xl">
                {CURRENCY_FLAG[offer.local_currency] ?? '🌍'}
              </div>

              {/* Details */}
              <div className="flex-1">
                <div className="flex items-center gap-2">
                  <p className="font-medium text-[#E2E8F0]">
                    {offer.local_amount.toLocaleString()} {offer.local_currency}
                    <span className="mx-1.5 text-[#64748B]">→</span>
                    {offer.usdc_amount.toFixed(2)} USDC
                  </p>
                  {isOwn && <Badge variant="arc">Your offer</Badge>}
                </div>
                <div className="mt-0.5 flex items-center gap-3 text-xs text-[#64748B]">
                  <span>Rate: {rate.toFixed(6)} USDC/{offer.local_currency}</span>
                  <span className="flex items-center gap-1">
                    <Clock className="h-3 w-3" />
                    {timeLeft(offer.expires_at)}
                  </span>
                </div>
              </div>

              {/* Action */}
              <div className="shrink-0">
                {isOwn ? (
                  <Badge variant="warning">Listed</Badge>
                ) : expired ? (
                  <Badge variant="danger">Expired</Badge>
                ) : (
                  <ClientOnly>
                    <Button
                      size="sm"
                      onClick={() => handleAccept(offer)}
                      disabled={!address || accepting === offer.id}
                    >
                      {accepting === offer.id ? 'Accepting…' : 'Accept offer'}
                    </Button>
                  </ClientOnly>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {p2pErr && (
        <div className="mt-4 rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
          {p2pErr}
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  app/(app)/marketplace/page.tsx"

# Create offer page
cat > "afrifx-web/app/(app)/marketplace/create/page.tsx" << '__EOF__'
'use client'
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, ShieldCheck, Info } from 'lucide-react'
import Link from 'next/link'

const CURRENCIES = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

export default function CreateOfferPage() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [usdcAmount,    setUsdcAmount]    = useState('')
  const [localCurrency, setLocalCurrency] = useState('NGN')
  const [localAmount,   setLocalAmount]   = useState('')
  const [submitted,     setSubmitted]     = useState(false)

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  const impliedRate = usdcAmount && localAmount
    ? parseFloat(localAmount) / parseFloat(usdcAmount)
    : 0

  const rateVsMarket = marketRate > 0 && impliedRate > 0
    ? ((impliedRate - marketRate) / marketRate) * 100
    : 0

  async function handleCreate() {
    if (!usdcAmount || !localAmount) return
    try {
      await createOffer(
        parseFloat(usdcAmount),
        localCurrency,
        parseFloat(localAmount),
      )
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2000)
    } catch {}
  }

  if (!isConnected) {
    return (
      <div className="flex h-64 items-center justify-center">
        <p className="text-sm text-[#64748B]">Connect your wallet to create an offer.</p>
      </div>
    )
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div>
          <h1 className="text-xl font-semibold text-[#E2E8F0]">Create P2P offer</h1>
          <p className="text-sm text-[#64748B]">
            Lock USDC in escrow — released to buyer after confirmation.
          </p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* How it works */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="flex items-start gap-2 text-xs text-[#64748B]">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#378ADD]" />
            <div className="space-y-1">
              <p>1. You lock USDC in the AfriFX vault (escrow)</p>
              <p>2. A buyer accepts your offer and sends you {localCurrency || 'local currency'}</p>
              <p>3. Both confirm — platform releases USDC to buyer</p>
              <p>4. Offer auto-expires in 30 minutes if not accepted</p>
            </div>
          </div>
        </div>

        {/* USDC to lock */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-[#64748B]">
              Balance: <span className="text-[#E2E8F0]">{balance} USDC</span>
            </span>
          </div>
          <Input
            type="number"
            placeholder="0.00"
            value={usdcAmount}
            onChange={(e) => setUsdcAmount(e.target.value)}
            className="font-mono text-lg"
          />
        </div>

        {/* Local currency */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <label className="mb-3 block text-xs font-medium uppercase tracking-wider text-[#64748B]">
            You want in return
          </label>
          <div className="flex gap-2">
            <select
              value={localCurrency}
              onChange={(e) => setLocalCurrency(e.target.value)}
              className="rounded-lg border border-[#1B2B4B] bg-[#080D1B] px-3 py-2 text-sm text-[#E2E8F0] outline-none"
            >
              {CURRENCIES.map(c => (
                <option key={c} value={c}>{CURRENCY_FLAG[c]} {c}</option>
              ))}
            </select>
            <Input
              type="number"
              placeholder="0"
              value={localAmount}
              onChange={(e) => setLocalAmount(e.target.value)}
              className="flex-1 font-mono text-lg"
            />
          </div>

          {/* Rate comparison */}
          {impliedRate > 0 && marketRate > 0 && (
            <div className="mt-3 flex items-center justify-between rounded-lg bg-[#080D1B] px-3 py-2 text-xs">
              <span className="text-[#64748B]">Your rate</span>
              <span className="font-mono text-[#E2E8F0]">
                1 USDC = {impliedRate.toFixed(2)} {localCurrency}
              </span>
              <span className={rateVsMarket >= 0 ? 'text-emerald-400' : 'text-red-400'}>
                {rateVsMarket >= 0 ? '+' : ''}{rateVsMarket.toFixed(2)}% vs market
              </span>
            </div>
          )}
        </div>

        {/* Summary */}
        {usdcAmount && localAmount && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-xs">
            <p className="mb-2 font-medium text-[#E2E8F0]">Offer summary</p>
            <div className="space-y-1.5 text-[#64748B]">
              <div className="flex justify-between">
                <span>You lock</span>
                <span className="font-mono text-[#E2E8F0]">{usdcAmount} USDC</span>
              </div>
              <div className="flex justify-between">
                <span>Buyer sends you</span>
                <span className="font-mono text-[#E2E8F0]">
                  {parseFloat(localAmount).toLocaleString()} {localCurrency}
                </span>
              </div>
              <div className="flex justify-between">
                <span>Platform fee (0.3%)</span>
                <span className="font-mono text-[#E2E8F0]">
                  {(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC
                </span>
              </div>
              <div className="flex justify-between">
                <span>Expires in</span>
                <span className="text-[#E2E8F0]">30 minutes</span>
              </div>
            </div>
          </div>
        )}

        {submitted ? (
          <div className="rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-center text-sm text-emerald-400">
            ✓ Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button
            className="w-full"
            size="lg"
            onClick={handleCreate}
            disabled={isLoading || !usdcAmount || !localAmount || parseFloat(usdcAmount) <= 0}
          >
            {isLoading ? 'Locking USDC in escrow…' : `Lock ${usdcAmount || '0'} USDC & Create Offer`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">
            {error}
          </div>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  app/(app)/marketplace/create/page.tsx"

# ============================================================
# 8 — Add Marketplace to Sidebar
# ============================================================
cat > afrifx-web/components/layout/Sidebar.tsx << '__EOF__'
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import {
  ArrowLeftRight, Send, History,
  LayoutDashboard, TrendingUp, Globe, Store
} from 'lucide-react'
import { cn } from '@/lib/utils'

const nav = [
  { label: 'Exchange', items: [
    { href: '/convert',     icon: ArrowLeftRight, label: 'Convert'     },
    { href: '/corridor',    icon: Globe,          label: 'Corridor'    },
    { href: '/send',        icon: Send,           label: 'Send'        },
    { href: '/marketplace', icon: Store,          label: 'Marketplace' },
  ]},
  { label: 'Account', items: [
    { href: '/history',   icon: History,         label: 'History'   },
    { href: '/dashboard', icon: LayoutDashboard, label: 'Dashboard' },
  ]},
  { label: 'Market', items: [
    { href: '/rates', icon: TrendingUp, label: 'Live rates' },
  ]},
]

export function Sidebar() {
  const pathname = usePathname()
  return (
    <aside className="w-52 shrink-0 border-r border-[#1B2B4B] py-4">
      {nav.map((section) => (
        <div key={section.label} className="mb-2">
          <p className="mb-1 px-4 text-[10px] font-semibold uppercase tracking-widest text-[#64748B]">
            {section.label}
          </p>
          {section.items.map(({ href, icon: Icon, label }) => {
            const active = pathname.startsWith(href)
            return (
              <Link
                key={href}
                href={href}
                className={cn(
                  'flex items-center gap-2.5 px-4 py-2.5 text-sm transition-colors',
                  active
                    ? 'bg-[#1B2B4B] font-medium text-[#E2E8F0]'
                    : 'text-[#64748B] hover:bg-[#0F1729] hover:text-[#E2E8F0]'
                )}
              >
                <Icon className="h-4 w-4 shrink-0" />
                {label}
              </Link>
            )
          })}
        </div>
      ))}
    </aside>
  )
}
__EOF__
echo "✅  Sidebar — Marketplace added"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 3 P2P Marketplace complete!"
echo ""
echo "  IMPORTANT — Redeploy vault contract with P2P functions:"
echo "  cd afrifx-contracts"
echo "  npx hardhat compile"
echo "  npm run deploy"
echo "  → Update NEXT_PUBLIC_AFRIFX_VAULT in afrifx-web/.env.local"
echo "  → Update AFRIFX_VAULT_ADDRESS in afrifx-api/.env"
echo ""
echo "  New pages:"
echo "    /marketplace        — browse + accept offers"
echo "    /marketplace/create — create a new offer"
echo ""
echo "  New API endpoints:"
echo "    GET  /offers"
echo "    GET  /offers/my?wallet=0x…"
echo "    GET  /offers/:id"
echo "    POST /offers"
echo "    PATCH /offers/:id"
echo ""
echo "  Restart both servers after redeployment:"
echo "  Terminal 1:  cd afrifx-api  && npm run dev"
echo "  Terminal 2:  cd afrifx-web  && npm run dev"
echo "══════════════════════════════════════════════════════"
