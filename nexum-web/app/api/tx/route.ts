import { NextRequest, NextResponse } from 'next/server'

const API = process.env.API_URL ?? 'http://localhost:4000'

export async function GET(req: NextRequest) {
  const hash = req.nextUrl.searchParams.get('hash')
  if (!hash) return NextResponse.json({ error: 'hash required' }, { status: 400 })
  try {
    const res = await fetch(`${API}/transactions/${hash}`)
    const data = await res.json()
    return NextResponse.json(data)
  } catch {
    return NextResponse.json({ error: 'Not found' }, { status: 404 })
  }
}
