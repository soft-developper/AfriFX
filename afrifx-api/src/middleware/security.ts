// ============================================================
// Security headers (Layer 5).
//
// AfriFX is a JSON API, not an HTML site, so the config is tuned for that:
//   * We DON'T serve a browsable UI from here, so a strict Content-Security-
//     Policy that assumes HTML/script tags would add risk of breakage without
//     protecting anything real — the frontend (Vercel) sets its own CSP. We
//     keep a minimal CSP that just disallows this origin being used to load
//     active content.
//   * HSTS is ON so browsers pin HTTPS (Render terminates TLS in front of us).
//   * We hide the framework fingerprint and turn off client-side MIME sniffing.
//   * crossOriginResourcePolicy is relaxed to 'cross-origin' because the API is
//     legitimately called from the frontend on a different origin — the strict
//     default ('same-origin') would break those reads.
// ============================================================

import helmet from 'helmet'

export const securityHeaders = helmet({
  // Clickjacking: this API should never be framed.
  frameguard: { action: 'deny' },

  // Force HTTPS for two years, including subdomains.
  hsts: {
    maxAge: 63072000,       // 2 years in seconds
    includeSubDomains: true,
    preload: true,
  },

  // Don't leak the referrer to third parties.
  referrerPolicy: { policy: 'no-referrer' },

  // A JSON API doesn't load scripts/styles/images of its own, so lock the CSP
  // right down to 'none' for active content. This makes any response that
  // somehow renders in a browser inert.
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'none'"],
      formAction: ["'none'"],
    },
  },

  // The frontend calls this API cross-origin, so allow that (the default
  // 'same-origin' would block legitimate cross-origin resource reads).
  crossOriginResourcePolicy: { policy: 'cross-origin' },

  // Belt-and-braces: X-Content-Type-Options: nosniff, hide X-Powered-By, etc.
  // (these are on by default in helmet, listed here for clarity of intent).
})
