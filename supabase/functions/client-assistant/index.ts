// ============================================================================
// NOTI CALLING — Edge Function : client-assistant
//
// Retour terrain : « un agent copilote pour les clients qui ont des
// questions pour commande ou besoin d'aide ». Répond en langage naturel sur
// la carte, le statut d'une commande, les crédits — jamais sur des données
// que le client n'a pas le droit de voir : tout le contexte est reconstruit
// côté serveur avec le JWT de l'appelant (RLS), jamais fourni par le client.
//
// Body attendu :
//   { eventId, message, lang? }        // lang: "fr" | "en" | "es", défaut "fr"
//
// Réponse :
//   { reply: string }
//
// Secret requis : ANTHROPIC_API_KEY (déjà utilisé par translate-menu).
// ============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import Anthropic from 'npm:@anthropic-ai/sdk@0.68.0'
import { json, preflight } from '../_shared/cors.ts'

const anthropic = new Anthropic({ apiKey: Deno.env.get('ANTHROPIC_API_KEY') ?? '' })

const LANG_NAMES: Record<string, string> = { fr: 'français', en: 'anglais', es: 'espagnol' }

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  if (!Deno.env.get('ANTHROPIC_API_KEY')) {
    return json({ error: 'ANTHROPIC_API_KEY non configurée' }, 500)
  }

  let body: { eventId?: string; message?: string; lang?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: 'JSON invalide' }, 400)
  }

  const eventId = body.eventId
  const message = (body.message ?? '').trim().slice(0, 600)
  const lang = LANG_NAMES[body.lang ?? ''] ? body.lang! : 'fr'
  if (!eventId || !message) return json({ error: 'eventId et message requis' }, 400)

  // Client scopé au JWT de l'appelant : toutes les lectures qui suivent
  // passent par la RLS existante, exactement ce que verrait le client dans
  // l'app — aucun accès plus large que ce qu'il a déjà.
  const authHeader = req.headers.get('Authorization') ?? ''
  const caller = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  )
  // Service role réservé à l'écriture de l'historique (voir 0031 : les
  // policies n'autorisent que la lecture côté client, pour que la paire
  // question/réponse soit toujours écrite ensemble par cette fonction).
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  const { data: customerId } = await caller.rpc('my_customer_id')
  if (!customerId) return json({ error: 'unauthorized' }, 401)

  const { data: attendance } = await caller
    .from('attendances')
    .select('customer_id')
    .eq('event_id', eventId)
    .eq('customer_id', customerId)
    .maybeSingle()
  if (!attendance) return json({ error: 'forbidden' }, 403)

  const { data: rateOk } = await caller.rpc('assistant_rate_ok', { p_event: eventId, p_customer: customerId })
  if (rateOk === false) {
    return json({ error: 'rate_limited' }, 429)
  }

  const { data: event } = await caller
    .from('events')
    .select('id, venue_id, name, accept_orders, venues ( name )')
    .eq('id', eventId)
    .maybeSingle()
  if (!event) return json({ error: 'not_found' }, 404)

  const [{ data: products }, { data: orders }, { data: pass }, { data: gifts }, { data: history }] = await Promise.all([
    caller
      .from('products')
      .select('name, description, price, universe, subcategory, is_alcohol, sold_out')
      .eq('venue_id', event.venue_id)
      .eq('is_listed', true)
      .limit(200),
    caller
      .from('orders')
      .select('pickup_code, status, total, created_at, ready_at, order_items ( name_snapshot, quantity )')
      .eq('event_id', eventId)
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false })
      .limit(5),
    caller.from('event_passes').select('credits_remaining, food_token_available').eq('event_id', eventId).eq('customer_id', customerId).maybeSingle(),
    caller.rpc('my_gift_summary', { p_event: eventId }),
    caller
      .from('client_assistant_messages')
      .select('role, content')
      .eq('event_id', eventId)
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false })
      .limit(12),
  ])

  const menuLines = (products ?? [])
    .map((p) => `- ${p.name} (${p.subcategory}, ${p.universe}) — ${Number(p.price).toFixed(2)} €${p.sold_out ? ' [épuisé]' : ''}${p.description ? ` : ${p.description}` : ''}`)
    .join('\n')

  const orderLines = (orders ?? [])
    .map((o) => {
      const items = (o.order_items ?? []).map((it: { quantity: number; name_snapshot: string }) => `${it.quantity}× ${it.name_snapshot}`).join(', ')
      return `- Commande ${o.pickup_code} — statut ${o.status} — ${Number(o.total).toFixed(2)} € — ${items}`
    })
    .join('\n')

  const creditsLine = pass
    ? `Forfait actif : ${pass.credits_remaining} crédit(s) restant(s)${pass.food_token_available ? ', 1 plat offert disponible' : ''}.`
    : 'Pas de forfait de crédits actif pour cette soirée.'
  const giftsLine = Array.isArray(gifts) && gifts.length > 0
    ? gifts.map((g: { product_name?: string; category?: string; remaining: number }) => `- ${g.product_name || g.category} : ${g.remaining} restant(s)`).join('\n')
    : null

  const system = [
    `Tu es l'assistant de Noti Calling pour "${(event as { venues?: { name?: string } })?.venues?.name ?? 'le lieu'}", ce soir "${event.name}".`,
    "Tu aides un client déjà présent sur place : questions sur la carte, sa commande en cours, ses crédits, comment commander.",
    'Réponds UNIQUEMENT à partir des informations fournies ci-dessous. Ne devine jamais un prix, un ingrédient ou un allergène qui ne figure pas dans la description — dis que le bar peut confirmer sur place.',
    "Aucun paiement ne se fait dans l'application : le règlement se fait toujours au bar, jamais en ligne. Ne dis jamais le contraire.",
    "Si la question sort de ton périmètre (réclamation, incident, urgence, sujet sensible), invite poliment le client à utiliser l'onglet Messages pour joindre l'équipe directement.",
    'Réponses courtes (2-4 phrases), ton chaleureux et direct, adapté à un téléphone dans un bar. Pas de markdown, pas de listes à puces sauf si vraiment utile.',
    `Réponds en ${LANG_NAMES[lang]}, quelle que soit la langue du message du client.`,
    '',
    event.accept_orders ? 'La carte accepte actuellement les commandes.' : "La carte n'accepte plus de commandes pour le moment (soirée fermée ou en pause).",
    '',
    '--- Carte ---',
    menuLines || '(carte vide)',
    '',
    '--- Crédits du client ---',
    creditsLine,
    ...(giftsLine ? ['--- Cadeaux/codes actifs du client ---', giftsLine] : []),
    '',
    '--- Commandes récentes du client (les plus récentes en premier) ---',
    orderLines || 'Aucune commande pour le moment.',
  ].join('\n')

  const priorTurns = (history ?? [])
    .slice()
    .reverse()
    .map((m: { role: string; content: string }) => ({ role: m.role as 'user' | 'assistant', content: m.content }))

  try {
    const response = await anthropic.beta.messages.create({
      model: 'claude-sonnet-5',
      max_tokens: 500,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: { effort: 'low' },
      system,
      messages: [...priorTurns, { role: 'user', content: message }],
    })

    if (response.stop_reason === 'refusal') {
      return json({ reply: null, error: 'declined' }, 422)
    }

    const reply = response.content.find((b) => b.type === 'text')?.text?.trim() || ''

    // `now()` est figé pour toute la durée d'un même statement : sans deux
    // horodatages distincts, les deux lignes d'une paire se retrouvent à
    // égalité et un ORDER BY created_at peut les relire dans le désordre —
    // cassant l'alternance user/assistant attendue par l'API au tour suivant.
    const t0 = Date.now()
    await admin.from('client_assistant_messages').insert([
      { event_id: eventId, customer_id: customerId, role: 'user', content: message, created_at: new Date(t0).toISOString() },
      { event_id: eventId, customer_id: customerId, role: 'assistant', content: reply, created_at: new Date(t0 + 1).toISOString() },
    ])

    return json({ reply })
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})
