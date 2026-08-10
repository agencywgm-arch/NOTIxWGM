// ============================================================
// Noti Calling — writer PDF maison (zéro dépendance).
// Chaque page est un <canvas> rendu en JPEG puis embarqué comme XObject
// /DCTDecode. Volontairement PAS de html2canvas : ça casse sur iOS Safari.
// ============================================================

const A4 = { w: 595.28, h: 841.89 } // points (72 dpi)

const ascii = (str) => {
  const out = new Uint8Array(str.length)
  for (let i = 0; i < str.length; i++) out[i] = str.charCodeAt(i) & 0xff
  return out
}

const dataUrlToBytes = (dataUrl) => {
  const b64 = dataUrl.slice(dataUrl.indexOf(',') + 1)
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

/**
 * @param {HTMLCanvasElement[]} canvases  une page par canvas
 * @param {{quality?:number, pageSize?:{w:number,h:number}|'auto'}} opts
 * @returns {Blob} application/pdf
 */
export function canvasesToPdfBlob(canvases, opts = {}) {
  const quality = opts.quality ?? 0.92
  const parts = []
  let length = 0
  const offsets = []

  const push = (chunk) => {
    const bytes = typeof chunk === 'string' ? ascii(chunk) : chunk
    parts.push(bytes)
    length += bytes.length
  }

  // Objets : 1 = Catalog, 2 = Pages, puis 3 objets par page.
  const objCount = 2 + canvases.length * 3
  const markObj = (n) => {
    offsets[n] = length
  }

  push('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n')

  const kids = canvases.map((_, i) => `${3 + i * 3} 0 R`).join(' ')

  markObj(1)
  push(`1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n`)

  markObj(2)
  push(`2 0 obj\n<< /Type /Pages /Kids [${kids}] /Count ${canvases.length} >>\nendobj\n`)

  canvases.forEach((canvas, i) => {
    const pageObj = 3 + i * 3
    const contentObj = pageObj + 1
    const imgObj = pageObj + 2

    const jpeg = dataUrlToBytes(canvas.toDataURL('image/jpeg', quality))

    // Taille de page : A4 dans l'orientation du canvas, ou taille explicite.
    let pw, ph
    if (opts.pageSize && opts.pageSize !== 'auto') {
      pw = opts.pageSize.w
      ph = opts.pageSize.h
    } else if (canvas.width >= canvas.height) {
      pw = A4.h
      ph = A4.w
    } else {
      pw = A4.w
      ph = A4.h
    }

    // Contain : l'image garde son ratio, centrée dans la page.
    const scale = Math.min(pw / canvas.width, ph / canvas.height)
    const dw = canvas.width * scale
    const dh = canvas.height * scale
    const dx = (pw - dw) / 2
    const dy = (ph - dh) / 2

    markObj(pageObj)
    push(
      `${pageObj} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pw.toFixed(2)} ${ph.toFixed(
        2
      )}] /Resources << /XObject << /Im0 ${imgObj} 0 R >> >> /Contents ${contentObj} 0 R >>\nendobj\n`
    )

    const content = `q\n${dw.toFixed(2)} 0 0 ${dh.toFixed(2)} ${dx.toFixed(2)} ${dy.toFixed(
      2
    )} cm\n/Im0 Do\nQ\n`
    markObj(contentObj)
    push(`${contentObj} 0 obj\n<< /Length ${content.length} >>\nstream\n`)
    push(content)
    push('endstream\nendobj\n')

    markObj(imgObj)
    push(
      `${imgObj} 0 obj\n<< /Type /XObject /Subtype /Image /Width ${canvas.width} /Height ${canvas.height} ` +
        `/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`
    )
    push(jpeg)
    push('\nendstream\nendobj\n')
  })

  const xrefStart = length
  let xref = `xref\n0 ${objCount + 1}\n0000000000 65535 f \n`
  for (let n = 1; n <= objCount; n++) {
    xref += `${String(offsets[n] ?? 0).padStart(10, '0')} 00000 n \n`
  }
  push(xref)
  push(
    `trailer\n<< /Size ${objCount + 1} /Root 1 0 R >>\nstartxref\n${xrefStart}\n%%EOF\n`
  )

  return new Blob(parts, { type: 'application/pdf' })
}

/** Télécharge un Blob (fallback universel). */
export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 4000)
}

/**
 * Partage un fichier via la feuille de partage iOS (navigator.share), avec repli
 * sur le téléchargement classique. C'est le seul chemin fiable sur iPhone.
 */
export async function shareOrDownload(blob, filename, title = 'Noti Calling') {
  try {
    const file = new File([blob], filename, { type: blob.type })
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      await navigator.share({ files: [file], title })
      return 'shared'
    }
  } catch (e) {
    if (e?.name === 'AbortError') return 'cancelled'
  }
  downloadBlob(blob, filename)
  return 'downloaded'
}

/** Crée un canvas HiDPI prêt à peindre (dimensions logiques en px CSS). */
export function makeCanvas(w, h, dpr = 2) {
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(w * dpr)
  canvas.height = Math.round(h * dpr)
  const ctx = canvas.getContext('2d')
  ctx.scale(dpr, dpr)
  ctx.textBaseline = 'top'
  return { canvas, ctx, w, h }
}

/** Rectangle arrondi (Canvas 2D natif). */
export function roundRect(ctx, x, y, w, h, r) {
  const rad = Math.min(r, w / 2, h / 2)
  ctx.beginPath()
  ctx.moveTo(x + rad, y)
  ctx.arcTo(x + w, y, x + w, y + h, rad)
  ctx.arcTo(x + w, y + h, x, y + h, rad)
  ctx.arcTo(x, y + h, x, y, rad)
  ctx.arcTo(x, y, x + w, y, rad)
  ctx.closePath()
}

/** Découpe un texte pour tenir dans une largeur ; renvoie les lignes. */
export function wrapText(ctx, text, maxWidth, maxLines = 3) {
  const words = String(text || '').split(/\s+/).filter(Boolean)
  const lines = []
  let line = ''
  for (const word of words) {
    const test = line ? `${line} ${word}` : word
    if (ctx.measureText(test).width > maxWidth && line) {
      lines.push(line)
      line = word
      if (lines.length === maxLines) break
    } else {
      line = test
    }
  }
  if (lines.length < maxLines && line) lines.push(line)
  if (lines.length === maxLines && line && lines[maxLines - 1] !== line) {
    let last = lines[maxLines - 1]
    while (ctx.measureText(last + '…').width > maxWidth && last.length > 1) last = last.slice(0, -1)
    lines[maxLines - 1] = last + '…'
  }
  return lines
}

/** Charge une image (CORS anonyme pour pouvoir l'exporter). */
export function loadImage(src) {
  return new Promise((resolve) => {
    if (!src) return resolve(null)
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => resolve(img)
    img.onerror = () => resolve(null)
    img.src = src
  })
}

/** Exporte un canvas en PNG (partage iOS inclus). */
export async function canvasToPng(canvas, filename, title = 'Noti Calling') {
  const blob = await new Promise((res) => canvas.toBlob(res, 'image/png'))
  return shareOrDownload(blob, filename, title)
}
