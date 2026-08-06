-- ============================================================
-- TAPZ — 0003_realtime.sql
-- Publication Realtime (kanban comptoir + suivi client).
-- Realtime respecte la RLS : voir les policies de 0002.
-- ============================================================

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- REPLICA IDENTITY FULL : nécessaire pour recevoir "old_record" sur UPDATE/DELETE.
alter table public.orders      replica identity full;
alter table public.order_items replica identity full;

do $$
begin
  begin
    alter publication supabase_realtime add table public.orders;
  exception when duplicate_object then null; end;

  begin
    alter publication supabase_realtime add table public.order_items;
  exception when duplicate_object then null; end;
end $$;
