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

export async function uploadBuffer(
  buffer:   Buffer,
  filename: string,
  mimeType: string,
  offerId:  string,
): Promise<UploadResult> {
  const resourceType =
    mimeType.startsWith('image/') ? 'image' :
    mimeType.startsWith('video/') ? 'video' : 'raw'

  const type: UploadResult['type'] =
    mimeType.startsWith('image/') ? 'image' :
    mimeType.startsWith('video/') ? 'video' : 'document'

  // Convert buffer to base64 data URI avoids upload_stream signing issues
  const base64    = buffer.toString('base64')
  const dataUri   = `data:${mimeType};base64,${base64}`

  // Use upload() with only folder minimal params = minimal signature surface
  const result = await cloudinary.uploader.upload(dataUri, {
    folder:        `afrifx/chat/${offerId}`,
    resource_type: resourceType as any,
    // No public_id let Cloudinary auto-generate it
    // This keeps the string-to-sign as: folder=...&timestamp=...
  })

  return {
    url:      result.secure_url,
    publicId: result.public_id,
    type,
    format:   result.format   ?? '',
    bytes:    result.bytes    ?? 0,
    name:     filename,
  }
}
