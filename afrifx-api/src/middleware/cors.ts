import cors from 'cors'

export const corsMiddleware = cors({
  origin: [
    process.env.FRONTEND_URL ?? 'http://localhost:3000',
    'https://afrifx.vercel.app',
  ],
  methods: ['GET', 'POST', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
})
