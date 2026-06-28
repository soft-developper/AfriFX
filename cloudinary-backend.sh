#!/bin/bash
# ============================================================
# AfriFX — Move Cloudinary to backend (API key secured)
# Run from ~/AfriFX:  bash cloudinary-backend.sh
# ============================================================
set -e
echo ""
echo "☁️   Moving Cloudinary to backend..."
echo ""

# ============================================================
# 1 — Install Cloudinary SDK + multer on backend
# ============================================================
cd afrifx-api
npm install cloudinary multer
npm install --save-dev @types/multer
cd ..
echo "✅  cloudinary + multer installed"

# ============================================================
# 2 — Add Cloudinary credentials to backend .env.example
# ============================================================
cat >> afrifx-api/.env.example << '__EOF__'

# Cloudinary — get from cloudinary.com → Settings → API Keys
CLOUDINARY_CLOUD_NAME=your_cloud_name
CLOUDINARY_API_KEY=your_api_key
CLOUDINARY_API_SECRET=your_api_secret
__EOF__
echo "✅  .env.example updated (add real values to .env)"

# ============================================================
# 3 — Backend: lib/cloudinary.ts
# ============================================================
mkdir -p afrifx-api/src/lib

cat > afrifx-api/src/lib/cloudinary.ts << '__EOF__'
// Cloudinary server-side upload
// API key stays on backend — never exposed to browser
// Docs: cloudinary.com/documentation/node_integration

import { v2 as cloudinary } from 'cloudinary'

cloudinary.config({
  cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
  api_key:    process.env.CLOUDINARY_API_KEY,
  api_secret: process.env.CLOUDINARY_API_SECRET,
  secure:     true,
})

export interface UploadResult {
  url:      string
  publicId: string
  type:     'image' | 'video' | 'document'
  format:   string
  bytes:    number
  name:     string
}

/**
 * Upload a buffer to Cloudinary.
 * Called from the /chat/upload endpoint after multer parses the multipart form.
 */
export async function uploadBuffer(
  buffer:   Buffer,
  filename: string,
  mimeType: string,
  offerId:  string,
): Promise<UploadResult> {
  // Determine resource type from mime
  const resourceType =
    mimeType.startsWith('image/') ? 'image' :
    mimeType.startsWith('video/') ? 'video' :
    'raw'   // PDFs, docs, etc.

  const type: UploadResult['type'] =
    mimeType.startsWith('image/') ? 'image' :
    mimeType.startsWith('video/') ? 'video' :
    'document'

  return new Promise((resolve, reject) => {
    const uploadStream = cloudinary.uploader.upload_stream(
      {
        folder:        `afrifx/chat/${offerId}`,
        resource_type: resourceType as any,
        public_id:     `${Date.now()}-${filename.replace(/[^a-zA-Z0-9._-]/g, '_')}`,
        // Auto-optimize images
        transformation: resourceType === 'image'
          ? [{ quality: 'auto', fetch_format: 'auto', width: 1200, crop: 'limit' }]
          : undefined,
      },
      (error, result) => {
        if (error || !result) return reject(error ?? new Error('Upload failed'))
        resolve({
          url:      result.secure_url,
          publicId: result.public_id,
          type,
          format:   result.format,
          bytes:    result.bytes,
          name:     filename,
        })
      },
    )
    uploadStream.end(buffer)
  })
}
__EOF__
echo "✅  afrifx-api/src/lib/cloudinary.ts"

# ============================================================
# 4 — Backend: upload endpoint in chat routes
# ============================================================
cat > afrifx-api/src/routes/chat.ts << '__EOF__'
import { Router }   from 'express'
import { db }       from '../db/client'
import { sql }      from 'drizzle-orm'
import { randomUUID } from 'crypto'
import multer       from 'multer'
import { uploadBuffer } from '../lib/cloudinary'

const router = Router()

// Multer — store in memory (we pipe to Cloudinary immediately)
const upload = multer({
  storage: multer.memoryStorage(),
  limits:  { fileSize: 10 * 1024 * 1024 }, // 10 MB
  fileFilter: (_req, file, cb) => {
    const allowed = [
      'image/jpeg','image/png','image/webp','image/gif',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'video/mp4','video/webm',
    ]
    cb(null, allowed.includes(file.mimetype))
  },
})

// ── Access control helper ─────────────────────────────────
async function verifyAccess(offerId: string, wallet: string): Promise<'maker'|'taker'|null> {
  try {
    const rows = await db.run(
      sql`SELECT maker_address, taker_address FROM p2p_offers WHERE id = ${offerId} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return null
    const o     = r[0]
    const maker = (o.maker_address ?? o[0] ?? '').toLowerCase()
    const taker = (o.taker_address ?? o[1] ?? '').toLowerCase()
    const w     = wallet.toLowerCase()
    if (w === maker) return 'maker'
    if (w === taker) return 'taker'
    return null
  } catch { return null }
}

function parseRows(result: any): any[] {
  if (!result) return []
  if (Array.isArray((result as any).rows)) return (result as any).rows
  if (Array.isArray(result)) return result
  return []
}

function normalizeMsg(row: any) {
  if (Array.isArray(row)) {
    return {
      id: row[0], offer_id: row[1], sender: row[2],
      content: row[3], media_url: row[4], media_type: row[5],
      msg_type: row[6], quick_action: row[7],
      read_maker: Number(row[8]), read_taker: Number(row[9]),
      created_at: Number(row[10]),
    }
  }
  return { ...row, read_maker: Number(row.read_maker), read_taker: Number(row.read_taker) }
}

// In-memory typing store
const typingMap = new Map<string, number>()

// ── POST /chat/:offerId/upload ────────────────────────────
// Multer parses multipart, we upload to Cloudinary from backend
router.post('/:offerId/upload', upload.single('file'), async (req, res) => {
  const { offerId } = req.params
  const wallet      = req.body.wallet as string

  if (!wallet)   return res.status(400).json({ error: 'wallet required' })
  if (!req.file) return res.status(400).json({ error: 'No file provided' })

  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.status(403).json({ error: 'Access denied' })

  if (!process.env.CLOUDINARY_CLOUD_NAME) {
    return res.status(500).json({ error: 'Cloudinary not configured on server' })
  }

  try {
    const result = await uploadBuffer(
      req.file.buffer,
      req.file.originalname,
      req.file.mimetype,
      offerId,
    )
    res.json(result)
  } catch (err: any) {
    console.error('[Cloudinary] Upload failed:', err.message)
    res.status(500).json({ error: 'Upload failed: ' + err.message })
  }
})

// ── GET /chat/:offerId ────────────────────────────────────
router.get('/:offerId', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  const after  = Number(req.query.after ?? 0)

  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.status(403).json({ error: 'Access denied' })

  try {
    const rows = await db.run(
      sql`SELECT * FROM messages
          WHERE offer_id   = ${offerId}
            AND created_at > ${after}
          ORDER BY created_at ASC LIMIT 100`
    )
    const msgs = parseRows(rows).map(normalizeMsg)

    // Mark messages from the other party as read
    const field = role === 'maker' ? 'read_maker' : 'read_taker'
    await db.run(
      sql`UPDATE messages SET ${sql.raw(field)} = 1
          WHERE offer_id = ${offerId} AND sender != ${wallet}`
    ).catch(() => {})

    res.json({ messages: msgs, role })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── GET /chat/:offerId/unread ─────────────────────────────
router.get('/:offerId/unread', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.json({ count: 0 })
  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.json({ count: 0 })
  try {
    const field = role === 'maker' ? 'read_maker' : 'read_taker'
    const rows  = await db.run(
      sql`SELECT COUNT(*) as cnt FROM messages
          WHERE offer_id = ${offerId}
            AND sender   != ${wallet}
            AND ${sql.raw(field)} = 0`
    )
    const r = parseRows(rows)
    res.json({ count: Number(r[0]?.cnt ?? r[0]?.[0] ?? 0) })
  } catch { res.json({ count: 0 }) }
})

// ── POST /chat/:offerId ───────────────────────────────────
router.post('/:offerId', async (req, res) => {
  const { offerId } = req.params
  const { wallet, content, mediaUrl, mediaType, msgType = 'text', quickAction } = req.body

  if (!wallet)                return res.status(400).json({ error: 'wallet required' })
  if (!content && !mediaUrl)  return res.status(400).json({ error: 'content or mediaUrl required' })

  const role = await verifyAccess(offerId, wallet.toLowerCase())
  if (!role) return res.status(403).json({ error: 'Access denied' })

  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO messages
          (id, offer_id, sender, content, media_url, media_type,
           msg_type, quick_action, created_at)
          VALUES
          (${id}, ${offerId}, ${wallet.toLowerCase()},
           ${content ?? null}, ${mediaUrl ?? null}, ${mediaType ?? null},
           ${msgType}, ${quickAction ?? null}, ${now})`
    )
    res.status(201).json({
      id, offer_id: offerId, sender: wallet.toLowerCase(),
      content, media_url: mediaUrl, media_type: mediaType,
      msg_type: msgType, quick_action: quickAction,
      read_maker: 0, read_taker: 0, created_at: now,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── POST /chat/:offerId/system ────────────────────────────
router.post('/:offerId/system', async (req, res) => {
  const { offerId }  = req.params
  const { content }  = req.body
  const id  = randomUUID()
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`INSERT INTO messages (id, offer_id, sender, content, msg_type, created_at)
          VALUES (${id}, ${offerId}, 'system', ${content}, 'system', ${now})`
    )
    res.status(201).json({ id })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// ── POST /chat/:offerId/typing ────────────────────────────
router.post('/:offerId/typing', async (req, res) => {
  const { wallet } = req.body
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  const role = await verifyAccess(req.params.offerId, wallet)
  if (!role)  return res.status(403).json({ error: 'Access denied' })
  typingMap.set(`${req.params.offerId}-${role}`, Date.now())
  res.json({ ok: true })
})

// ── GET /chat/:offerId/typing ─────────────────────────────
router.get('/:offerId/typing', async (req, res) => {
  const { offerId } = req.params
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.json({ typing: false })
  const role = await verifyAccess(offerId, wallet)
  if (!role)  return res.json({ typing: false })
  const other     = role === 'maker' ? 'taker' : 'maker'
  const lastTyped = typingMap.get(`${offerId}-${other}`) ?? 0
  res.json({ typing: Date.now() - lastTyped < 3000 })
})

export default router
__EOF__
echo "✅  routes/chat.ts — /upload endpoint using backend Cloudinary"

# ============================================================
# 5 — Frontend: update lib/cloudinary.ts to POST to backend
# ============================================================
cat > afrifx-web/lib/cloudinary.ts << '__EOF__'
// Cloudinary upload via AfriFX backend
// API keys stay on the server — never exposed to the browser
// Backend endpoint: POST /chat/:offerId/upload

const API = process.env.NEXT_PUBLIC_API_URL ?? 'http://localhost:4000'

export interface CloudinaryUploadResult {
  url:      string
  publicId: string
  type:     'image' | 'video' | 'document'
  format:   string
  bytes:    number
  name:     string
}

/**
 * Upload a file through our backend → Cloudinary.
 * The backend holds the API key; the browser never sees it.
 *
 * @param file       File selected by the user
 * @param offerId    P2P offer ID (used for folder organisation in Cloudinary)
 * @param wallet     Sender's wallet address (access control)
 * @param onProgress Progress callback 0–100
 */
export async function uploadToCloudinary(
  file:       File,
  offerId:    string,
  wallet:     string,
  onProgress?: (pct: number) => void,
): Promise<CloudinaryUploadResult> {
  const formData = new FormData()
  formData.append('file',   file)
  formData.append('wallet', wallet)

  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', `${API}/chat/${offerId}/upload`)

    xhr.upload.addEventListener('progress', (e) => {
      if (e.lengthComputable && onProgress) {
        onProgress(Math.round((e.loaded / e.total) * 100))
      }
    })

    xhr.addEventListener('load', () => {
      if (xhr.status === 201 || xhr.status === 200) {
        try {
          resolve(JSON.parse(xhr.responseText))
        } catch {
          reject(new Error('Invalid response from upload server'))
        }
      } else {
        try {
          const err = JSON.parse(xhr.responseText)
          reject(new Error(err.error ?? 'Upload failed'))
        } catch {
          reject(new Error(`Upload failed (${xhr.status})`))
        }
      }
    })

    xhr.addEventListener('error', () => reject(new Error('Upload failed — network error')))
    xhr.send(formData)
  })
}

export function isImageFile(file: File): boolean {
  return file.type.startsWith('image/')
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024)         return `${bytes} B`
  if (bytes < 1024 * 1024)  return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}
__EOF__
echo "✅  lib/cloudinary.ts — now POSTs to backend"

# ============================================================
# 6 — Frontend: update MediaUploadButton to pass offerId + wallet
# ============================================================
cat > afrifx-web/components/chat/MediaUploadButton.tsx << '__EOF__'
'use client'
import { useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { Paperclip, Loader2 } from 'lucide-react'
import { uploadToCloudinary, type CloudinaryUploadResult } from '@/lib/cloudinary'

interface Props {
  offerId:   string
  onUpload:  (result: CloudinaryUploadResult) => void
  disabled?: boolean
}

export function MediaUploadButton({ offerId, onUpload, disabled }: Props) {
  const { address }               = useAccount()
  const inputRef                  = useRef<HTMLInputElement>(null)
  const [progress,  setProgress]  = useState(0)
  const [uploading, setUploading] = useState(false)
  const [errMsg,    setErrMsg]    = useState<string | null>(null)

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file || !address) return

    if (file.size > 10 * 1024 * 1024) {
      setErrMsg('File too large — max 10 MB')
      return
    }

    setUploading(true)
    setProgress(0)
    setErrMsg(null)

    try {
      const result = await uploadToCloudinary(file, offerId, address, setProgress)
      onUpload(result)
    } catch (err: any) {
      setErrMsg(err.message ?? 'Upload failed')
    } finally {
      setUploading(false)
      setProgress(0)
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  return (
    <div className="relative">
      <input
        ref={inputRef}
        type="file"
        accept="image/*,application/pdf,.doc,.docx,video/mp4,video/webm"
        onChange={handleFile}
        className="hidden"
      />

      <button
        onClick={() => { setErrMsg(null); inputRef.current?.click() }}
        disabled={disabled || uploading}
        title="Attach image, PDF, or document (max 10 MB)"
        className="flex h-9 w-9 items-center justify-center rounded-full border border-[#1B2B4B] bg-[#0F1729] text-[#64748B] transition-colors hover:border-[#378ADD] hover:text-[#E2E8F0] disabled:opacity-40"
      >
        {uploading
          ? <Loader2 className="h-4 w-4 animate-spin" />
          : <Paperclip className="h-4 w-4" />
        }
      </button>

      {/* Progress bubble */}
      {uploading && (
        <div className="absolute -top-7 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-[#0F1729] border border-[#1B2B4B] px-2 py-0.5 text-[10px] text-[#378ADD]">
          {progress}%
        </div>
      )}

      {/* Error bubble */}
      {errMsg && (
        <div className="absolute -top-7 left-0 whitespace-nowrap rounded-full bg-red-900/80 px-2 py-0.5 text-[10px] text-red-300">
          {errMsg}
        </div>
      )}
    </div>
  )
}
__EOF__
echo "✅  MediaUploadButton.tsx — passes offerId + wallet to upload fn"

# ============================================================
# 7 — Update ChatWindow to pass offerId to MediaUploadButton
# ============================================================
# Just update the MediaUploadButton usage inside ChatWindow
# (ChatWindow already has offerId as a prop — just thread it through)
sed -i 's/<MediaUploadButton onUpload={handleMediaUpload} disabled={sending}/<MediaUploadButton offerId={offerId} onUpload={handleMediaUpload} disabled={sending}/g' \
  afrifx-web/components/chat/ChatWindow.tsx
echo "✅  ChatWindow.tsx — offerId threaded to MediaUploadButton"

# ============================================================
# 8 — Remove NEXT_PUBLIC_CLOUDINARY_* from frontend .env.local
#     (they are no longer needed — API key is backend-only now)
# ============================================================
if [ -f afrifx-web/.env.local ]; then
  grep -v "CLOUDINARY" afrifx-web/.env.local > afrifx-web/.env.local.tmp
  mv afrifx-web/.env.local.tmp afrifx-web/.env.local
  echo "✅  Removed CLOUDINARY vars from frontend .env.local"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅  Cloudinary backend integration complete!"
echo ""
echo "  SETUP — add to afrifx-api/.env:"
echo "  CLOUDINARY_CLOUD_NAME=your_cloud_name"
echo "  CLOUDINARY_API_KEY=your_api_key"
echo "  CLOUDINARY_API_SECRET=your_api_secret"
echo ""
echo "  Where to find these:"
echo "  cloudinary.com → Dashboard → API Keys"
echo ""
echo "  Upload flow:"
echo "  Browser → POST /chat/:offerId/upload → Backend → Cloudinary"
echo "              (multer parses multipart)    (API key secured)"
echo "              ← { url, type, name } ←"
echo ""
echo "  Supported files:"
echo "  Images: JPEG, PNG, WebP, GIF (auto-optimised)"
echo "  Docs:   PDF, DOC, DOCX"
echo "  Video:  MP4, WebM"
echo "  Limit:  10 MB per file"
echo ""
echo "  Restart backend:  cd afrifx-api  && npm run dev"
echo "══════════════════════════════════════════════════════"
