import PDFDocument from 'pdfkit'

export interface ReceiptData {
  title:           string          // e.g. 'Trade Receipt' | 'Payment Receipt'
  recipientName:   string
  recipientRole:   string          // 'Buyer' | 'Seller' | 'Sender' | 'Receiver'
  counterpartName: string
  usdcAmount:      number
  localAmount?:    number
  localCcy?:       string
  reference:       string
  txHash:          string
  timestamp:       number          // unix seconds
  type:            'trade' | 'invoice'
}

// Brand colors (kept literal PDF is theme-independent)
const GOLD  = '#8A5E13'
const INK   = '#2B2416'
const MUTED = '#6B5F49'
const LINE  = '#E4D9C4'

// Render the receipt to a PDF and return it as a Buffer.
export function generateReceiptPdf(data: ReceiptData): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    try {
      const doc = new PDFDocument({ size: 'A4', margin: 50 })
      const chunks: Buffer[] = []
      doc.on('data', (c: Buffer) => chunks.push(c))
      doc.on('end', () => resolve(Buffer.concat(chunks)))
      doc.on('error', reject)

      // ── Header ──────────────────────────────────────────────
      doc.fillColor(GOLD).fontSize(22).font('Helvetica-Bold').text('AfriFX', 50, 50)
      doc.fillColor(MUTED).fontSize(9).font('Helvetica')
        .text('Stablecoin FX & cross-border payments on Arc', 50, 76)

      doc.fillColor(INK).fontSize(16).font('Helvetica-Bold')
        .text(data.title, 50, 110)
      doc.fillColor(MUTED).fontSize(9).font('Helvetica')
        .text(`Issued ${new Date(data.timestamp * 1000).toUTCString()}`, 50, 132)

      // Divider
      doc.moveTo(50, 155).lineTo(545, 155).strokeColor(LINE).lineWidth(1).stroke()

      // ── Body rows ───────────────────────────────────────────
      let y = 175
      const row = (label: string, value: string) => {
        doc.fillColor(MUTED).fontSize(10).font('Helvetica').text(label, 50, y)
        doc.fillColor(INK).fontSize(10).font('Helvetica-Bold')
          .text(value, 220, y, { width: 325, align: 'right' })
        y += 26
      }

      row('Receipt for', `${data.recipientName} (${data.recipientRole})`)
      row('Counterparty', data.counterpartName)
      row('USDC amount', `${data.usdcAmount.toLocaleString(undefined, { maximumFractionDigits: 6 })} USDC`)
      if (data.localAmount && data.localCcy) {
        row('Local amount', `${data.localAmount.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${data.localCcy}`)
      }
      row('Reference', data.reference)

      // Tx hash wraps, so give it its own block
      doc.fillColor(MUTED).fontSize(10).font('Helvetica').text('Transaction', 50, y)
      doc.fillColor(GOLD).fontSize(8).font('Courier')
        .text(data.txHash, 220, y, { width: 325, align: 'right' })
      y += 34

      // Divider
      doc.moveTo(50, y).lineTo(545, y).strokeColor(LINE).lineWidth(1).stroke()
      y += 20

      // ── Footer ──────────────────────────────────────────────
      doc.fillColor(MUTED).fontSize(8).font('Helvetica').text(
        'This receipt was generated automatically by AfriFX. The transaction is recorded on the Arc blockchain and can be verified at testnet.arcscan.app using the transaction hash above.',
        50, y, { width: 495, align: 'left' },
      )
      doc.fillColor(MUTED).fontSize(8)
        .text('© ' + new Date().getFullYear() + ' AfriFX', 50, y + 40, { align: 'center', width: 495 })

      doc.end()
    } catch (err) {
      reject(err)
    }
  })
}
