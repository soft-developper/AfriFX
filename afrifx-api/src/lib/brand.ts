/**
 * Brand strings in one place.
 *
 * The rebrand to Nexum is deliberately deferred (decision D5), which
 * normally means rewriting copy twice. Routing every user-visible brand
 * string through here makes the rename a one-file change instead of a
 * grep across the codebase.
 *
 * Use these anywhere a name is shown to a user: emails, page titles,
 * support copy. Do NOT use them for things that must stay stable when
 * the name changes, such as on-chain Memo tags or database values.
 */

export const BRAND = {
  /** Display name, e.g. in email copy and headings. */
  name: process.env.BRAND_NAME ?? 'AfriFX',

  /** Lowercase machine-ish form, e.g. in URLs or slugs. */
  slug: process.env.BRAND_SLUG ?? 'afrifx',

  /** Public site, used in emails and links. */
  url: process.env.BRAND_URL ?? 'https://afrifx.vercel.app',

  /** From address for transactional mail. */
  supportEmail: process.env.BRAND_SUPPORT_EMAIL ?? 'support@afrifx.com',
} as const

/** e.g. "Welcome to AfriFX" */
export const brandSubject = (s: string) => `${s} ${BRAND.name}`.trim()
