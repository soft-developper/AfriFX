// AfriFX broadcast email template — the branded shell for admin announcements.
//
// Uses the CURRENT gold brand (the older transactional templates in
// templates.ts still use the pre-rebrand blue; those are left alone here).
//
// Every broadcast carries the marks of an authentic platform email:
//   * the AfriFX wordmark + hexagon mark in the header
//   * the sending admin's name and role, so it's clear who it's from
//   * the recipient's own name in the greeting
//   * a footer explaining WHY they received it, plus a working unsubscribe link

const GOLD        = '#D9A441'
const GOLD_BRIGHT = '#EAC15C'
const BG          = '#12100B'
const CARD        = '#1C1810'
const BORDER      = '#2A2418'
const TEXT        = '#F2E9D8'
const MUTED       = '#9C8A6E'

const APP_URL = process.env.APP_URL ?? 'https://afrifx.xyz'

export interface BroadcastTemplateParams {
  recipientName:  string      // personalises the greeting
  senderName:     string      // the admin who sent it
  senderRole:     string      // e.g. 'Administrator'
  subject:        string
  body:           string      // the admin's message (plain text; newlines honoured)
  unsubscribeUrl?: string     // omitted for sub-admin recipients (internal mail)
  isInternal?:    boolean     // true when sent to sub-admins
}

// Turn the admin's plain-text message into safe HTML paragraphs.
// We escape everything, then honour blank-line paragraphs and single newlines.
function renderBody(text: string): string {
  const esc = (s: string) => s
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')

  return esc(text)
    .split(/\n{2,}/)
    .map(p => `<p style="margin:0 0 16px;color:${TEXT};font-size:15px;line-height:1.6;">${p.replace(/\n/g, '<br/>')}</p>`)
    .join('')
}

export function broadcastEmail(p: BroadcastTemplateParams): { subject: string; html: string } {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${p.subject}</title>
</head>
<body style="margin:0;padding:0;background:${BG};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG};padding:32px 16px;">
  <tr><td align="center">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;">

      <!-- Header: brand mark + wordmark -->
      <tr><td align="center" style="padding-bottom:24px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td style="vertical-align:middle;padding-right:10px;">
              <svg width="34" height="35" viewBox="0 0 120 124" xmlns="http://www.w3.org/2000/svg">
                <path d="M60 4 L112 34 L112 90 L60 120 L8 90 L8 34 Z" fill="none" stroke="${GOLD}" stroke-width="8" stroke-linejoin="round"/>
                <g fill="none" stroke="${TEXT}" stroke-width="9" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M36 88 L52 40 L68 88"/><path d="M43 70 L61 70"/>
                </g>
                <g fill="none" stroke="${GOLD}" stroke-width="9" stroke-linecap="round">
                  <path d="M74 52 L96 84"/><path d="M96 52 L74 84"/>
                </g>
              </svg>
            </td>
            <td style="vertical-align:middle;">
              <span style="font-size:24px;font-weight:800;letter-spacing:-0.5px;color:${GOLD_BRIGHT};">Afri</span><span style="font-size:24px;font-weight:800;letter-spacing:-0.5px;color:${GOLD};">FX</span>
            </td>
          </tr>
        </table>
      </td></tr>

      <!-- Card -->
      <tr><td style="background:${CARD};border:1px solid ${BORDER};border-radius:14px;padding:28px 26px;">

        <!-- Who it's from — an authenticity signal -->
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-bottom:20px;">
          <tr><td style="padding-bottom:14px;border-bottom:1px solid ${BORDER};">
            <p style="margin:0;font-size:11px;text-transform:uppercase;letter-spacing:1.2px;color:${MUTED};">
              ${p.isInternal ? 'Internal message from' : 'Message from'}
            </p>
            <p style="margin:4px 0 0;font-size:15px;font-weight:600;color:${GOLD_BRIGHT};">
              ${p.senderName}
            </p>
            <p style="margin:2px 0 0;font-size:12px;color:${MUTED};">
              ${p.senderRole} · AfriFX
            </p>
          </td></tr>
        </table>

        <!-- Greeting with the recipient's own name -->
        <p style="margin:0 0 18px;font-size:15px;color:${TEXT};">
          Hi ${p.recipientName},
        </p>

        <!-- The admin's message -->
        ${renderBody(p.body)}

        <!-- Sign-off -->
        <p style="margin:24px 0 0;padding-top:18px;border-top:1px solid ${BORDER};font-size:14px;color:${MUTED};">
          — ${p.senderName}<br/>
          <span style="font-size:12px;">${p.senderRole}, AfriFX</span>
        </p>
      </td></tr>

      <!-- Footer -->
      <tr><td style="padding-top:20px;text-align:center;">
        <p style="margin:0 0 8px;font-size:11px;color:${MUTED};line-height:1.5;">
          ${p.isInternal
            ? 'You received this because you are an AfriFX sub-administrator.'
            : 'You received this because you have an account on AfriFX.'}
        </p>
        <p style="margin:0 0 10px;font-size:11px;color:${MUTED};">
          <a href="${APP_URL}" style="color:${GOLD};text-decoration:none;">afrifx.xyz</a>
          ${p.unsubscribeUrl ? `
            &nbsp;·&nbsp;
            <a href="${p.unsubscribeUrl}" style="color:${MUTED};text-decoration:underline;">
              Unsubscribe from announcements
            </a>` : ''}
        </p>
        <p style="margin:0;font-size:10px;color:${MUTED};">
          ${p.unsubscribeUrl
            ? 'Unsubscribing stops announcements only — you will still receive essential alerts about your own trades and disputes.'
            : ''}
        </p>
      </td></tr>

    </table>
  </td></tr>
</table>
</body>
</html>`

  return { subject: p.subject, html }
}
