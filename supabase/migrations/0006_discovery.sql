/* =====================================================================================
   Stage 3c: discovery and search. PUBLIC content only.
   - There is no new table and no new privilege on a table: two read-only RPCs.
   - "Public" is decided by the SAME functions as everywhere else: private.can_view_book(book, NULL) /
     private.can_view_library(library, NULL), i.e. what a signed-out stranger could already read. So a
     book that is private / friends / password, still uploading or failed never shows up, and the
     rules cannot drift apart from the row-level security.
   - Blocks hide in both directions (a signed-in viewer never sees a user who blocked them or whom they blocked).
   - Nothing is returned that the tables would not already show to anyone: no file hash, no storage path.
   - Search is a plain case-insensitive substring match on every word (all words must match), so it works for
     Arabic, French and English alike. Pages are capped; results are newest first with a stable tie-break.
   ===================================================================================== */

/* escapes LIKE wildcards and splits a free-text query into at most 6 words of at most 40 characters each */
create function private.search_words(q text) returns text[]
language sql immutable set search_path = pg_temp as $$
  select coalesce(array_agg(w), '{}')
  from (
    select '%' || replace(replace(replace(left(x, 40), '\', '\\'), '%', '\%'), '_', '\_') || '%' as w
    from regexp_split_to_table(lower(btrim(left(coalesce(q, ''), 120))), '\s+') as x
    where x <> ''
    limit 6
  ) s
$$;

/* Public books, optionally filtered by words of the title / author / owner's handle and name. */
create function public.discover_books(p_query text default '', p_limit integer default 30, p_offset integer default 0)
returns table (
  id uuid, owner_id uuid, title text, author text, description text, language text, format text, file_size bigint,
  file_status public.file_status, has_cover boolean, read_allowed boolean, download_allowed boolean,
  owner_handle text, owner_name text
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  viewer uuid := auth.uid();
  words text[] := private.search_words(p_query);
  lim integer := least(greatest(coalesce(p_limit, 30), 1), 60);
  off integer := least(greatest(coalesce(p_offset, 0), 0), 5000);
begin
  return query
  select b.id, b.owner_id, b.title, b.author, b.description, b.language, b.format, b.file_size,
         b.file_status, b.has_cover, b.read_allowed, b.download_allowed, p.handle, p.display_name
  from public.books b
  join public.profiles p on p.id = b.owner_id
  where b.file_status = 'ready'
    and not (viewer is not null and private.is_blocked_between(b.owner_id, viewer))
    and not exists (
      select 1 from unnest(words) w
      where not (b.title ilike w or b.author ilike w or p.handle ilike w or p.display_name ilike w))
    and private.can_view_book(b.id, null)
  order by b.created_at desc, b.id
  limit lim offset off;
end $$;

/* Public libraries (default mode public) that hold at least one public book, matched by words of the
   owner's handle / name or the library's title. */
create function public.discover_libraries(p_query text default '', p_limit integer default 30, p_offset integer default 0)
returns table (
  handle text, display_name text, bio text, library_title text, library_description text, book_count bigint
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  viewer uuid := auth.uid();
  words text[] := private.search_words(p_query);
  lim integer := least(greatest(coalesce(p_limit, 30), 1), 60);
  off integer := least(greatest(coalesce(p_offset, 0), 0), 5000);
begin
  return query
  select x.handle, x.display_name, x.bio, x.title, x.description, x.n
  from (
    select p.handle, p.display_name, p.bio, l.title, l.description, l.created_at, l.id as lid,
           (select count(*) from public.books b
             where b.owner_id = p.id and b.file_status = 'ready' and private.can_view_book(b.id, null)) as n
    from public.libraries l
    join public.profiles p on p.id = l.owner_id
    where private.can_view_library(l.id, null)
      and not (viewer is not null and private.is_blocked_between(p.id, viewer))
      and not exists (
        select 1 from unnest(words) w
        where not (p.handle ilike w or p.display_name ilike w or l.title ilike w))
  ) x
  where x.n > 0
  order by x.n desc, x.created_at desc, x.lid
  limit lim offset off;
end $$;

revoke all on function private.search_words(text) from public, anon, authenticated;
grant execute on function private.search_words(text) to anon, authenticated, service_role;
revoke all on function public.discover_books(text, integer, integer), public.discover_libraries(text, integer, integer) from public, anon, authenticated;
grant execute on function public.discover_books(text, integer, integer), public.discover_libraries(text, integer, integer) to anon, authenticated;
