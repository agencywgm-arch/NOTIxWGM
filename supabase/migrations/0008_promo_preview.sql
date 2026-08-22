-- ============================================================================
--  NOTI Calling — 0008_promo_preview.sql
--
--  Jusqu'ici, un code promo invalide était silencieusement ignoré par
--  place_order() (comportement volontaire pour ne jamais bloquer une
--  commande) — mais côté client, rien n'indiquait si le code avait
--  fonctionné ou pas : le total affiché au checkout ne bougeait jamais.
--
--  Cette fonction permet au client de VÉRIFIER un code avant de commander,
--  sans exposer la table (toujours aucune lecture publique sur promo_codes,
--  cf. 0002_rls.sql) : elle ne renvoie que le résultat du calcul pour LE
--  code fourni, jamais la liste. C'est un aperçu, la source de vérité reste
--  place_order() qui revalide tout côté serveur à la commande.
-- ============================================================================

create or replace function public.preview_promo(p_event uuid, p_code text, p_subtotal numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo    public.promo_codes;
  v_discount numeric(10,2) := 0;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses)
      and min_total <= coalesce(p_subtotal, 0);

  if v_promo.id is null then
    return jsonb_build_object('valid', false);
  end if;

  v_discount := least(
    case when v_promo.kind = 'amount' then v_promo.value
         else round(coalesce(p_subtotal, 0) * v_promo.value / 100, 2) end,
    coalesce(p_subtotal, 0));

  return jsonb_build_object(
    'valid', true,
    'kind', v_promo.kind,
    'value', v_promo.value,
    'label', v_promo.label,
    'discount', v_discount
  );
end;
$$;

grant execute on function public.preview_promo(uuid, text, numeric) to authenticated;
