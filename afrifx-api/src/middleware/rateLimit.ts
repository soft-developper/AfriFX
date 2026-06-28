import type { Request, Response, NextFunction } from 'express'

const windowMs = 60_000 // 1 minute
const maxRequests = 100
const hits = new Map<string, { count: number; resetAt: number }>()

export function rateLimitMiddleware(req: Request, res: Response, next: NextFunction) {
  const key = req.ip ?? 'unknown'
  const now = Date.now()
  const entry = hits.get(key)

  if (!entry || now > entry.resetAt) {
    hits.set(key, { count: 1, resetAt: now + windowMs })
    return next()
  }

  entry.count++
  if (entry.count > maxRequests) {
    return res.status(429).json({ error: 'Too many requests' })
  }

  next()
}
