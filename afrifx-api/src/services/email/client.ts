import { Resend } from 'resend'

const RESEND_KEY = process.env.RESEND_API_KEY
const FROM_EMAIL = process.env.EMAIL_FROM ?? 'AfriFX <notifications@afrifx.xyz>'

if (!RESEND_KEY) {
  console.warn('[Email] RESEND_API_KEY not set — emails will be logged but not sent')
}

const resend = RESEND_KEY ? new Resend(RESEND_KEY) : null

export interface SendEmailParams {
  to:      string
  subject: string
  html:    string
}

export async function sendEmail({ to, subject, html }: SendEmailParams) {
  if (!resend) {
    console.log(`[Email DEV MODE] To: ${to} | Subject: ${subject}`)
    return { id: 'dev-mode', success: true }
  }

  try {
    const result = await resend.emails.send({
      from:    FROM_EMAIL,
      to:      [to],
      subject,
      html,
    })
    return { id: result.data?.id, success: true, error: result.error }
  } catch (err: any) {
    console.error('[Email] Send failed:', err.message)
    return { id: null, success: false, error: err.message }
  }
}
