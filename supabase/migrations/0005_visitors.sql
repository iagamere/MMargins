/* =====================================================================================
   Stage 3b: other people can open a library by @handle, unlock it with a password, and read / download books.
   - storage SELECT now also allows a visitor, but ONLY through the same functions that decide row visibility
     (private.can_read_book_file / can_download_book_file / can_view_book), so rules cannot drift apart;
   - visit_library(handle) is the single entry point: it tells the client whether the library is open, locked
     behind a password, or unavailable, and lists which shelves / books are locked, WITHOUT leaking names,
     titles or counts of anything the visitor may not see;
   - files are fetched by the client with its own session token (an authenticated GET that the policy checks on
     every request) instead of long-lived signed links, so there is no URL that can be forwarded.
   ===================================================================================== */

/* may `uid` fetch this stored object?  owner (as in 0004) or a visitor who is allowed to read / download the book */
create function private.object_readable(p_bucket text, p_name text, uid uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  m text[];
  b public.books;
begin
  if uid is null or p_name is null then return false; end if;
  if private.own_object_ok(p_bucket, p_name, uid, false) then return true; end if;
  m := regexp_match(p_name, '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(epub|pdf|jpg)$');
  if m is null then return false; end if;
  -- the folder must be the real owner of the book: a forged path never matches
  select * into b from public.books where id = m[2]::uuid and owner_id = m[1]::uuid;
  if not found then return false; end if;
  if p_bucket = 'books' then
    return m[3] = b.format and (private.can_read_book_file(b.id, uid) or private.can_download_book_file(b.id, uid));
  elsif p_bucket = 'covers' then
    return m[3] = 'jpg' and b.has_cover and private.can_view_book(b.id, uid);
  end if;
  return false;
end $$;

drop policy margins_objects_select on storage.objects;
create policy margins_objects_select on storage.objects for select to authenticated
  using (private.object_readable(bucket_id, name, auth.uid()));

/* Opens a library by handle.
     unknown handle and blocked (either direction) both raise not_found: they look the same.
     library.state: 'open'        the visitor may see the library page
                    'locked'      only a password stands in the way (and one is set): unlock with type 'library'
                    'unavailable' friends-only / private / anything else: nothing more is said
     shelves:       shelves the visitor can see (name, description) + shelves with THEIR OWN password
                    (id only: no name, no content). A shelf that merely inherits a locked library is not listed.
     locked_books:  ids of ready books with their own password that the visitor cannot see yet.
   Visible books are read through the normal tables (row-level security). */
create function public.visit_library(p_handle text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  viewer uuid := auth.uid();
  p public.profiles;
  l public.libraries;
  lib_ok boolean;
  lib_state text;
  shelf_list jsonb;
  locked jsonb;
begin
  select * into p from public.profiles where handle = lower(btrim(coalesce(p_handle, '')));
  if not found or (viewer is not null and viewer <> p.id and private.is_blocked_between(p.id, viewer)) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  select * into l from public.libraries where owner_id = p.id;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;

  lib_ok := private.can_view_library(l.id, viewer);
  lib_state := case
    when lib_ok then 'open'
    when l.default_access = 'password'
         and exists (select 1 from public.access_secrets s where s.resource_type = 'library' and s.resource_id = l.id) then 'locked'
    else 'unavailable' end;

  select coalesce(jsonb_agg(x.j order by x.position, x.created_at), '[]'::jsonb) into shelf_list
  from (
    select s.position, s.created_at,
      case
        when private.can_view_shelf(s.id, viewer)
          then jsonb_build_object('id', s.id, 'state', 'open', 'name', s.name, 'description', s.description, 'position', s.position)
        else jsonb_build_object('id', s.id, 'state', 'locked', 'position', s.position)
      end as j
    from public.shelves s
    where s.owner_id = p.id
      and (private.can_view_shelf(s.id, viewer)
           or (s.access = 'password'
               and exists (select 1 from public.access_secrets a where a.resource_type = 'shelf' and a.resource_id = s.id)))
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', b.id) order by b.created_at), '[]'::jsonb) into locked
  from public.books b
  where b.owner_id = p.id and b.access = 'password' and b.file_status = 'ready'
    and not private.can_view_book(b.id, viewer)
    and exists (select 1 from public.access_secrets a where a.resource_type = 'book' and a.resource_id = b.id);

  return jsonb_build_object(
    'profile', jsonb_build_object('id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'bio', p.bio),
    'library', case when lib_state = 'open'
                    then jsonb_build_object('id', l.id, 'state', lib_state, 'title', l.title, 'description', l.description)
                    else jsonb_build_object('id', l.id, 'state', lib_state) end,
    'shelves', shelf_list,
    'locked_books', locked);
end $$;

revoke all on function private.object_readable(text, text, uuid) from public, anon, authenticated;
grant execute on function private.object_readable(text, text, uuid) to authenticated, service_role;
revoke all on function public.visit_library(text) from public, anon, authenticated;
grant execute on function public.visit_library(text) to anon, authenticated;
