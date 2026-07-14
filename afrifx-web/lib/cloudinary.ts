// Cloudinary upload via AfriFX backend
// API keys stay on the server never exposed to the browser
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

    xhr.addEventListener('error', () => reject(new Error('Upload failed, network error')))
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
