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

  async function hdleFile(e: React.ChangeEvent<HTMLInputElement>) {
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
        className="flex h-9 w-9 items-center justify-center rounded-full border border-app-border bg-app-surface text-app-muted transition-colors hover:border-app-accent hover:text-app-text disabled:opacity-40"
      >
        {uploading
          ? <Loader2 className="h-4 w-4 animate-spin" />
          : <Paperclip className="h-4 w-4" />
        }
      </button>

      {/* Progress bubble */}
      {uploading && (
        <div className="absolute -top-7 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full bg-app-surface border border-app-border px-2 py-0.5 text-[10px] text-app-accent-text">
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
