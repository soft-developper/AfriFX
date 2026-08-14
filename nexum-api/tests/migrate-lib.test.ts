/**
 * Migration statement splitting.
 *
 * The runner executes statements one at a time, so this splitter decides what
 * actually gets run. If it splits inside a string literal or a comment, a
 * migration either fails or, worse, applies a truncated statement. These cases
 * come from patterns that appear in the real migration files.
 */

import { describe, it, expect } from 'vitest'
import { splitStatements, loadMigrations, checksum } from '../src/db/migrate-lib'

describe('splitStatements', () => {
  it('splits simple statements', () => {
    expect(splitStatements('SELECT 1; SELECT 2;')).toEqual(['SELECT 1', 'SELECT 2'])
  })

  it('does not require a trailing semicolon', () => {
    expect(splitStatements('SELECT 1')).toEqual(['SELECT 1'])
  })

  it('ignores empty statements from doubled or trailing semicolons', () => {
    expect(splitStatements('SELECT 1;;  ;SELECT 2;')).toEqual(['SELECT 1', 'SELECT 2'])
  })

  it('does not split on a semicolon inside a single-quoted string', () => {
    const sql = "INSERT INTO t (msg) VALUES ('a;b'); SELECT 1;"
    expect(splitStatements(sql)).toEqual([
      "INSERT INTO t (msg) VALUES ('a;b')",
      'SELECT 1',
    ])
  })

  it('handles escaped quotes inside strings', () => {
    // 'it''s;fine' is one string containing a semicolon
    const sql = "INSERT INTO t (msg) VALUES ('it''s;fine'); SELECT 1;"
    const out = splitStatements(sql)
    expect(out).toHaveLength(2)
    expect(out[0]).toContain("it''s;fine")
  })

  it('does not split on a semicolon inside a double-quoted identifier', () => {
    const sql = 'CREATE TABLE "weird;name" (id TEXT); SELECT 1;'
    expect(splitStatements(sql)).toHaveLength(2)
  })

  it('does not split on a semicolon inside a line comment', () => {
    // This pattern is common in the real files: prose comments with semicolons.
    const sql = `
      -- run this; then that
      CREATE TABLE a (id TEXT);
      SELECT 1;
    `
    const out = splitStatements(sql)
    expect(out).toHaveLength(2)
    expect(out[0]).toContain('CREATE TABLE a')
  })

  it('does not split on a semicolon inside a block comment', () => {
    const sql = `
      /* one; two; three */
      CREATE TABLE a (id TEXT);
    `
    expect(splitStatements(sql)).toHaveLength(1)
  })

  it('drops fragments that are only comments', () => {
    // A file ending in a trailing comment must not produce an empty statement,
    // which libSQL would reject.
    const sql = `
      CREATE TABLE a (id TEXT);
      -- trailing note, nothing executable after this
    `
    expect(splitStatements(sql)).toHaveLength(1)
  })

  it('returns nothing for a comment-only file', () => {
    expect(splitStatements('-- just a note\n/* and another */')).toEqual([])
  })

  it('keeps a multi-line statement intact', () => {
    const sql = `CREATE TABLE a (
      id   TEXT PRIMARY KEY,
      name TEXT
    );`
    const out = splitStatements(sql)
    expect(out).toHaveLength(1)
    expect(out[0]).toContain('PRIMARY KEY')
  })
})

describe('migration files', () => {
  const migrations = loadMigrations()

  it('there is at least one migration', () => {
    expect(migrations.length).toBeGreaterThan(0)
  })

  it('every file is named NNNN_snake_case.sql', () => {
    // loadMigrations throws on a bad name, so reaching here is the assertion;
    // this also pins the shape for anyone adding one.
    for (const m of migrations) {
      expect(m.file).toMatch(/^\d{4}_[a-z0-9_]+\.sql$/)
    }
  })

  it('version numbers are unique', () => {
    const versions = migrations.map(m => m.version)
    expect(new Set(versions).size).toBe(versions.length)
  })

  it('version numbers are contiguous from 0001, so none was lost in a rename', () => {
    const nums = migrations.map(m => Number(m.version)).sort((a, b) => a - b)
    expect(nums[0]).toBe(1)
    for (let i = 1; i < nums.length; i++) {
      expect(nums[i]).toBe(nums[i - 1] + 1)
    }
  })

  it('every migration contains at least one executable statement', () => {
    for (const m of migrations) {
      expect(splitStatements(m.sql).length, `${m.file} has no statements`)
        .toBeGreaterThan(0)
    }
  })

  it('checksums are stable for identical content', () => {
    expect(checksum('SELECT 1')).toBe(checksum('SELECT 1'))
    expect(checksum('SELECT 1')).not.toBe(checksum('SELECT 2'))
  })
})
