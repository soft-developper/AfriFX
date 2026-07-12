import cors from 'cors'

export const corsMiddleware = cors({
  origin: [
    'http://localhost:3000',
    'https://afrifx.xyz',
    'https://www.afrifx.xyz',
    'https://afrifx.vercel.app',
    process.env.FRONTEND_URL ?? '',
  ].filter(Boolean),
  // PUT was missing, which made the browser's preflight reject
  // PUT /maintenance/:section before it ever reached the API.
  // OPTIONS is listed explicitly since preflight relies on it.
  methods:        ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
})
