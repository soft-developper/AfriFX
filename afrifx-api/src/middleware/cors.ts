import cors from 'cors'

export const corsMiddleware = cors({
  origin: [
    'http://localhost:3000',
    'https://afrifx.xyz',
    'https://www.afrifx.xyz',
    'https://afrifx.vercel.app',
    process.env.FRONTEND_URL ?? '',
  ].filter(Boolean),
  methods:        ['GET', 'POST', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
})
