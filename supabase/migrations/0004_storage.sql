-- ============================================================
-- TAPZ — 0004_storage.sql
-- Bucket public "tapz" : logos d'établissement + photos de la carte.
-- Convention de chemin : {bar_id}/menu/xxx.jpg  ou  {bar_id}/logo.jpg
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'tapz', 'tapz', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/gif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = excluded.allowed_mime_types;

-- Lecture publique (les photos s'affichent sur la carte client).
drop policy if exists tapz_read on storage.objects;
create policy tapz_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'tapz');

-- Écriture réservée au propriétaire du bar : le 1er segment du chemin = bar_id.
drop policy if exists tapz_write on storage.objects;
create policy tapz_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'tapz'
    and public.owns_bar(nullif(split_part(name, '/', 1), '')::uuid)
  );

drop policy if exists tapz_update on storage.objects;
create policy tapz_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'tapz'
    and public.owns_bar(nullif(split_part(name, '/', 1), '')::uuid)
  );

drop policy if exists tapz_delete on storage.objects;
create policy tapz_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'tapz'
    and public.owns_bar(nullif(split_part(name, '/', 1), '')::uuid)
  );
