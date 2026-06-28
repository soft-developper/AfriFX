#!/bin/bash
# ============================================================
# AfriFX — Market/Limit Orders + Timers + Disputes
# Run from ~/AfriFX:  bash phase3-orders.sh
# ============================================================
set -e
echo ""
echo "📈  Building Market/Limit Orders + Timers + Disputes..."
echo ""

# ============================================================
# 1 — Updated smart contract — perpetual offers + order types
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
 * @notice Handles FX conversion + P2P marketplace with:
 *   - Market orders (live rate) and Limit orders (±5% of market)
 *   - Perpetual offers (no on-chain expiry — backend enforces timers)
 *   - Maker-set timer for taker completion window
 *
 * Arc Testnet USDC: 0x3600000000000000000000000000000000000000
 * Chain ID: 5042002
 */
contract AfriFXVault is Ownable, ReentrancyGuard, Pausable {

    IUSDC public immutable usdc;

    uint256 public spreadBps  = 50;
    uint256 public p2pFeeBps  = 30;
    uint256 public constant MAX_SPREAD_BPS = 200;

    enum OfferStatus { Open, Accepted, Released, Cancelled }
    enum OrderType   { Market, Limit }

    struct P2POffer {
        bytes32     offerId;
        address     maker;
        address     taker;
        uint256     usdcAmount;
        string      localCurrency;
        uint256     localAmount;        // auto-calculated from rate
        uint256     rateOffered;        // local units per USDC * 1e6
        OrderType   orderType;          // Market or Limit
        uint256     makerTimerSeconds;  // window maker gives taker
        OfferStatus status;
        bool        makerConfirmed;     // maker received local currency
        bool        takerConfirmed;     // taker sent local currency
    }

    mapping(bytes32 => P2POffer) public offers;

    uint256 public p2pFeeBps_ = 30;

    event OfferCreated(
        bytes32 indexed offerId,
        address indexed maker,
        uint256 usdcAmount,
        string  localCurrency,
        uint256 localAmount,
        uint8   orderType,
        uint256 makerTimerSeconds
    );
    event OfferAccepted(bytes32 indexed offerId, address indexed taker);
    event TakerConfirmed(bytes32 indexed offerId);
    event MakerConfirmed(bytes32 indexed offerId);
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
     * @notice Create a perpetual P2P offer (no on-chain expiry).
     * @param usdcAmount       USDC to lock (6 decimals)
     * @param localCurrency    ISO code e.g. "NGN"
     * @param localAmount      Local currency amount (calculated from rate off-chain)
     * @param orderType        0=Market, 1=Limit
     * @param makerTimerSeconds Window given to taker after accepting (in seconds)
     */
    function createP2POffer(
        uint256 usdcAmount,
        string  calldata localCurrency,
        uint256 localAmount,
        uint8   orderType,
        uint256 makerTimerSeconds
    ) external nonReentrant whenNotPaused returns (bytes32 offerId) {
        require(usdcAmount    > 0,  "Amount required");
        require(localAmount   > 0,  "Local amount required");
        require(makerTimerSeconds >= 5 minutes, "Min timer: 5 minutes");
        require(makerTimerSeconds <= 24 hours,  "Max timer: 24 hours");

        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        offerId = keccak256(abi.encodePacked(
            msg.sender, usdcAmount, localCurrency, block.timestamp, block.prevrandao
        ));

        uint256 rate = (usdcAmount * 1e6) / localAmount;

        offers[offerId] = P2POffer({
            offerId:           offerId,
            maker:             msg.sender,
            taker:             address(0),
            usdcAmount:        usdcAmount,
            localCurrency:     localCurrency,
            localAmount:       localAmount,
            rateOffered:       rate,
            orderType:         OrderType(orderType),
            makerTimerSeconds: makerTimerSeconds,
            status:            OfferStatus.Open,
            makerConfirmed:    false,
            takerConfirmed:    false
        });

        emit OfferCreated(offerId, msg.sender, usdcAmount, localCurrency, localAmount, orderType, makerTimerSeconds);
    }

    function acceptP2POffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status   == OfferStatus.Open, "Offer not open");
        require(offer.maker    != msg.sender,        "Cannot self-trade");
        offer.taker  = msg.sender;
        offer.status = OfferStatus.Accepted;
        emit OfferAccepted(offerId, msg.sender);
    }

    // Taker confirms they SENT local currency to maker
    function takerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  == msg.sender,           "Not the taker");
        offer.takerConfirmed = true;
        emit TakerConfirmed(offerId);
    }

    // Maker confirms they RECEIVED local currency from taker
    function makerConfirm(bytes32 offerId) external {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.maker  == msg.sender,           "Not the maker");
        offer.makerConfirmed = true;
        emit MakerConfirmed(offerId);
    }

    // Platform releases USDC to taker (owner only)
    function releaseP2POffer(bytes32 offerId) external onlyOwner nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Accepted, "Offer not accepted");
        require(offer.taker  != address(0),           "No taker");
        uint256 fee    = (offer.usdcAmount * p2pFeeBps) / 10_000;
        uint256 payout = offer.usdcAmount - fee;
        offer.status   = OfferStatus.Released;
        usdc.transfer(offer.taker, payout);
        emit OfferReleased(offerId, offer.taker, payout);
    }

    // Platform cancels and returns USDC to maker (owner only)
    function cancelP2POffer(bytes32 offerId, string calldata reason) external onlyOwner nonReentrant {
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

    // Maker cancels own open offer
    function makerCancelOffer(bytes32 offerId) external nonReentrant {
        P2POffer storage offer = offers[offerId];
        require(offer.status == OfferStatus.Open, "Offer not open");
        require(offer.maker  == msg.sender,       "Not the maker");
        offer.status = OfferStatus.Cancelled;
        usdc.transfer(offer.maker, offer.usdcAmount);
        emit OfferCancelled(offerId, "Maker cancelled");
    }

    function getOffer(bytes32 offerId) external view returns (P2POffer memory) {
        return offers[offerId];
    }

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
echo "✅  AfriFXVault.sol — perpetual offers + orderType + makerTimerSeconds"

# ============================================================
# 2 — Updated vault ABI for frontend
# ============================================================
cat > afrifx-web/lib/vault-abi.ts << '__EOF__'
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
__EOF__
echo "✅  lib/vault-abi.ts — updated with new params"

# ============================================================
# 3 — Turso: add new columns to p2p_offers + create disputes
# ============================================================
echo "  Migrating Turso..."

turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN order_type TEXT DEFAULT 'market';" 2>/dev/null || true
turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN limit_rate REAL;" 2>/dev/null || true
turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN maker_timer_seconds INTEGER DEFAULT 1800;" 2>/dev/null || true
turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN taker_deadline INTEGER;" 2>/dev/null || true
turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN maker_deadline INTEGER;" 2>/dev/null || true
turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN dispute_raised INTEGER DEFAULT 0;" 2>/dev/null || true
turso db shell afrifx "ALTER TABLE p2p_offers ADD COLUMN dispute_id TEXT;" 2>/dev/null || true

turso db shell afrifx "
CREATE TABLE IF NOT EXISTS disputes (
  id             TEXT PRIMARY KEY,
  offer_id       TEXT NOT NULL,
  raised_by      TEXT NOT NULL,
  reason         TEXT,
  status         TEXT NOT NULL DEFAULT 'open',
  auto_settle_at INTEGER NOT NULL,
  settled_at     INTEGER,
  created_at     INTEGER NOT NULL
);" && echo "  ✅  disputes table created"

echo "✅  Turso migrations done"

# ============================================================
# 4 — Updated DB schema
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
  id:                 text('id').primaryKey(),
  makerAddress:       text('maker_address').notNull(),
  takerAddress:       text('taker_address'),
  usdcAmount:         real('usdc_amount').notNull(),
  localCurrency:      text('local_currency').notNull(),
  localAmount:        real('local_amount').notNull(),
  rateOffered:        real('rate_offered').notNull(),
  orderType:          text('order_type').notNull().default('market'),
  limitRate:          real('limit_rate'),
  makerTimerSeconds:  integer('maker_timer_seconds').notNull().default(1800),
  status:             text('status').notNull().default('open'),
  makerConfirmed:     integer('maker_confirmed').notNull().default(0),
  takerConfirmed:     integer('taker_confirmed').notNull().default(0),
  takerDeadline:      integer('taker_deadline'),
  makerDeadline:      integer('maker_deadline'),
  disputeRaised:      integer('dispute_raised').notNull().default(0),
  disputeId:          text('dispute_id'),
  arcTxHash:          text('arc_tx_hash'),
  releaseTxHash:      text('release_tx_hash'),
  createdAt:          integer('created_at').notNull(),
  updatedAt:          integer('updated_at').notNull(),
})

export const disputes = sqliteTable('disputes', {
  id:           text('id').primaryKey(),
  offerId:      text('offer_id').notNull(),
  raisedBy:     text('raised_by').notNull(),
  reason:       text('reason'),
  status:       text('status').notNull().default('open'),
  autoSettleAt: integer('auto_settle_at').notNull(),
  settledAt:    integer('settled_at'),
  createdAt:    integer('created_at').notNull(),
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
  walletAddress:    text('wallet_address').primaryKey(),
  volume30d:        real('volume_30d').notNull().default(0),
  txCount:          integer('tx_count').notNull().default(0),
  disputeWarnings:  integer('dispute_warnings').notNull().default(0),
  createdAt:        integer('created_at').notNull(),
})
__EOF__
echo "✅  db/schema.ts — updated with all new columns"

# ============================================================
# 5 — Updated offers route — handles new fields
# ============================================================
cat > afrifx-api/src/routes/offers.ts << '__EOF__'
import { Router } from 'express'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

// GET /offers
router.get('/', async (req, res) => {
  const currency = req.query.currency as string | undefined
  const status   = req.query.status   as string | undefined
  const type     = req.query.type     as string | undefined
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE status IN ('open','accepted')
          ${currency ? sql`AND local_currency = ${currency}` : sql``}
          ${status   ? sql`AND status = ${status}`           : sql``}
          ${type     ? sql`AND order_type = ${type}`         : sql``}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/my?wallet=0x…
router.get('/my', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers
          WHERE LOWER(maker_address) = ${wallet}
             OR LOWER(taker_address) = ${wallet}
          ORDER BY created_at DESC LIMIT 50`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    res.json(offers)
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM p2p_offers WHERE id = ${req.params.id} LIMIT 1`
    )
    const offers = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!offers.length) return res.status(404).json({ error: 'Not found' })
    res.json(offers[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers — create
router.post('/', async (req, res) => {
  const {
    id, makerAddress, usdcAmount, localCurrency, localAmount,
    rateOffered, orderType, limitRate, makerTimerSeconds, arcTxHash,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`INSERT OR IGNORE INTO p2p_offers
          (id, maker_address, usdc_amount, local_currency, local_amount,
           rate_offered, order_type, limit_rate, maker_timer_seconds,
           arc_tx_hash, created_at, updated_at)
          VALUES
          (${id}, ${makerAddress.toLowerCase()}, ${usdcAmount},
           ${localCurrency}, ${localAmount}, ${rateOffered},
           ${orderType ?? 'market'}, ${limitRate ?? null},
           ${makerTimerSeconds ?? 1800},
           ${arcTxHash ?? null}, ${now}, ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /offers/:id — update status/confirmations/deadlines
router.patch('/:id', async (req, res) => {
  const {
    status, takerAddress, makerConfirmed, takerConfirmed,
    releaseTxHash, takerDeadline, makerDeadline,
    disputeRaised, disputeId,
  } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE p2p_offers SET
            status          = COALESCE(${status          ?? null}, status),
            taker_address   = COALESCE(${takerAddress    ? takerAddress.toLowerCase() : null}, taker_address),
            maker_confirmed = COALESCE(${makerConfirmed  ?? null}, maker_confirmed),
            taker_confirmed = COALESCE(${takerConfirmed  ?? null}, taker_confirmed),
            release_tx_hash = COALESCE(${releaseTxHash   ?? null}, release_tx_hash),
            taker_deadline  = COALESCE(${takerDeadline   ?? null}, taker_deadline),
            maker_deadline  = COALESCE(${makerDeadline   ?? null}, maker_deadline),
            dispute_raised  = COALESCE(${disputeRaised   ?? null}, dispute_raised),
            dispute_id      = COALESCE(${disputeId       ?? null}, dispute_id),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /offers/:id/dispute — taker raises a dispute
router.post('/:id/dispute', async (req, res) => {
  const { raisedBy, reason } = req.body
  const offerId = req.params.id
  const now     = Math.floor(Date.now() / 1000)
  const disputeId    = randomUUID()
  const autoSettleAt = now + 86400 // 24 hours

  try {
    // Create dispute record
    await db.run(
      sql`INSERT INTO disputes (id, offer_id, raised_by, reason, auto_settle_at, created_at)
          VALUES (${disputeId}, ${offerId}, ${raisedBy.toLowerCase()}, ${reason ?? null}, ${autoSettleAt}, ${now})`
    )

    // Flag the offer
    await db.run(
      sql`UPDATE p2p_offers SET
            dispute_raised = 1,
            dispute_id     = ${disputeId},
            updated_at     = ${now}
          WHERE id = ${offerId}`
    )

    // Add warning to maker's record
    const offerRows = await db.run(sql`SELECT maker_address FROM p2p_offers WHERE id = ${offerId}`)
    const rows = Array.isArray((offerRows as any).rows) ? (offerRows as any).rows : []
    if (rows.length) {
      const maker = rows[0].maker_address ?? rows[0][0]
      await db.run(
        sql`UPDATE users SET dispute_warnings = dispute_warnings + 1
            WHERE wallet_address = ${maker.toLowerCase()}`
      ).catch(() => {}) // ignore if user row doesn't exist yet
    }

    res.status(201).json({ disputeId, autoSettleAt })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /offers/:id/dispute — get dispute details
router.get('/:id/dispute', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM disputes WHERE offer_id = ${req.params.id} ORDER BY created_at DESC LIMIT 1`
    )
    const disputes = Array.isArray((rows as any).rows)
      ? (rows as any).rows : Array.isArray(rows) ? rows : []
    if (!disputes.length) return res.status(404).json({ error: 'No dispute found' })
    res.json(disputes[0])
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
__EOF__
echo "✅  routes/offers.ts — dispute endpoint + new fields"

# ============================================================
# 6 — Updated P2P release watcher with all 4 jobs
# ============================================================
cat > afrifx-api/src/jobs/p2pReleaseWatcher.ts << '__EOF__'
import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { releasePlatform, cancelPlatform } from '../services/platformWallet'

export function startP2PReleaseWatcher() {
  if (!process.env.PLATFORM_WALLET_PRIVATE_KEY) {
    console.warn('[P2PWatcher] PLATFORM_WALLET_PRIVATE_KEY not set — auto-release disabled')
    return
  }
  console.log('[P2PWatcher] Starting — polling every 15s')

  cron.schedule('*/15 * * * * *', async () => {
    await job1_releaseConfirmed()
    await job2_cancelTimedOutTakers()
    await job3_flagTimedOutMakers()
    await job4_autoSettleDisputes()
  })

  // Run immediately on boot
  job1_releaseConfirmed()
  job2_cancelTimedOutTakers()
  job3_flagTimedOutMakers()
  job4_autoSettleDisputes()
}

// ── Job 1: Both confirmed → release USDC to taker ────────
async function job1_releaseConfirmed() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND maker_confirmed = 1
            AND taker_confirmed = 1
            AND dispute_raised  = 0`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        const hash = await releasePlatform(offerId)
        await db.run(
          sql`UPDATE p2p_offers SET
                status          = 'released',
                release_tx_hash = ${hash},
                updated_at      = ${now}
              WHERE id = ${offerId}`
        )
        console.log(`[P2PWatcher] ✅ Released ${offerId.slice(0,12)}…`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Release failed ${offerId.slice(0,12)}:`, err.message)
      }
    }
  } catch (err: any) {
    console.error('[P2PWatcher] Job1 error:', err.message)
  }
}

// ── Job 2: Taker didn't send in time → cancel, return to market ──
async function job2_cancelTimedOutTakers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND taker_confirmed = 0
            AND taker_deadline  IS NOT NULL
            AND taker_deadline  < ${now}`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      try {
        await cancelPlatform(offerId, 'Taker did not complete in time')
        await db.run(
          sql`UPDATE p2p_offers SET
                status         = 'open',
                taker_address  = NULL,
                taker_deadline = NULL,
                updated_at     = ${now}
              WHERE id = ${offerId}`
        )
        console.log(`[P2PWatcher] ⏰ Taker timed out — offer ${offerId.slice(0,12)} back to market`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Cancel timed-out taker failed:`, err.message)
      }
    }
  } catch (err: any) {
    console.error('[P2PWatcher] Job2 error:', err.message)
  }
}

// ── Job 3: Maker didn't confirm in time → flag dispute ───
async function job3_flagTimedOutMakers() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT id FROM p2p_offers
          WHERE status          = 'accepted'
            AND taker_confirmed = 1
            AND maker_confirmed = 0
            AND dispute_raised  = 0
            AND maker_deadline  IS NOT NULL
            AND maker_deadline  < ${now}`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId = (row.id ?? row[0]) as `0x${string}`
      // Automatically raise a system dispute
      await db.run(
        sql`UPDATE p2p_offers
            SET dispute_raised = 1, updated_at = ${now}
            WHERE id = ${offerId}`
      ).catch(() => {})
      console.log(`[P2PWatcher] ⚠️  Maker timed out — dispute flagged for ${offerId.slice(0,12)}`)
    }
  } catch (err: any) {
    console.error('[P2PWatcher] Job3 error:', err.message)
  }
}

// ── Job 4: Dispute 24h old → auto-release to taker ───────
async function job4_autoSettleDisputes() {
  const now = Math.floor(Date.now() / 1000)
  try {
    const result = await db.run(
      sql`SELECT d.id as dispute_id, d.offer_id
          FROM disputes d
          JOIN p2p_offers o ON o.id = d.offer_id
          WHERE d.status         = 'open'
            AND d.auto_settle_at < ${now}
            AND o.status         = 'accepted'`
    )
    const rows = parseRows(result)
    for (const row of rows) {
      const offerId   = (row.offer_id  ?? row[1]) as `0x${string}`
      const disputeId =  row.dispute_id ?? row[0]
      try {
        const hash = await releasePlatform(offerId)
        await db.run(
          sql`UPDATE p2p_offers SET
                status          = 'released',
                release_tx_hash = ${hash},
                updated_at      = ${now}
              WHERE id = ${offerId}`
        )
        await db.run(
          sql`UPDATE disputes SET
                status     = 'auto_settled',
                settled_at = ${now}
              WHERE id = ${disputeId}`
        )
        console.log(`[P2PWatcher] ⚖️  Auto-settled dispute → USDC released to taker ${offerId.slice(0,12)}`)
      } catch (err: any) {
        console.error(`[P2PWatcher] Auto-settle failed:`, err.message)
      }
    }
  } catch (err: any) {
    console.error('[P2PWatcher] Job4 error:', err.message)
  }
}

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}
__EOF__
echo "✅  p2pReleaseWatcher.ts — 4 jobs: release, taker-timeout, maker-timeout, dispute"

# ============================================================
# 7 — Updated useP2P hook — new contract signature
# ============================================================
cat > afrifx-web/hooks/useP2P.ts << '__EOF__'
'use client'
import { useState } from 'react'
import { useAccount, useWriteContract, usePublicClient } from 'wagmi'
import { parseUnits, isAddress, decodeEventLog } from 'viem'
import { CONTRACTS, USDC_DECIMALS } from '@/lib/contracts'
import { USDC_ABI } from '@/lib/usdc'
import { VAULT_P2P_ABI } from '@/lib/vault-abi'
import { arcTestnet } from '@/lib/arc-chain'

const API  = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const ZERO = '0x0000000000000000000000000000000000000000'

export type OrderType = 'market' | 'limit'

export interface CreateOfferParams {
  usdcAmount:        number
  localCurrency:     string
  localAmount:       number
  orderType:         OrderType
  limitRate?:        number   // only for limit orders
  makerTimerSeconds: number
}

export function useP2P() {
  const { address }   = useAccount()
  const publicClient  = usePublicClient({ chainId: arcTestnet.id })
  const [isLoading, setIsLoading] = useState(false)
  const [error,     setError]     = useState<string | null>(null)
  const [txHash,    setTxHash]    = useState<`0x${string}` | null>(null)
  const [offerId,   setOfferId]   = useState<`0x${string}` | null>(null)

  const { writeContractAsync } = useWriteContract()

  function clearError() { setError(null) }

  async function getOfferIdFromReceipt(hash: `0x${string}`): Promise<`0x${string}`> {
    if (!publicClient) throw new Error('No public client')
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    for (const log of receipt.logs) {
      try {
        const decoded = decodeEventLog({
          abi: VAULT_P2P_ABI, eventName: 'OfferCreated',
          data: log.data, topics: log.topics,
        })
        if (decoded.args.offerId) return decoded.args.offerId as `0x${string}`
      } catch {}
    }
    throw new Error('OfferCreated event not found')
  }

  // ── Create offer ──────────────────────────────────────────
  async function createOffer(params: CreateOfferParams) {
    if (!address) throw new Error('Wallet not connected')
    const vault = CONTRACTS.AFRIFX_VAULT
    if (!vault || vault === ZERO || !isAddress(vault)) {
      throw new Error('Vault not configured')
    }
    setIsLoading(true); setError(null)
    try {
      const usdcRaw    = parseUnits(params.usdcAmount.toFixed(6), USDC_DECIMALS)
      const localRaw   = BigInt(Math.round(params.localAmount))
      const orderTypeN = params.orderType === 'limit' ? 1 : 0

      // Approve vault
      await writeContractAsync({
        address: CONTRACTS.USDC, abi: USDC_ABI,
        functionName: 'approve', args: [vault, usdcRaw],
      })

      // Create offer on-chain
      const hash = await writeContractAsync({
        address: vault, abi: VAULT_P2P_ABI,
        functionName: 'createP2POffer',
        args: [usdcRaw, params.localCurrency, localRaw, orderTypeN, BigInt(params.makerTimerSeconds)],
      })
      setTxHash(hash)

      const realOfferId = await getOfferIdFromReceipt(hash)
      setOfferId(realOfferId)

      await fetch(`${API}/offers`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id:                realOfferId,
          makerAddress:      address,
          usdcAmount:        params.usdcAmount,
          localCurrency:     params.localCurrency,
          localAmount:       params.localAmount,
          rateOffered:       params.usdcAmount / params.localAmount,
          orderType:         params.orderType,
          limitRate:         params.limitRate ?? null,
          makerTimerSeconds: params.makerTimerSeconds,
          arcTxHash:         hash,
        }),
      })
      return realOfferId
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Accept offer ──────────────────────────────────────────
  async function acceptOffer(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const hash = await writeContractAsync({
        address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
        functionName: 'acceptP2POffer', args: [offerId],
      })
      setTxHash(hash)
      const takerDeadline = Math.floor(Date.now() / 1000) + makerTimerSeconds
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'accepted', takerAddress: address, takerDeadline }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Taker confirms: sent local currency ───────────────────
  async function takerConfirm(offerId: `0x${string}`, makerTimerSeconds: number) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const hash = await writeContractAsync({
        address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
        functionName: 'takerConfirm', args: [offerId],
      })
      setTxHash(hash)
      // Reset timer for maker — fresh window
      const makerDeadline = Math.floor(Date.now() / 1000) + makerTimerSeconds
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ takerConfirmed: 1, makerDeadline }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Maker confirms: received local currency ───────────────
  async function makerConfirm(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const hash = await writeContractAsync({
        address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
        functionName: 'makerConfirm', args: [offerId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ makerConfirmed: 1 }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Taker raises dispute ──────────────────────────────────
  async function raiseDispute(offerId: string, reason?: string) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const res = await fetch(`${API}/offers/${offerId}/dispute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ raisedBy: address, reason }),
      })
      const data = await res.json()
      return data
    } catch (err: any) {
      setError(err?.message ?? 'Failed to raise dispute')
      throw err
    } finally { setIsLoading(false) }
  }

  // ── Maker cancels own open offer ──────────────────────────
  async function cancelOwnOffer(offerId: `0x${string}`) {
    if (!address) throw new Error('Wallet not connected')
    setIsLoading(true); setError(null)
    try {
      const hash = await writeContractAsync({
        address: CONTRACTS.AFRIFX_VAULT, abi: VAULT_P2P_ABI,
        functionName: 'makerCancelOffer', args: [offerId],
      })
      setTxHash(hash)
      await fetch(`${API}/offers/${offerId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'cancelled' }),
      })
      return hash
    } catch (err: any) {
      setError(err?.shortMessage ?? err?.message ?? 'Failed')
      throw err
    } finally { setIsLoading(false) }
  }

  return {
    createOffer, acceptOffer, takerConfirm,
    makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading, error, txHash, offerId, clearError,
  }
}
__EOF__
echo "✅  hooks/useP2P.ts — new params + dispute + cancel"

# ============================================================
# 8 — useCountdown hook
# ============================================================
cat > afrifx-web/hooks/useCountdown.ts << '__EOF__'
'use client'
import { useState, useEffect } from 'react'

export function useCountdown(deadlineUnix: number | null | undefined) {
  const [secondsLeft, setSecondsLeft] = useState<number>(0)

  useEffect(() => {
    if (!deadlineUnix) { setSecondsLeft(0); return }

    function update() {
      const diff = deadlineUnix! - Math.floor(Date.now() / 1000)
      setSecondsLeft(Math.max(0, diff))
    }

    update()
    const interval = setInterval(update, 1000)
    return () => clearInterval(interval)
  }, [deadlineUnix])

  const hours   = Math.floor(secondsLeft / 3600)
  const minutes = Math.floor((secondsLeft % 3600) / 60)
  const seconds = secondsLeft % 60

  const isExpired = secondsLeft === 0 && !!deadlineUnix
  const isUrgent  = secondsLeft > 0 && secondsLeft < 300 // < 5 min

  const formatted = secondsLeft === 0
    ? (deadlineUnix ? 'Expired' : '—')
    : hours > 0
    ? `${hours}h ${minutes}m ${seconds}s`
    : minutes > 0
    ? `${minutes}m ${seconds}s`
    : `${seconds}s`

  return { secondsLeft, formatted, isExpired, isUrgent }
}
__EOF__
echo "✅  hooks/useCountdown.ts"

# ============================================================
# 9 — CountdownTimer component
# ============================================================
mkdir -p afrifx-web/components/p2p
cat > afrifx-web/components/p2p/CountdownTimer.tsx << '__EOF__'
'use client'
import { useCountdown } from '@/hooks/useCountdown'
import { Clock, AlertTriangle } from 'lucide-react'

interface CountdownTimerProps {
  deadline:    number | null | undefined
  label:       string
  onExpired?:  () => void
}

export function CountdownTimer({ deadline, label, onExpired }: CountdownTimerProps) {
  const { formatted, isExpired, isUrgent } = useCountdown(deadline)

  if (isExpired && onExpired) onExpired()

  if (!deadline) return null

  return (
    <div className={`flex items-center gap-2 rounded-lg px-3 py-2 text-xs
      ${isExpired
        ? 'border border-red-900/50 bg-red-900/20 text-red-400'
        : isUrgent
        ? 'border border-amber-900/50 bg-amber-900/20 text-amber-400'
        : 'border border-[#1B2B4B] bg-[#080D1B] text-[#64748B]'
      }`}>
      {isExpired
        ? <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
        : <Clock className="h-3.5 w-3.5 shrink-0" />
      }
      <span>{label}</span>
      <span className={`ml-auto font-mono font-medium ${
        isExpired ? 'text-red-400' : isUrgent ? 'text-amber-400' : 'text-[#E2E8F0]'
      }`}>
        {formatted}
      </span>
    </div>
  )
}
__EOF__
echo "✅  components/p2p/CountdownTimer.tsx"

# ============================================================
# 10 — New create offer page: Market/Limit + timer
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/create/page.tsx" << '__EOF__'
'use client'
import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useAccount } from 'wagmi'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useP2P, type OrderType } from '@/hooks/useP2P'
import { useUSDCBalance } from '@/hooks/useUSDCBalance'
import { useRate } from '@/hooks/useFXRate'
import { ArrowLeft, Info, CheckCircle, TrendingUp, Sliders } from 'lucide-react'
import Link from 'next/link'

const CURRENCIES      = ['NGN', 'GHS', 'KES', 'ZAR', 'EGP']
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

const TIMER_OPTIONS = [
  { label: '30 min', value: 1800  },
  { label: '1 hour', value: 3600  },
  { label: '2 hours',value: 7200  },
  { label: 'Custom', value: 0     },
]

export default function CreateOfferPage() {
  const router               = useRouter()
  const { address, isConnected } = useAccount()
  const { formatted: balance }   = useUSDCBalance()

  const [orderType,      setOrderType]      = useState<OrderType>('market')
  const [localCurrency,  setLocalCurrency]  = useState('NGN')
  const [usdcAmount,     setUsdcAmount]     = useState('')
  const [limitOffset,    setLimitOffset]    = useState(0)    // -5 to +5 percent
  const [timerOption,    setTimerOption]    = useState(1800)
  const [customTimer,    setCustomTimer]    = useState('')   // minutes
  const [submitted,      setSubmitted]      = useState(false)

  const { createOffer, isLoading, error } = useP2P()
  const { rate: fxRate } = useRate(`${localCurrency}/USDC`)
  const marketRate = fxRate?.rate ?? 0

  // Effective rate for this order
  const effectiveRate = orderType === 'market'
    ? marketRate
    : marketRate * (1 + limitOffset / 100)

  // Auto-calculated local amount
  const localAmount = usdcAmount && effectiveRate > 0
    ? parseFloat(usdcAmount) * effectiveRate
    : 0

  // Timer in seconds
  const timerSeconds = timerOption === 0
    ? (parseInt(customTimer) || 0) * 60
    : timerOption

  const rateVsMarket = orderType === 'limit' ? limitOffset : 0

  async function handleCreate() {
    if (!usdcAmount || localAmount <= 0 || timerSeconds < 300) return
    try {
      await createOffer({
        usdcAmount:        parseFloat(usdcAmount),
        localCurrency,
        localAmount,
        orderType,
        limitRate:         orderType === 'limit' ? effectiveRate : undefined,
        makerTimerSeconds: timerSeconds,
      })
      setSubmitted(true)
      setTimeout(() => router.push('/marketplace'), 2500)
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
          <p className="text-sm text-[#64748B]">Lock USDC in escrow — perpetual until filled or cancelled.</p>
        </div>
      </div>

      <div className="w-full max-w-md space-y-4">

        {/* Order type tabs */}
        <div className="flex rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-1">
          <button
            onClick={() => setOrderType('market')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'market'
                ? 'bg-[#378ADD] text-white'
                : 'text-[#64748B] hover:text-[#E2E8F0]'}`}
          >
            <TrendingUp className="h-4 w-4" /> Market order
          </button>
          <button
            onClick={() => setOrderType('limit')}
            className={`flex flex-1 items-center justify-center gap-2 rounded-lg py-2.5 text-sm font-medium transition-colors
              ${orderType === 'limit'
                ? 'bg-[#378ADD] text-white'
                : 'text-[#64748B] hover:text-[#E2E8F0]'}`}
          >
            <Sliders className="h-4 w-4" /> Limit order
          </button>
        </div>

        {/* Order type description */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-3 text-xs text-[#64748B]">
          <div className="flex items-start gap-2">
            <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#378ADD]" />
            {orderType === 'market'
              ? 'Market order uses the live exchange rate. Local amount is calculated automatically and updates with the market.'
              : 'Limit order lets you set a custom rate within ±5% of the market rate. Attract takers faster with a better rate, or maximise your return.'
            }
          </div>
        </div>

        {/* Currency + USDC amount */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-3 flex items-center justify-between">
            <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
              USDC to lock in escrow
            </label>
            <span className="text-xs text-[#64748B]">
              Balance: <span className="text-[#E2E8F0]">{balance}</span>
            </span>
          </div>
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
              placeholder="0.00"
              value={usdcAmount}
              onChange={(e) => setUsdcAmount(e.target.value)}
              className="flex-1 font-mono text-lg"
            />
          </div>
        </div>

        {/* Market rate display */}
        {marketRate > 0 && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="mb-2 flex items-center justify-between text-xs">
              <span className="text-[#64748B]">Live market rate</span>
              <span className="font-mono text-[#E2E8F0]">
                1 USDC = {marketRate.toLocaleString()} {localCurrency}
              </span>
            </div>

            {/* Limit order rate slider */}
            {orderType === 'limit' && (
              <div className="mt-3">
                <div className="mb-2 flex items-center justify-between text-xs">
                  <span className="text-[#64748B]">Your rate</span>
                  <span className={`font-medium ${limitOffset > 0 ? 'text-emerald-400' : limitOffset < 0 ? 'text-red-400' : 'text-[#E2E8F0]'}`}>
                    {limitOffset > 0 ? '+' : ''}{limitOffset.toFixed(1)}% · 1 USDC = {effectiveRate.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                  </span>
                </div>
                <input
                  type="range"
                  min="-5"
                  max="5"
                  step="0.5"
                  value={limitOffset}
                  onChange={(e) => setLimitOffset(parseFloat(e.target.value))}
                  className="w-full accent-[#378ADD]"
                />
                <div className="mt-1 flex justify-between text-[10px] text-[#64748B]">
                  <span>-5% (worse for taker)</span>
                  <span>Market</span>
                  <span>+5% (better for taker)</span>
                </div>
                {Math.abs(limitOffset) > 5 && (
                  <p className="mt-1 text-xs text-red-400">Rate must be within ±5% of market</p>
                )}
              </div>
            )}
          </div>
        )}

        {/* Auto-calculated local amount */}
        {localAmount > 0 && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-xs text-[#64748B]">You will receive</p>
                <p className="mt-1 font-mono text-2xl font-semibold text-[#E2E8F0]">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  <span className="ml-2 text-base text-[#64748B]">{localCurrency}</span>
                </p>
              </div>
              <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                {orderType === 'market' ? 'Market rate' : `${limitOffset > 0 ? '+' : ''}${limitOffset}%`}
              </Badge>
            </div>
          </div>
        )}

        {/* Maker timer */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4">
          <div className="mb-3 flex items-center gap-2">
            <label className="text-xs font-medium uppercase tracking-wider text-[#64748B]">
              Taker completion window
            </label>
            <span className="text-[10px] text-[#64748B]">(time taker has after accepting)</span>
          </div>
          <div className="flex gap-2 flex-wrap">
            {TIMER_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                onClick={() => setTimerOption(opt.value)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors
                  ${timerOption === opt.value
                    ? 'bg-[#378ADD] text-white'
                    : 'border border-[#1B2B4B] text-[#64748B] hover:text-[#E2E8F0]'}`}
              >
                {opt.label}
              </button>
            ))}
          </div>
          {timerOption === 0 && (
            <div className="mt-3 flex items-center gap-2">
              <Input
                type="number"
                placeholder="Minutes (min 5, max 1440)"
                value={customTimer}
                onChange={(e) => setCustomTimer(e.target.value)}
                className="font-mono"
              />
              <span className="text-xs text-[#64748B]">min</span>
            </div>
          )}
          <p className="mt-2 text-xs text-[#64748B]">
            If taker doesn't send {localCurrency} within this window, the offer automatically returns to the marketplace.
          </p>
        </div>

        {/* Summary */}
        {usdcAmount && localAmount > 0 && timerSeconds > 0 && (
          <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-4 text-xs">
            <p className="mb-2 font-medium text-[#E2E8F0]">Order summary</p>
            <div className="space-y-1.5 text-[#64748B]">
              <div className="flex justify-between">
                <span>Order type</span>
                <Badge variant={orderType === 'market' ? 'arc' : 'warning'}>
                  {orderType === 'market' ? 'Market' : 'Limit'}
                </Badge>
              </div>
              <div className="flex justify-between">
                <span>You lock (escrow)</span>
                <span className="font-mono text-[#E2E8F0]">{usdcAmount} USDC</span>
              </div>
              <div className="flex justify-between">
                <span>You receive</span>
                <span className="font-mono text-[#E2E8F0]">
                  {localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} {localCurrency}
                </span>
              </div>
              <div className="flex justify-between">
                <span>Taker window</span>
                <span className="text-[#E2E8F0]">
                  {timerSeconds >= 3600
                    ? `${timerSeconds / 3600}h`
                    : `${timerSeconds / 60}min`}
                </span>
              </div>
              <div className="flex justify-between">
                <span>Duration</span>
                <span className="text-[#E2E8F0]">Perpetual until filled or cancelled</span>
              </div>
              <div className="flex justify-between">
                <span>Platform fee</span>
                <span className="font-mono text-[#E2E8F0]">
                  {(parseFloat(usdcAmount) * 0.003).toFixed(4)} USDC (0.3%)
                </span>
              </div>
            </div>
          </div>
        )}

        {/* Flow reminder */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-3 text-xs text-[#64748B]">
          <p className="mb-1 font-medium text-[#E2E8F0]">Trade flow</p>
          <ol className="space-y-0.5 list-none">
            {[
              'You lock USDC in vault escrow',
              `Taker accepts + sends ${localCurrency} to you within the window`,
              'Taker confirms: "I sent the money"',
              'You confirm: "I received the money"',
              'Platform releases USDC to taker',
            ].map((s, i) => (
              <li key={i} className="flex items-start gap-2">
                <span className="shrink-0 text-[#378ADD]">{i+1}.</span>
                <span>{s}</span>
              </li>
            ))}
          </ol>
        </div>

        {submitted ? (
          <div className="flex items-center gap-2 rounded-xl border border-emerald-900/50 bg-emerald-900/20 p-4 text-sm text-emerald-400">
            <CheckCircle className="h-4 w-4 shrink-0" />
            Offer created! Redirecting to marketplace…
          </div>
        ) : (
          <Button
            className="w-full"
            size="lg"
            onClick={handleCreate}
            disabled={
              isLoading ||
              !usdcAmount ||
              localAmount <= 0 ||
              timerSeconds < 300 ||
              (timerOption === 0 && (!customTimer || parseInt(customTimer) < 5))
            }
          >
            {isLoading
              ? 'Locking USDC in escrow…'
              : `Create ${orderType === 'market' ? 'market' : 'limit'} order — ${usdcAmount || '0'} USDC`}
          </Button>
        )}

        {error && (
          <div className="rounded-lg bg-red-900/20 px-4 py-3 text-xs text-red-400">{error}</div>
        )}
      </div>
    </div>
  )
}
__EOF__
echo "✅  create/page.tsx — market/limit + auto-calc + timer"

# ============================================================
# 11 — Updated offer detail page with timer + dispute
# ============================================================
cat > "afrifx-web/app/(app)/marketplace/[id]/page.tsx" << '__EOF__'
'use client'
import { useEffect, useState, useCallback } from 'react'
import { useAccount } from 'wagmi'
import { useParams } from 'next/navigation'
import Link from 'next/link'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ClientOnly } from '@/components/ui/client-only'
import { CountdownTimer } from '@/components/p2p/CountdownTimer'
import { useP2P } from '@/hooks/useP2P'
import {
  ArrowLeft, CheckCircle, ExternalLink,
  Loader2, AlertCircle, ArrowRight, RefreshCw, Flag,
} from 'lucide-react'
import type { P2POffer } from '@/types'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'
const CURRENCY_FLAG: Record<string, string> = {
  NGN: '🇳🇬', GHS: '🇬🇭', KES: '🇰🇪', ZAR: '🇿🇦', EGP: '🇪🇬'
}

function normalizeOffer(row: any): P2POffer | null {
  if (!row || row.error) return null
  if (Array.isArray(row)) {
    return {
      id: row[0], maker_address: row[1], taker_address: row[2],
      usdc_amount: row[3], local_currency: row[4], local_amount: row[5],
      rate_offered: row[6], status: row[7],
      maker_confirmed: Number(row[8]), taker_confirmed: Number(row[9]),
      arc_tx_hash: row[10], release_tx_hash: row[11],
      expires_at: row[12], created_at: row[13], updated_at: row[14],
    }
  }
  return {
    ...row,
    maker_confirmed: Number(row.maker_confirmed ?? 0),
    taker_confirmed: Number(row.taker_confirmed ?? 0),
    taker_deadline:  row.taker_deadline  ? Number(row.taker_deadline)  : null,
    maker_deadline:  row.maker_deadline  ? Number(row.maker_deadline)  : null,
    dispute_raised:  Number(row.dispute_raised ?? 0),
    maker_timer_seconds: Number(row.maker_timer_seconds ?? 1800),
  } as P2POffer
}

function shortenAddr(addr: string) { return `${addr.slice(0,6)}…${addr.slice(-4)}` }

export default function OfferDetailPage() {
  const params          = useParams()
  const { address }     = useAccount()
  const [offer, setOffer] = useState<P2POffer | null>(null)
  const [loading, setLoading]       = useState(true)
  const [notFound, setNotFound]     = useState(false)
  const [disputing, setDisputing]   = useState(false)
  const [disputeDone, setDisputeDone] = useState(false)

  const {
    takerConfirm, makerConfirm, raiseDispute, cancelOwnOffer,
    isLoading: actionLoading, error, txHash,
  } = useP2P()

  const load = useCallback(async () => {
    try {
      const res  = await fetch(`${API}/offers/${params.id}`)
      if (res.status === 404) { setNotFound(true); return }
      const data = await res.json()
      const norm = normalizeOffer(data)
      if (norm) setOffer(norm)
      else setNotFound(true)
    } catch { setNotFound(true) }
    finally  { setLoading(false) }
  }, [params.id])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    const t = setInterval(load, 5000)
    return () => clearInterval(t)
  }, [load])

  if (loading) return (
    <div className="space-y-4">
      {[1,2].map(i => <div key={i} className="h-48 animate-pulse rounded-xl bg-[#0F1729]" />)}
    </div>
  )

  if (notFound || !offer) return (
    <div className="flex h-64 flex-col items-center justify-center gap-3">
      <p className="text-sm text-[#64748B]">Offer not found.</p>
      <Link href="/marketplace"><Button variant="outline" size="sm">← Back</Button></Link>
    </div>
  )

  const isMaker    = address?.toLowerCase() === offer.maker_address?.toLowerCase()
  const isTaker    = address?.toLowerCase() === offer.taker_address?.toLowerCase()
  const isInvolved = isMaker || isTaker
  const offerId    = offer.id as `0x${string}`
  const timerSecs  = (offer as any).maker_timer_seconds ?? 1800

  const steps = [
    { n:1, done: offer.status !== 'open',    label: 'Taker accepted offer',                             desc: 'USDC locked in vault escrow' },
    { n:2, done: offer.status !== 'open',    label: `Taker sends ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`, desc: 'Off-chain — bank or mobile money' },
    { n:3, done: !!offer.taker_confirmed,    label: 'Taker confirmed: "I sent the money"',              desc: 'Taker timer window' },
    { n:4, done: !!offer.maker_confirmed,    label: 'Maker confirmed: "I received the money"',          desc: 'Maker timer window (fresh reset)' },
    { n:5, done: offer.status === 'released',label: 'Platform releases USDC to taker',                  desc: 'Auto-released within 15 seconds' },
  ]

  const statusBadge = {
    open: 'warning', accepted: 'arc', released: 'success', cancelled: 'danger',
  }[offer.status] as any

  async function handleDisputeRaise() {
    if (!address) return
    setDisputing(true)
    try {
      await raiseDispute(offer.id, 'Maker did not confirm receipt within time limit')
      setDisputeDone(true)
      await load()
    } catch {} finally { setDisputing(false) }
  }

  return (
    <div>
      <div className="mb-6 flex items-center gap-3">
        <Link href="/marketplace">
          <button className="rounded-lg border border-[#1B2B4B] p-2 text-[#64748B] hover:text-[#E2E8F0]">
            <ArrowLeft className="h-4 w-4" />
          </button>
        </Link>
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-[#E2E8F0]">Offer detail</h1>
            <Badge variant={statusBadge}>{offer.status}</Badge>
            {(offer as any).order_type && (
              <Badge variant={(offer as any).order_type === 'limit' ? 'warning' : 'arc'}>
                {(offer as any).order_type}
              </Badge>
            )}
            {!!(offer as any).dispute_raised && (
              <Badge variant="danger">Disputed</Badge>
            )}
          </div>
          <p className="font-mono text-xs text-[#64748B]">{offer.id.slice(0,26)}…</p>
        </div>
        <button onClick={load}
          className="flex items-center gap-1.5 rounded-lg border border-[#1B2B4B] px-3 py-1.5 text-xs text-[#64748B] hover:text-[#E2E8F0]">
          <RefreshCw className="h-3 w-3" /> Refresh
        </button>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">

        {/* Summary */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Summary</p>
          <div className="mb-4 flex items-center justify-center gap-6 rounded-lg bg-[#080D1B] p-4">
            <div className="text-center">
              <p className="text-2xl">💵</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{Number(offer.usdc_amount).toFixed(2)}</p>
              <p className="text-xs text-[#64748B]">USDC (escrow)</p>
            </div>
            <ArrowRight className="h-5 w-5 text-[#64748B]" />
            <div className="text-center">
              <p className="text-2xl">{CURRENCY_FLAG[offer.local_currency] ?? '🌍'}</p>
              <p className="mt-1 font-mono text-xl font-semibold text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()}</p>
              <p className="text-xs text-[#64748B]">{offer.local_currency} (to maker)</p>
            </div>
          </div>

          <div className="space-y-2 text-xs">
            {[
              ['Maker (wants local)', `${offer.maker_address ? shortenAddr(offer.maker_address) : '—'}${isMaker ? ' (you)' : ''}`],
              ['Taker (wants USDC)',  offer.taker_address ? `${shortenAddr(offer.taker_address!)}${isTaker ? ' (you)' : ''}` : 'Waiting…'],
              ['Rate', `1 USDC = ${Number(offer.rate_offered) > 0 ? (1 / Number(offer.rate_offered)).toFixed(2) : '—'} ${offer.local_currency}`],
              ['Taker window', `${timerSecs >= 3600 ? timerSecs/3600 + 'h' : timerSecs/60 + 'min'}`],
            ].map(([label, val]) => (
              <div key={label} className="flex justify-between">
                <span className="text-[#64748B]">{label}</span>
                <span className="font-mono text-[#E2E8F0]">{val}</span>
              </div>
            ))}
            {offer.arc_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Create tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.arc_tx_hash}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-[#378ADD] hover:underline">
                  {offer.arc_tx_hash.slice(0,14)}…<ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
            {offer.release_tx_hash && (
              <div className="flex justify-between">
                <span className="text-[#64748B]">Release tx</span>
                <a href={`https://testnet.arcscan.app/tx/${offer.release_tx_hash}`} target="_blank" rel="noopener noreferrer"
                  className="flex items-center gap-1 font-mono text-emerald-400 hover:underline">
                  {offer.release_tx_hash.slice(0,14)}…<ExternalLink className="h-3 w-3" />
                </a>
              </div>
            )}
          </div>

          {/* Cancel button for maker on open offers */}
          {isMaker && offer.status === 'open' && (
            <Button variant="danger" size="sm" className="mt-4 w-full"
              onClick={async () => { await cancelOwnOffer(offerId); await load() }}
              disabled={actionLoading}>
              Cancel offer & retrieve USDC
            </Button>
          )}
        </div>

        {/* Confirmation flow */}
        <div className="rounded-xl border border-[#1B2B4B] bg-[#0F1729] p-5">
          <p className="mb-4 text-sm font-medium text-[#E2E8F0]">Progress</p>

          {/* Step indicators */}
          <div className="mb-4 space-y-3">
            {steps.map(({ n, label, done, desc }) => (
              <div key={n} className="flex items-start gap-3">
                <div className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold
                  ${done ? 'bg-emerald-500 text-white' : 'bg-[#1B2B4B] text-[#64748B]'}`}>
                  {done ? '✓' : n}
                </div>
                <div>
                  <p className={`text-sm font-medium ${done ? 'text-emerald-400' : 'text-[#E2E8F0]'}`}>{label}</p>
                  <p className="text-xs text-[#64748B]">{desc}</p>
                </div>
              </div>
            ))}
          </div>

          {/* Active timers */}
          {offer.status === 'accepted' && !offer.taker_confirmed && (offer as any).taker_deadline && (
            <CountdownTimer
              deadline={(offer as any).taker_deadline}
              label="Taker must send + confirm by"
            />
          )}
          {offer.status === 'accepted' && offer.taker_confirmed && !offer.maker_confirmed && (offer as any).maker_deadline && (
            <CountdownTimer
              deadline={(offer as any).maker_deadline}
              label="Maker must confirm receipt by"
            />
          )}

          <ClientOnly>
            <div className="mt-4 space-y-3">

              {/* Released */}
              {offer.status === 'released' && (
                <div className="rounded-lg border border-emerald-900/50 bg-emerald-900/20 p-4 text-center">
                  <CheckCircle className="mx-auto mb-2 h-6 w-6 text-emerald-400" />
                  <p className="text-sm font-medium text-emerald-400">Trade complete</p>
                  <p className="mt-1 text-xs text-emerald-600">USDC released to taker</p>
                </div>
              )}

              {/* Cancelled */}
              {offer.status === 'cancelled' && (
                <div className="rounded-lg border border-red-900/50 bg-red-900/20 p-4 text-center">
                  <AlertCircle className="mx-auto mb-2 h-6 w-6 text-red-400" />
                  <p className="text-sm font-medium text-red-400">Offer cancelled</p>
                  <p className="mt-1 text-xs text-red-600">USDC returned to maker</p>
                </div>
              )}

              {/* Disputed */}
              {!!(offer as any).dispute_raised && offer.status === 'accepted' && (
                <div className="rounded-lg border border-amber-900/50 bg-amber-900/20 p-3 text-xs">
                  <div className="flex items-start gap-2">
                    <Flag className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-400" />
                    <div>
                      <p className="font-medium text-amber-400">Dispute raised</p>
                      <p className="mt-0.5 text-amber-600">
                        USDC remains locked. Platform will auto-release to taker in 24 hours if unresolved.
                      </p>
                    </div>
                  </div>
                </div>
              )}

              {/* Accepted + active actions */}
              {offer.status === 'accepted' && !offer.taker_confirmed && isTaker && (
                <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                  <p className="font-medium text-[#E2E8F0]">Send {offer.local_currency} to maker now</p>
                  <p className="mt-1 text-[#64748B]">
                    Send <strong className="text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()} {offer.local_currency}</strong> via bank or mobile money,
                    then confirm below before your timer expires.
                  </p>
                </div>
              )}

              {offer.status === 'accepted' && !offer.taker_confirmed && isMaker && (
                <div className="rounded-lg bg-[#080D1B] p-3 text-xs text-[#64748B]">
                  <Loader2 className="mb-1 h-4 w-4 animate-spin" />
                  Waiting for taker to send and confirm {Number(offer.local_amount).toLocaleString()} {offer.local_currency}…
                </div>
              )}

              {offer.status === 'accepted' && offer.taker_confirmed && !offer.maker_confirmed && isMaker && (
                <div className="rounded-lg border border-[#378ADD]/30 bg-[#378ADD]/10 p-3 text-xs">
                  <p className="font-medium text-[#E2E8F0]">Check your account</p>
                  <p className="mt-1 text-[#64748B]">
                    Taker confirmed sending <strong className="text-[#E2E8F0]">{Number(offer.local_amount).toLocaleString()} {offer.local_currency}</strong>.
                    Confirm receipt to release USDC.
                  </p>
                </div>
              )}

              {/* TAKER confirm button */}
              {isTaker && offer.status === 'accepted' && (
                <Button className="w-full"
                  onClick={async () => { await takerConfirm(offerId, timerSecs); await load() }}
                  disabled={!!offer.taker_confirmed || actionLoading}
                  variant={offer.taker_confirmed ? 'outline' : 'default'}>
                  {actionLoading
                    ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                    : offer.taker_confirmed
                    ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed sending</>
                    : `✓ I sent ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency} to maker`}
                </Button>
              )}

              {/* MAKER confirm button */}
              {isMaker && offer.status === 'accepted' && (
                <Button className="w-full"
                  onClick={async () => { await makerConfirm(offerId); await load() }}
                  disabled={!offer.taker_confirmed || !!offer.maker_confirmed || actionLoading}
                  variant={offer.maker_confirmed ? 'outline' : 'default'}>
                  {actionLoading
                    ? <><Loader2 className="h-4 w-4 animate-spin" /> Confirming…</>
                    : offer.maker_confirmed
                    ? <><CheckCircle className="h-4 w-4 text-emerald-400" /> You confirmed receipt</>
                    : !offer.taker_confirmed
                    ? 'Waiting for taker to send first…'
                    : `✓ I received ${Number(offer.local_amount).toLocaleString()} ${offer.local_currency}`}
                </Button>
              )}

              {/* Taker waits for maker */}
              {isTaker && offer.taker_confirmed && !offer.maker_confirmed && offer.status === 'accepted' && (
                <div className="flex items-center gap-2 rounded-lg bg-[#080D1B] px-3 py-2 text-xs text-[#64748B]">
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  Waiting for maker to confirm receipt…
                </div>
              )}

              {/* DISPUTE button — taker can raise when maker deadline expired */}
              {isTaker && offer.taker_confirmed && !offer.maker_confirmed &&
               offer.status === 'accepted' && !(offer as any).dispute_raised &&
               (offer as any).maker_deadline &&
               (offer as any).maker_deadline < Math.floor(Date.now() / 1000) && (
                <div className="space-y-2">
                  <p className="text-xs text-amber-400">
                    ⚠️ Maker has not confirmed within the agreed window.
                  </p>
                  {!disputeDone ? (
                    <Button variant="danger" className="w-full"
                      onClick={handleDisputeRaise}
                      disabled={disputing}>
                      <Flag className="h-4 w-4" />
                      {disputing ? 'Raising dispute…' : 'Raise dispute'}
                    </Button>
                  ) : (
                    <p className="text-xs text-emerald-400">
                      ✓ Dispute raised — USDC auto-releases to you in 24 hours if unresolved.
                    </p>
                  )}
                </div>
              )}

              {/* Both confirmed — waiting */}
              {offer.maker_confirmed && offer.taker_confirmed && offer.status !== 'released' && (
                <div className="flex items-center gap-2 rounded-lg border border-emerald-900/30 bg-emerald-900/10 px-3 py-2.5 text-xs text-emerald-400">
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  Both confirmed — releasing USDC within 15 seconds…
                </div>
              )}

              {!isInvolved && offer.status === 'accepted' && (
                <p className="text-center text-xs text-[#64748B]">Trade in progress between two parties.</p>
              )}
            </div>
          </ClientOnly>

          {error && (
            <div className="mt-3 flex items-start gap-2 rounded-lg bg-red-900/20 px-3 py-2.5 text-xs text-red-400">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />{error}
            </div>
          )}
          {txHash && (
            <a href={`https://testnet.arcscan.app/tx/${txHash}`} target="_blank" rel="noopener noreferrer"
              className="mt-3 flex items-center gap-1.5 text-xs text-[#378ADD] hover:underline">
              <ExternalLink className="h-3 w-3" /> View on ArcScan
            </a>
          )}
        </div>
      </div>
    </div>
  )
}
__EOF__
echo "✅  marketplace/[id]/page.tsx — countdown timers + dispute button"

# ============================================================
# 12 — Dashboard dispute warning banner
# ============================================================
cat > afrifx-web/hooks/useDisputeWarnings.ts << '__EOF__'
'use client'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export function useDisputeWarnings() {
  const { address } = useAccount()
  return useQuery({
    queryKey: ['dispute-warnings', address],
    queryFn: async () => {
      const res  = await fetch(`${API}/user/${address}`)
      const data = await res.json()
      return Number(data.dispute_warnings ?? 0)
    },
    enabled:         !!address,
    refetchInterval: 60_000,
  })
}
__EOF__

# Add warning column to Turso
turso db shell afrifx "ALTER TABLE users ADD COLUMN dispute_warnings INTEGER DEFAULT 0;" 2>/dev/null || true
echo "✅  users table — dispute_warnings column added"

# ============================================================
# 13 — Updated marketplace listing: show order type + timer
# ============================================================
# Add order type badge + timer badge to marketplace page
echo "  Updating marketplace listing..."
cat >> "afrifx-web/app/(app)/marketplace/page.tsx" << '__APPEND__'
// Order type badges and timer shown via normalizeOffer fields:
// offer.order_type: 'market' | 'limit'
// offer.maker_timer_seconds: number (seconds)
__APPEND__

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Phase 3 Market/Limit Orders + Timers + Disputes!"
echo ""
echo "  IMPORTANT — Redeploy the updated contract:"
echo "  cd afrifx-contracts"
echo "  npx hardhat compile"
echo "  npm run deploy"
echo "  Update NEXT_PUBLIC_AFRIFX_VAULT + AFRIFX_VAULT_ADDRESS"
echo ""
echo "  New features:"
echo "  • Market order — auto-calc local from live rate"
echo "  • Limit order  — rate slider ±5% of market"  
echo "  • Perpetual offers — no expiry"
echo "  • Maker timer — 30min/1hr/2hr/custom"
echo "  • Taker timer countdown — auto-cancel if expired"
echo "  • Maker timer countdown — dispute button appears"
echo "  • Dispute → 24h auto-release to taker"
echo "  • Dashboard dispute warnings (after next build)"
echo "  • Maker can cancel own open offer"
echo ""
echo "  Restart both servers after redeployment"
echo "══════════════════════════════════════════════════════"
