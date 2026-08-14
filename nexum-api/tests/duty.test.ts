/**
 * Duty window logic.
 *
 * This is the security model behind the dispute gate: only a sub-admin inside
 * their scheduled window (and who has resumed duty) may accept or resolve a
 * dispute, and disputes move real money. The window maths is pure and easy to
 * get subtly wrong around boundaries, midnight, and timezones, so it's tested
 * directly.
 *
 * `isOnDuty` itself is not covered here because it hits the database; these
 * cover the two pure functions it is built on.
 */

import { describe, it, expect } from 'vitest'
import { validateWindow, windowAt, MAX_DUTY_MINUTES } from '../src/lib/duty'

const DAYS_ALL = [0, 1, 2, 3, 4, 5, 6]

/** Unix seconds for a UTC wall-clock time. */
function utc(y: number, m: number, d: number, hh = 0, mm = 0): number {
  return Math.floor(Date.UTC(y, m - 1, d, hh, mm, 0) / 1000)
}

describe('validateWindow', () => {
  it('accepts a normal window on recurring days', () => {
    expect(validateWindow({ startMin: 540, endMin: 720, days: [1, 2, 3] })).toBeNull()
  })

  it('accepts a window with only specific dates and no recurring days', () => {
    expect(validateWindow({
      startMin: 540, endMin: 720, days: [], dates: ['2026-08-11'],
    })).toBeNull()
  })

  it('requires both start and end', () => {
    expect(validateWindow({ endMin: 720, days: [1] })).toBe('Working hours are required')
    expect(validateWindow({ startMin: 540, days: [1] })).toBe('Working hours are required')
  })

  it('rejects an end at or before the start', () => {
    expect(validateWindow({ startMin: 720, endMin: 720, days: [1] }))
      .toBe('End time must be after start time')
    expect(validateWindow({ startMin: 720, endMin: 600, days: [1] }))
      .toBe('End time must be after start time')
  })

  it('allows exactly the maximum session length but not a minute more', () => {
    const start = 0
    expect(validateWindow({ startMin: start, endMin: start + MAX_DUTY_MINUTES, days: [1] }))
      .toBeNull()
    expect(validateWindow({ startMin: start, endMin: start + MAX_DUTY_MINUTES + 1, days: [1] }))
      .toBe('Working session cannot exceed 6 hours')
  })

  it('rejects times outside a single day', () => {
    expect(validateWindow({ startMin: -1, endMin: 60, days: [1] }))
      .toBe('Working hours must be within a single day')
    expect(validateWindow({ startMin: 0, endMin: 1440, days: [1] }))
      .toBe('Working hours must be within a single day')
  })

  it('requires at least one day or date, so a window can never match nothing', () => {
    expect(validateWindow({ startMin: 540, endMin: 720 }))
      .toBe('Choose at least one recurring day or a specific date')
    expect(validateWindow({ startMin: 540, endMin: 720, days: [], dates: [] }))
      .toBe('Choose at least one recurring day or a specific date')
  })

  // A window that spans midnight would have endMin < startMin, which is
  // rejected. Worth pinning: the gate assumes windows live inside one UTC day.
  it('rejects a window that would wrap past midnight', () => {
    expect(validateWindow({ startMin: 1380, endMin: 120, days: [1] }))
      .toBe('End time must be after start time')
  })
})

describe('windowAt', () => {
  // 2026-08-10 is a Monday (UTC).
  const monday = { y: 2026, m: 8, d: 10, dow: 1 }
  const win = { startMin: 540, endMin: 720, days: [monday.dow], dates: [] } // 09:00-12:00

  it('returns the window when inside it on a scheduled day', () => {
    const at  = utc(monday.y, monday.m, monday.d, 10, 0)
    const got = windowAt(win, at)
    expect(got).not.toBeNull()
    expect(got!.start).toBe(utc(monday.y, monday.m, monday.d, 9, 0))
    expect(got!.end).toBe(utc(monday.y, monday.m, monday.d, 12, 0))
  })

  it('is inclusive of the start instant', () => {
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 9, 0))).not.toBeNull()
  })

  // The end is exclusive: at exactly 12:00 the admin is OFF duty. This is the
  // boundary that decides whether someone can still accept a dispute.
  it('is exclusive of the end instant', () => {
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 11, 59))).not.toBeNull()
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 12, 0))).toBeNull()
  })

  it('returns null before the window opens', () => {
    expect(windowAt(win, utc(monday.y, monday.m, monday.d, 8, 59))).toBeNull()
  })

  it('returns null on a day that is not scheduled', () => {
    // 2026-08-11 is a Tuesday; the window only covers Monday.
    expect(windowAt(win, utc(2026, 8, 11, 10, 0))).toBeNull()
  })

  it('matches a specific date even when the weekday is not scheduled', () => {
    const w = { startMin: 540, endMin: 720, days: [], dates: ['2026-08-11'] }
    expect(windowAt(w, utc(2026, 8, 11, 10, 0))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 12, 10, 0))).toBeNull()
  })

  it('treats days and dates as a union, not an intersection', () => {
    const w = { startMin: 540, endMin: 720, days: [1], dates: ['2026-08-12'] }
    expect(windowAt(w, utc(2026, 8, 10, 10, 0))).not.toBeNull() // Monday, via days
    expect(windowAt(w, utc(2026, 8, 12, 10, 0))).not.toBeNull() // Wednesday, via dates
    expect(windowAt(w, utc(2026, 8, 13, 10, 0))).toBeNull()     // neither
  })

  it('works at a midnight-adjacent window without leaking into the previous day', () => {
    const w = { startMin: 0, endMin: 60, days: DAYS_ALL, dates: [] } // 00:00-01:00
    expect(windowAt(w, utc(2026, 8, 10, 0, 0))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 10, 0, 59))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 10, 1, 0))).toBeNull()
    // 23:59 the night before is a different day's window, not this one
    expect(windowAt(w, utc(2026, 8, 9, 23, 59))).toBeNull()
  })

  it('anchors the window to the UTC day, not the host timezone', () => {
    // Runs identically regardless of TZ because windowAt uses getUTC* only.
    const w = { startMin: 60, endMin: 120, days: DAYS_ALL, dates: [] } // 01:00-02:00 UTC
    expect(windowAt(w, utc(2026, 8, 10, 1, 30))).not.toBeNull()
    expect(windowAt(w, utc(2026, 8, 10, 23, 30))).toBeNull()
  })
})
