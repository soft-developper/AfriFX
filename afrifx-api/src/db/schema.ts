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
