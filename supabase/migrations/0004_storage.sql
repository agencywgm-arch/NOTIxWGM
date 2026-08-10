-- ============================================================================
--  NOTI Calling — 0004_storage.sql
--  Bucket public « noti » : logos de lieu + visuels produits.
--  Convention de chemin : {venue_id}/products/xxx.jpg — le premier segment
--  contrôle qui a le droit d'écrire.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'noti', 'noti', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists noti_read on storage.objects;
create policy noti_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'noti');

drop policy if exists noti_insert on storage.objects;
create policy noti_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'noti'
    and public.is_staff(nullif(split_part(name, '/', 1), '')::uuid)
  );

drop policy if exists noti_update on storage.objects;
create policy noti_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'noti'
    and public.is_staff(nullif(split_part(name, '/', 1), '')::uuid)
  );

drop policy if exists noti_delete on storage.objects;
create policy noti_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'noti'
    and public.is_staff(nullif(split_part(name, '/', 1), '')::uuid)
  );
