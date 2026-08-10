/**
 * Signup validation.
 *
 * These rules decide what identities can exist, so the edge cases matter:
 * case handling drives the uniqueness guarantee (the database constraint
 * is case-sensitive), and the username rules stop impersonation.
 */

import { describe, it, expect } from 'vitest'
import {
  validateUsername, validateEmail, validateName, validateSignup,
  normalizeUsername, normalizeEmail, normalizeName,
  USERNAME_MIN, USERNAME_MAX,
} from '../src/lib/accountValidation'

describe('normalization', () => {
  it('lowercases and trims usernames and emails', () => {
    expect(normalizeUsername('  AdaLovelace ')).toBe('adalovelace')
    expect(normalizeEmail('  Ada@Example.COM ')).toBe('ada@example.com')
  })

  // This is what makes the UNIQUE constraint meaningful: SQLite compares
  // case-sensitively, so "Ada" and "ada" would otherwise both be insertable.
  it('collapses case so two spellings cannot both be registered', () => {
    expect(normalizeUsername('ADA')).toBe(normalizeUsername('ada'))
    expect(normalizeEmail('A@B.COM')).toBe(normalizeEmail('a@b.com'))
  })

  it('collapses internal whitespace in names but keeps case', () => {
    expect(normalizeName('  Ada   King  Lovelace ')).toBe('Ada King Lovelace')
  })
})

describe('validateUsername', () => {
  it('accepts a normal username', () => {
    expect(validateUsername('ada_lovelace')).toBeNull()
    expect(validateUsername('ada99')).toBeNull()
  })

  it('accepts regardless of the case typed', () => {
    expect(validateUsername('AdaLovelace')).toBeNull()
  })

  it('enforces length bounds', () => {
    expect(validateUsername('a'.repeat(USERNAME_MIN - 1))).toMatch(/at least/)
    expect(validateUsername('a'.repeat(USERNAME_MIN))).toBeNull()
    expect(validateUsername('a'.repeat(USERNAME_MAX))).toBeNull()
    expect(validateUsername('a'.repeat(USERNAME_MAX + 1))).toMatch(/or fewer/)
  })

  it('requires a leading letter, so usernames never look like ids or addresses', () => {
    expect(validateUsername('1ada')).toMatch(/start with a letter/)
    expect(validateUsername('_ada')).toMatch(/start with a letter/)
    expect(validateUsername('0xabc')).toMatch(/start with a letter/)
  })

  it('rejects characters that could be used to spoof another user', () => {
    expect(validateUsername('ada lovelace')).not.toBeNull()  // space
    expect(validateUsername('ada.lovelace')).not.toBeNull()  // dot
    expect(validateUsername('ada-lovelace')).not.toBeNull()  // hyphen
    expect(validateUsername('ada@home')).not.toBeNull()
    expect(validateUsername('adá')).not.toBeNull()           // lookalike accent
  })

  it('rejects trailing and doubled underscores', () => {
    expect(validateUsername('ada_')).toMatch(/end with an underscore/)
    expect(validateUsername('ada__x')).toMatch(/two underscores/)
  })

  it('rejects an empty or whitespace-only username', () => {
    expect(validateUsername('')).toMatch(/Choose a username/)
    expect(validateUsername('   ')).toMatch(/Choose a username/)
  })
})

describe('validateEmail', () => {
  it('accepts ordinary addresses', () => {
    expect(validateEmail('ada@example.com')).toBeNull()
    expect(validateEmail('Ada.Lovelace@sub.example.co.uk')).toBeNull()
  })

  // Plus-addressing is widely used and must not be rejected.
  it('accepts plus-addressing and unusual but valid local parts', () => {
    expect(validateEmail('ada+afrifx@example.com')).toBeNull()
    expect(validateEmail("ada'brien@example.com")).toBeNull()
  })

  it('rejects obvious typos', () => {
    expect(validateEmail('ada')).not.toBeNull()
    expect(validateEmail('ada@')).not.toBeNull()
    expect(validateEmail('ada@example')).not.toBeNull()   // no TLD
    expect(validateEmail('a@b@c.com')).not.toBeNull()     // two @
    expect(validateEmail('ada @example.com')).not.toBeNull()
  })

  it('rejects an over-long address', () => {
    expect(validateEmail('a'.repeat(250) + '@example.com')).toMatch(/too long/)
  })
})

describe('validateName', () => {
  it('accepts real-world name shapes', () => {
    expect(validateName("O'Brien", 'Last')).toBeNull()
    expect(validateName('Anne-Marie', 'First')).toBeNull()
    expect(validateName('Ngozi', 'First')).toBeNull()
    expect(validateName('Оксана', 'First')).toBeNull()   // non-Latin script
  })

  it('rejects digits and markup characters', () => {
    expect(validateName('Ada2', 'First')).toMatch(/cannot contain numbers/)
    expect(validateName('<script>', 'First')).toMatch(/invalid characters/)
  })

  it('requires a value', () => {
    expect(validateName('', 'First')).toMatch(/Enter your first name/)
    expect(validateName('   ', 'Last')).toMatch(/Enter your last name/)
  })
})

describe('validateSignup', () => {
  it('returns no errors for a valid submission', () => {
    expect(validateSignup({
      firstName: 'Ada', lastName: 'Lovelace',
      username: 'ada_lovelace', email: 'ada@example.com',
    })).toEqual({})
  })

  // The form should show every problem at once, not one per submit.
  it('reports every invalid field together', () => {
    const errors = validateSignup({
      firstName: '', lastName: '', username: '1', email: 'nope',
    })
    expect(Object.keys(errors).sort())
      .toEqual(['email', 'firstName', 'lastName', 'username'])
  })

  it('treats missing fields as invalid rather than skipping them', () => {
    expect(Object.keys(validateSignup({})).sort())
      .toEqual(['email', 'firstName', 'lastName', 'username'])
  })
})
