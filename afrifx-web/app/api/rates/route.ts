import { NextResponse } from 'next/server'

const API = process.env.API_URL ?? 'http://localhost:4000'

export async function GET() {
  try {
    const res = await fetch(`${API}/rates`, { next: { revalidate: 30 } })
    const data = await res.json()
    return NextResponse.json(data)
  } catch {
    return NextResponse.json({ error: 'Failed to fetch rates' }, { status: 502 })
  }
}
