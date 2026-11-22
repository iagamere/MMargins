/* =====================================================================================
   Stage 3a: private file storage for published books.
   - buckets are PRIVATE; nobody reads a file through a public URL.
   - the owner may upload only to  <their user id>/<book id>.<epub|pdf>  (covers: .jpg) for a book they own;
   - a book becomes visible to others ONLY through finalize_book_upload(), which checks the stored size.
   - reading by other people (stage 3b) will extend the SELECT policy; today only the owner can read files.
   ===================================================================================== */

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('books',  'books',  false, 52428800, array['application/epub+zip', 'application/pdf']),   -- 50 MB: the Supabase free-plan ceiling
  ('covers', 'covers', false, 2097152,  array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

/* does this object path belong to a book of `uid`?  need_open: refuse changes to the file of a book that is already published */
create function private.own_object_ok(p_bucket text, p_name text, uid uuid, need_open boolean) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  m text[];
  b public.books;
begin
  if uid is null or p_name is null then return false; end if;
  m := regexp_match(p_name, '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(epub|pdf|jpg)$');
  if m is null or m[1]::uuid <> uid then return false; end if;
  select * into b from public.books where id = m[2]::uuid and owner_id = uid;
  if not found then return false; end if;
  if p_bucket = 'books' then
    if m[3] <> b.format then return false; end if;
    if need_open and b.file_status = 'ready' then return false; end if;
    return true;
  elsif p_bucket = 'covers' then
    return m[3] = 'jpg';
  end if;
  return false;
end $$;

create policy margins_objects_select on storage.objects for select to authenticated
  using (private.own_object_ok(bucket_id, name, auth.uid(), false));
create policy margins_objects_insert on storage.objects for insert to authenticated
  with check (private.own_object_ok(bucket_id, name, auth.uid(), bucket_id = 'books'));
create policy margins_objects_update on storage.objects for update to authenticated
  using (private.own_object_ok(bucket_id, name, auth.uid(), bucket_id = 'books'))
  with check (private.own_object_ok(bucket_id, name, auth.uid(), bucket_id = 'books'));
create policy margins_objects_delete on storage.objects for delete to authenticated
  using (private.own_object_ok(bucket_id, name, auth.uid(), false));

/* after uploading, the owner asks the database to check the file: stored size must equal the declared size */
create function public.finalize_book_upload(p_book uuid) returns public.file_status
language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare
  uid uuid := auth.uid();
  b public.books;
  o storage.objects;
  s public.file_status;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into b from public.books where id = p_book and owner_id = uid;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  select * into o from storage.objects where bucket_id = 'books' and name = uid::text || '/' || b.id::text || '.' || b.format;
  if not found then raise exception 'upload_missing' using errcode = 'P0001'; end if;
  s := case when (o.metadata ->> 'size')::bigint = b.file_size then 'ready' else 'failed' end;
  update public.books set file_status = s where id = b.id;
  return s;
end $$;

/* the owner's own book ids with their hashes (file_hash is never selectable): lets any device match local files to online records */
create function public.my_book_hashes() returns table (id uuid, file_hash text)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.id, b.file_hash from public.books b where b.owner_id = auth.uid()
$$;

revoke all on function private.own_object_ok(text, text, uuid, boolean) from public, anon;
grant execute on function private.own_object_ok(text, text, uuid, boolean) to authenticated, service_role;
revoke all on function public.finalize_book_upload(uuid), public.my_book_hashes() from public, anon;
grant execute on function public.finalize_book_upload(uuid), public.my_book_hashes() to authenticated;
