/**
 * Signup field validation.
 *
 * Pure and dependency-free so it can be unit tested exhaustively and
 * reused by the frontend's live availability check. Everything here
 * normalizes before validating, because the database uniqueness
 * constraints are case-sensitive: two accounts differing only in case
 * would both be insertable and would then be indistinguishable to a
 * user reading them.
 */

export const USERNAME_MIN = 3
export const USERNAME_MAX = 20

/** Lowercase and trim. Always store and compare the normalized form. */
export const normalizeUsername = (raw: string) => String(raw ?? '').trim().toLowerCase()
export const normalizeEmail    = (raw: string) => String(raw ?? '').trim().toLowerCase()

/** Collapse internal whitespace, trim ends. Preserves case for display. */
export const normalizeName = (raw: string) =>
  String(raw ?? '').replace(/\s+/g, ' ').trim()

/**
 * Returns an error message, or null when valid.
 *
 * Rules: 3-20 chars, letters/digits/underscore only, must start with a
 * letter, no leading/trailing/double underscore. Starting with a letter
 * keeps usernames distinguishable from ids and addresses in URLs.
 */
export function validateUsername(raw: string): string | null {
  const u = normalizeUsername(raw)
  if (!u) return 'Choose a username'
  if (u.length < USERNAME_MIN) return `Username must be at least ${USERNAME_MIN} characters`
  if (u.length > USERNAME_MAX) return `Username must be ${USERNAME_MAX} characters or fewer`
  if (!/^[a-z]/.test(u))       return 'Username must start with a letter'
  if (!/^[a-z0-9_]+$/.test(u)) return 'Username can only use letters, numbers and underscores'
  if (u.endsWith('_'))         return 'Username cannot end with an underscore'
  if (u.includes('__'))        return 'Username cannot contain two underscores in a row'
  return null
}

/**
 * Deliberately permissive. Over-strict email regexes reject valid
 * addresses (plus-addressing, new TLDs, unicode domains) and the
 * address is proven anyway by Circle's OTP or by Google, so this only
 * needs to catch obvious typos.
 */
export function validateEmail(raw: string): string | null {
  const e = normalizeEmail(raw)
  if (!e) return 'Enter your email address'
  if (e.length > 254) return 'Email address is too long'
  if (/\s/.test(e)) return 'Email address cannot contain spaces'
  // exactly one @, something before it, and a dotted domain after it
  if (!/^[^@]+@[^@]+\.[^@.]+$/.test(e)) return 'Enter a valid email address'
  return null
}

export function validateName(raw: string, field: 'First' | 'Last'): string | null {
  const n = normalizeName(raw)
  if (!n) return `Enter your ${field.toLowerCase()} name`
  if (n.length > 60) return `${field} name is too long`
  // Allow letters, spaces, apostrophes, hyphens, periods: covers
  // O'Brien, Anne-Marie, Jr. and non-Latin scripts.
  if (/[0-9]/.test(n)) return `${field} name cannot contain numbers`
  if (/[<>@{}\\/]/.test(n)) return `${field} name contains invalid characters`
  return null
}

export interface SignupInput {
  firstName: string
  lastName:  string
  username:  string
  email:     string
}

/** Validate every field at once. Returns field -> message, empty when valid. */
export function validateSignup(input: Partial<SignupInput>): Record<string, string> {
  const errors: Record<string, string> = {}
  const first = validateName(input.firstName ?? '', 'First')
  const last  = validateName(input.lastName ?? '', 'Last')
  const user  = validateUsername(input.username ?? '')
  const email = validateEmail(input.email ?? '')
  if (first) errors.firstName = first
  if (last)  errors.lastName  = last
  if (user)  errors.username  = user
  if (email) errors.email     = email
  return errors
}
