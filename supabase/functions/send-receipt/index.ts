// ============================================================
// TAPZ — Edge Function : send-receipt
// Envoie par e-mail le RÉCAPITULATIF d'une commande (pas un reçu de paiement :
// le règlement se fait au bar). Fournisseur : Resend.
//
// Body attendu : { "orderId": "uuid" }
// Secrets requis : RESEND_API_KEY, RESEND_FROM (ex: "TAPZ <hello@mondomaine.fr>")
// ============================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import { json, preflight } from '../_shared/cors.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? ''
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'TAPZ <onboarding@resend.dev>'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

const eur = (n: number) =>
  new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR' }).format(n || 0)

const esc = (s: string) =>
  String(s ?? '').replace(/[&<>"]/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c] as string
  )

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  if (!RESEND_API_KEY) return json({ error: 'RESEND_API_KEY non configurée' }, 500)

  let orderId: string | undefined
  try {
    orderId = (await req.json()).orderId
  } catch {
    return json({ error: 'JSON invalide' }, 400)
  }
  if (!orderId) return json({ error: 'orderId requis' }, 400)

  const { data: order, error } = await supabase
    .from('orders')
    .select(
      'id, code, total, subtotal, discount, note, customer_name, customer_email, order_type, created_at, ' +
        'bars ( name, address, city, phone, siret, tva_number, logo_emoji ), ' +
        'tables ( number, label ), ' +
        'order_items ( name_snapshot, unit_price, quantity, vat_rate, detail )'
    )
    .eq('id', orderId)
    .single()

  if (error || !order) return json({ error: error?.message ?? 'commande introuvable' }, 404)
  if (!order.customer_email) return json({ error: 'aucune adresse e-mail sur la commande' }, 400)

  const bar = (order as Record<string, any>).bars ?? {}
  const table = (order as Record<string, any>).tables ?? {}
  const items: Array<Record<string, any>> = (order as Record<string, any>).order_items ?? []

  const rows = items
    .map((it) => {
      const opts = Array.isArray(it.detail?.options)
        ? it.detail.options.map((o: Record<string, string>) => o.name).filter(Boolean).join(', ')
        : ''
      return `<tr>
        <td style="padding:8px 0;border-bottom:1px solid #241d3a">
          <strong>${esc(it.name_snapshot)}</strong>
          ${opts ? `<div style="color:#9c93b8;font-size:12px">${esc(opts)}</div>` : ''}
        </td>
        <td style="padding:8px 0;border-bottom:1px solid #241d3a;text-align:center">×${it.quantity}</td>
        <td style="padding:8px 0;border-bottom:1px solid #241d3a;text-align:right">${eur(
          Number(it.unit_price) * Number(it.quantity)
        )}</td>
      </tr>`
    })
    .join('')

  const legal = [
    bar.address ? esc(bar.address) : '',
    bar.city ? esc(bar.city) : '',
    bar.phone ? `Tél. ${esc(bar.phone)}` : '',
    bar.siret ? `SIRET ${esc(bar.siret)}` : '',
    bar.tva_number ? `TVA ${esc(bar.tva_number)}` : '',
  ]
    .filter(Boolean)
    .join(' · ')

  const html = `<!doctype html><html><body style="margin:0;background:#0A0713;color:#F4F1FF;
    font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:24px">
    <div style="max-width:520px;margin:0 auto;background:#141024;border:1px solid rgba(255,255,255,.08);
      border-radius:18px;padding:24px">
      <div style="font-size:11px;letter-spacing:4px;color:#B14EFF;margin-bottom:6px">TAPZ</div>
      <h1 style="margin:0 0 4px;font-size:22px">${esc(bar.logo_emoji ?? '🍸')} ${esc(bar.name ?? 'Bar')}</h1>
      <div style="color:#9C93B8;font-size:13px;margin-bottom:18px">
        Récapitulatif · Commande <strong style="color:#00E5FF">#${esc(order.code)}</strong>
        ${table?.number != null ? ` · Table ${table.number}${table.label ? ` (${esc(table.label)})` : ''}` : ''}
      </div>

      <table style="width:100%;border-collapse:collapse;font-size:14px">${rows}</table>

      ${
        Number(order.discount) > 0
          ? `<div style="display:flex;justify-content:space-between;margin-top:12px;color:#3DFFA8;font-size:14px">
               <span>Remise</span><span>−${eur(Number(order.discount))}</span></div>`
          : ''
      }

      <div style="display:flex;justify-content:space-between;margin-top:16px;padding-top:14px;
        border-top:1px solid rgba(255,255,255,.12);font-size:20px;font-weight:700">
        <span>TOTAL</span><span style="color:#B14EFF">${eur(Number(order.total))}</span>
      </div>

      <div style="margin-top:18px;padding:12px;border-radius:12px;background:rgba(255,61,139,.12);
        border:1px solid rgba(255,61,139,.35);color:#FF3D8B;font-weight:700;text-align:center;font-size:13px">
        À RÉGLER AU BAR — aucun paiement en ligne
      </div>

      ${order.note ? `<div style="margin-top:14px;color:#9C93B8;font-size:12px">Note : ${esc(order.note)}</div>` : ''}
      ${legal ? `<div style="margin-top:18px;color:#6f668c;font-size:11px;line-height:1.6">${legal}</div>` : ''}
    </div>
  </body></html>`

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: RESEND_FROM,
      to: [order.customer_email],
      subject: `${bar.name ?? 'TAPZ'} — récapitulatif #${order.code}`,
      html,
    }),
  })

  if (!res.ok) return json({ error: await res.text() }, 502)
  return json({ ok: true })
})
