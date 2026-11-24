/* =====================================================================================
   0010 — CORE (v2).  Run after 0009.
   Model:  profile (a "library" the world can see)  →  shelves (a shelf IS a novel)  →  chapters (one file each).
   Visibility is deliberately simple:
     * profiles are public;
     * a chapter is visible to others only when it is PUBLISHED, its file is READY and it was not taken down;
     * a shelf is visible to others only when it has at least one such chapter (so a shelf of drafts is invisible);
     * the owner always sees everything of theirs, drafts included.
   There are no passwords, friends, blocks or privacy modes any more.
   "Read only" (shelves.downloadable = false) only hides the save button in the app: anyone who can read a file
   can technically keep it. The docs say so; the app must not claim copy protection.
   The app never uses the service-role key. Chapters/shelves are written by their owner only; publishing and
   takedown go through functions, so a client can never set published_at / removed_at directly.
   ===================================================================================== */

create schema if not exists private;   -- not exposed by the API: helpers cannot be called as /rpc

create type public.file_status as enum ('pending', 'ready', 'failed');
create type public.report_target as enum ('chapter', 'shelf', 'profile');
create type public.report_reason as enum ('copyright', 'illegal', 'abuse', 'spam', 'other');
create type public.report_status as enum ('open', 'dismissed', 'actioned');

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

/* ------------------------------------------------------------------ profiles */
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  handle text not null,
  display_name text not null,
  bio text not null default '',
  avatar_v integer not null default 0,   -- 0 = no picture; bumped on every new upload (cache-busting)
  cover_v integer not null default 0,    -- the big background picture
  handle_changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_handle_format check (handle ~ '^[a-z0-9][a-z0-9_.]{1,28}[a-z0-9]$' and handle !~ '[_.]{2}'),
  constraint profiles_display_name_len check (char_length(btrim(display_name)) between 1 and 60),
  constraint profiles_bio_len check (char_length(bio) <= 300),
  constraint profiles_versions check (avatar_v between 0 and 1000000 and cover_v between 0 and 1000000)
);
create unique index profiles_handle_key on public.profiles (handle);
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

create table public.reserved_handles (handle text primary key);
insert into public.reserved_handles (handle) values
  ('admin'), ('administrator'), ('root'), ('support'), ('help'), ('margins'), ('margin'), ('moderator'),
  ('mod'), ('official'), ('security'), ('staff'), ('system'), ('null'), ('undefined'), ('anonymous'),
  ('me'), ('you'), ('api'), ('www'), ('settings'), ('account'), ('library'), ('shelf'), ('book'), ('discover'), ('home');

/* ------------------------------------------------------------------- shelves (= novels) */
create table public.shelves (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  description text not null default '',
  cover_v integer not null default 0,
  downloadable boolean not null default true,
  license text,                 -- rights declaration comes later; kept so no new migration is needed for it
  origin text,
  removed_at timestamptz,       -- set only by a moderator (resolve_report)
  removed_reason public.report_reason,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  constraint shelves_title_len check (char_length(btrim(title)) between 1 and 80),
  constraint shelves_description_len check (char_length(description) <= 1000),
  constraint shelves_cover_v check (cover_v between 0 and 1000000),
  constraint shelves_license_len check (char_length(coalesce(license, '')) <= 200 and char_length(coalesce(origin, '')) <= 300)
);
create index shelves_owner on public.shelves (owner_id, created_at);
create trigger shelves_touch before update on public.shelves for each row execute function public.touch_updated_at();

/* ------------------------------------------------------------------- chapters (one file each) */
create table public.chapters (
  id uuid primary key default gen_random_uuid(),
  shelf_id uuid not null,
  owner_id uuid not null,
  position integer not null default 0,
  title text not null,
  format text not null,
  file_hash text not null,                 -- sha256: never shown to other users
  file_size bigint not null,
  file_status public.file_status not null default 'pending',   -- only finalize_chapter_upload sets 'ready'
  published_at timestamptz,                -- null = draft; only publish_chapters sets it
  removed_at timestamptz,                  -- only a moderator sets it
  removed_reason public.report_reason,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  unique (owner_id, file_hash),
  foreign key (shelf_id, owner_id) references public.shelves (id, owner_id) on delete cascade,
  constraint chapters_format check (format in ('epub', 'pdf')),
  constraint chapters_hash check (file_hash ~ '^[0-9a-f]{64}$'),
  constraint chapters_size check (file_size > 0 and file_size <= 52428800),   -- 50 MB: the Supabase free-plan ceiling
  constraint chapters_title_len check (char_length(btrim(title)) between 1 and 200),
  constraint chapters_position check (position between 0 and 100000)
);
create index chapters_shelf on public.chapters (shelf_id, position);
create trigger chapters_touch before update on public.chapters for each row execute function public.touch_updated_at();

/* ------------------------------------------------------------------- moderation */
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  target_type public.report_target not null,
  target_id uuid not null,
  reason public.report_reason not null,
  details text not null default '' check (char_length(details) <= 1000),
  status public.report_status not null default 'open',
  created_at timestamptz not null default now(),
  handled_by uuid references public.profiles (id) on delete set null,
  handled_at timestamptz,
  resolution text check (resolution in ('dismissed', 'removed', 'noted')),
  note text not null default '' check (char_length(note) <= 1000)
);
create unique index reports_one_open on public.reports (reporter_id, target_type, target_id) where status = 'open';
create index reports_queue on public.reports (status, created_at);
create index reports_target on public.reports (target_type, target_id);

create table public.moderators (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table private.removed_hashes (file_hash text primary key, created_at timestamptz not null default now());

/* ------------------------------------------------------------------- RLS + privileges */
alter table public.profiles enable row level security;
alter table public.reserved_handles enable row level security;
alter table public.shelves enable row level security;
alter table public.chapters enable row level security;
alter table public.reports enable row level security;
alter table public.moderators enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on private.removed_hashes from public, anon, authenticated;

grant select (id, handle, display_name, bio, avatar_v, cover_v, created_at) on public.profiles to anon, authenticated;
grant update (display_name, bio, avatar_v, cover_v) on public.profiles to authenticated;

-- removed_at / removed_reason are not selectable: the owner learns about a takedown through my_removed()
grant select (id, owner_id, title, description, cover_v, downloadable, license, origin, created_at, updated_at) on public.shelves to anon, authenticated;
grant insert (owner_id, title, description, downloadable, license, origin) on public.shelves to authenticated;
grant update (title, description, cover_v, downloadable, license, origin) on public.shelves to authenticated;
grant delete on public.shelves to authenticated;

-- file_hash is never selectable; file_status / published_at / removed_* can only change through the functions below
grant select (id, shelf_id, owner_id, position, title, format, file_size, file_status, published_at, created_at, updated_at) on public.chapters to anon, authenticated;
grant insert (shelf_id, owner_id, position, title, format, file_hash, file_size) on public.chapters to authenticated;
grant update (title, position) on public.chapters to authenticated;
grant delete on public.chapters to authenticated;

-- reports, moderators, reserved_handles: no client privileges at all

/* ------------------------------------------------------------------- the visibility rules (one place) */
create function private.chapter_visible(p_chapter uuid, uid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.chapters c join public.shelves s on s.id = c.shelf_id
    where c.id = p_chapter and (
      c.owner_id = uid
      or (s.removed_at is null and c.removed_at is null and c.published_at is not null and c.file_status = 'ready')))
$$;

create function private.shelf_visible(p_shelf uuid, uid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.shelves s where s.id = p_shelf and (
      s.owner_id = uid
      or (s.removed_at is null and exists (
            select 1 from public.chapters c
            where c.shelf_id = s.id and c.removed_at is null and c.published_at is not null and c.file_status = 'ready'))))
$$;

create function private.is_moderator(u uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select u is not null and exists (select 1 from public.moderators where user_id = u)
$$;

create policy profiles_read on public.profiles for select to anon, authenticated using (true);
create policy profiles_update on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- NB: the owner test comes FIRST so INSERT ... RETURNING works (a STABLE function cannot see the row being inserted)
create policy shelves_read on public.shelves for select to anon, authenticated
  using (owner_id = auth.uid() or private.shelf_visible(id, auth.uid()));
create policy shelves_insert on public.shelves for insert to authenticated with check (owner_id = auth.uid());
create policy shelves_update on public.shelves for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy shelves_delete on public.shelves for delete to authenticated using (owner_id = auth.uid());

create policy chapters_read on public.chapters for select to anon, authenticated
  using (owner_id = auth.uid() or private.chapter_visible(id, auth.uid()));
create policy chapters_insert on public.chapters for insert to authenticated with check (owner_id = auth.uid());
create policy chapters_update on public.chapters for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy chapters_delete on public.chapters for delete to authenticated using (owner_id = auth.uid());

/* ------------------------------------------------------------------- validation, quotas, takedown memory */
create function private.check_handle() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.reserved_handles r where r.handle = new.handle) then
    raise exception 'handle_reserved' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger profiles_check_handle before insert or update of handle on public.profiles for each row execute function private.check_handle();

create function private.enforce_quota() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer; lim integer := tg_argv[1]::integer;
begin
  execute format('select count(*) from public.%I where %I = $1', tg_argv[0], tg_argv[2]) into n using (to_jsonb(new) ->> tg_argv[2])::uuid;
  if n >= lim then raise exception 'quota_exceeded:%', tg_argv[0] using errcode = '53400'; end if;
  return new;
end $$;
create trigger shelves_quota before insert on public.shelves for each row execute function private.enforce_quota('shelves', '200', 'owner_id');
create trigger chapters_quota before insert on public.chapters for each row execute function private.enforce_quota('chapters', '300', 'shelf_id');

/* the same file cannot be added again after a takedown */
create function private.refuse_removed_hash() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from private.removed_hashes where file_hash = new.file_hash) then
    raise exception 'content_removed' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger chapters_refuse_removed before insert on public.chapters for each row execute function private.refuse_removed_hash();

/* ------------------------------------------------------------------- RPCs: profile */
create function public.handle_is_valid(h text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select h ~ '^[a-z0-9][a-z0-9_.]{1,28}[a-z0-9]$' and h !~ '[_.]{2}'
$$;

create function public.handle_available(p_handle text) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare h text := lower(btrim(coalesce(p_handle, '')));
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return public.handle_is_valid(h)
     and not exists (select 1 from public.reserved_handles where handle = h)
     and not exists (select 1 from public.profiles where handle = h);
end $$;

create function public.create_profile(p_handle text, p_display_name text, p_bio text default '')
returns public.profiles language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); p public.profiles;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  insert into public.profiles (id, handle, display_name, bio)
  values (uid, lower(btrim(p_handle)), btrim(p_display_name), coalesce(p_bio, ''))
  returning * into p;
  return p;
end $$;

create function public.change_handle(p_handle text) returns public.profiles
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); p public.profiles;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into p from public.profiles where id = uid for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if p.handle_changed_at is not null and p.handle_changed_at > now() - interval '30 days' then
    raise exception 'handle_cooldown' using errcode = 'P0001';
  end if;
  update public.profiles set handle = lower(btrim(p_handle)), handle_changed_at = now() where id = uid returning * into p;
  return p;
end $$;

create function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from auth.users where id = uid;
end $$;

/* ------------------------------------------------------------------- RPCs: chapters */
/* after uploading, the owner asks the database to check the file: stored size must equal the declared size */
create function public.finalize_chapter_upload(p_chapter uuid) returns public.file_status
language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare uid uuid := auth.uid(); c public.chapters; o storage.objects; s public.file_status;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into c from public.chapters where id = p_chapter and owner_id = uid;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  select * into o from storage.objects where bucket_id = 'books' and name = uid::text || '/' || c.id::text || '.' || c.format;
  if not found then raise exception 'upload_missing' using errcode = 'P0001'; end if;
  s := case when (o.metadata ->> 'size')::bigint = c.file_size then 'ready' else 'failed' end;
  update public.chapters set file_status = s where id = c.id;
  return s;
end $$;

/* publish: only ready, not-removed chapters of the caller; returns how many were published */
create function public.publish_chapters(p_ids uuid[]) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); n integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  update public.chapters set published_at = coalesce(published_at, now())
   where owner_id = uid and id = any (p_ids) and file_status = 'ready' and removed_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

create function public.unpublish_chapters(p_ids uuid[]) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); n integer;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  update public.chapters set published_at = null where owner_id = uid and id = any (p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

/* the caller's own chapter ids with their hashes (file_hash is never selectable): lets any device match local files to online records */
create function public.my_chapter_hashes() returns table (id uuid, file_hash text)
language sql stable security definer set search_path = public, pg_temp as $$
  select c.id, c.file_hash from public.chapters c where c.owner_id = auth.uid()
$$;

/* ------------------------------------------------------------------- storage */
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('books', 'books', false, 52428800, array['application/epub+zip', 'application/pdf']),     -- chapter files: private
  ('media', 'media', true,  409600,   array['image/webp', 'image/jpeg'])                      -- avatars, covers: public, small
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

/* chapter files:  books/<owner id>/<chapter id>.<epub|pdf>
   - the owner may write only for a chapter she owns, and only until the file is 'ready' (a published file never changes);
   - others may read the file only while the chapter is visible to them (published, ready, not removed). */
create function private.chapter_object_ok(p_name text, uid uuid, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m text[]; c public.chapters;
begin
  if p_name is null then return false; end if;
  m := regexp_match(p_name, '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(epub|pdf)$');
  if m is null then return false; end if;
  select * into c from public.chapters where id = m[2]::uuid and owner_id = m[1]::uuid;
  if not found or c.format <> m[3] then return false; end if;
  if p_write then
    return uid is not null and c.owner_id = uid and c.file_status <> 'ready';
  end if;
  return uid is not null and (c.owner_id = uid or private.chapter_visible(c.id, uid));
end $$;

/* pictures:  media/<owner id>/avatar.webp | cover.webp | shelf-<shelf id>.webp  (.jpg also allowed) */
create function private.media_object_ok(p_name text, uid uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m text[];
begin
  if uid is null or p_name is null then return false; end if;
  m := regexp_match(p_name, '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/(avatar|cover|shelf-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(webp|jpg)$');
  if m is null or m[1]::uuid <> uid then return false; end if;
  if m[2] like 'shelf-%' then
    return exists (select 1 from public.shelves s where s.id = substr(m[2], 7)::uuid and s.owner_id = uid);
  end if;
  return exists (select 1 from public.profiles p where p.id = uid);
end $$;

create policy margins_books_select on storage.objects for select to authenticated
  using (bucket_id = 'books' and private.chapter_object_ok(name, auth.uid(), false));
create policy margins_books_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'books' and private.chapter_object_ok(name, auth.uid(), true));
create policy margins_books_update on storage.objects for update to authenticated
  using (bucket_id = 'books' and private.chapter_object_ok(name, auth.uid(), true))
  with check (bucket_id = 'books' and private.chapter_object_ok(name, auth.uid(), true));
create policy margins_books_delete on storage.objects for delete to authenticated
  using (bucket_id = 'books' and private.chapter_object_ok(name, auth.uid(), false) and split_part(name, '/', 1) = auth.uid()::text);

create policy margins_media_select on storage.objects for select to anon, authenticated using (bucket_id = 'media');
create policy margins_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and private.media_object_ok(name, auth.uid()));
create policy margins_media_update on storage.objects for update to authenticated
  using (bucket_id = 'media' and private.media_object_ok(name, auth.uid()))
  with check (bucket_id = 'media' and private.media_object_ok(name, auth.uid()));
create policy margins_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'media' and private.media_object_ok(name, auth.uid()));

/* ------------------------------------------------------------------- RPCs: reports and moderation */
create function public.report_content(p_type public.report_target, p_id uuid, p_reason public.report_reason, p_details text default '')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); v_owner uuid; rid uuid;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'profile_required' using errcode = 'P0001'; end if;
  -- the reporter must be able to see what they report (so a report cannot be used to probe hidden things)
  if p_type = 'chapter' then
    if not private.chapter_visible(p_id, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
    select c.owner_id into v_owner from public.chapters c where c.id = p_id;
  elsif p_type = 'shelf' then
    if not private.shelf_visible(p_id, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
    select s.owner_id into v_owner from public.shelves s where s.id = p_id;
  else
    select p.id into v_owner from public.profiles p where p.id = p_id;
    if v_owner is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  end if;
  if v_owner = uid then raise exception 'invalid_request' using errcode = 'P0001'; end if;
  if (select count(*) from public.reports r where r.reporter_id = uid and r.created_at > now() - interval '24 hours') >= 10 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.reports r where r.reporter_id = uid and r.target_type = p_type and r.target_id = p_id and r.status = 'open') then
    raise exception 'already_reported' using errcode = 'P0001';
  end if;
  insert into public.reports (reporter_id, target_type, target_id, reason, details)
  values (uid, p_type, p_id, p_reason, left(btrim(coalesce(p_details, '')), 1000)) returning id into rid;
  return rid;
end $$;

/* the owner sees what was taken down and why (the columns themselves are not readable) */
create function public.my_removed() returns table (kind text, item_id uuid, title text, reason public.report_reason, removed_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return query
    select 'chapter'::text, c.id, c.title, c.removed_reason, c.removed_at from public.chapters c where c.owner_id = uid and c.removed_at is not null
    union all
    select 'shelf'::text, s.id, s.title, s.removed_reason, s.removed_at from public.shelves s where s.owner_id = uid and s.removed_at is not null
    order by 5 desc;
end $$;

create function public.am_i_moderator() returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return private.is_moderator(auth.uid());
end $$;

create function public.moderation_queue(p_status text default 'open', p_limit integer default 30, p_offset integer default 0)
returns table (id uuid, target_type public.report_target, target_id uuid, reason public.report_reason, details text, status public.report_status,
               created_at timestamptz, handled_at timestamptz, resolution text, note text, reporter_handle text,
               target_title text, owner_handle text, owner_name text, item_removed boolean, open_reports bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_moderator(uid) then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
  select r.id, r.target_type, r.target_id, r.reason, r.details, r.status, r.created_at, r.handled_at, r.resolution, r.note, rp.handle,
         case r.target_type
           when 'chapter' then (select c.title from public.chapters c where c.id = r.target_id)
           when 'shelf' then (select s.title from public.shelves s where s.id = r.target_id)
           else (select p.display_name from public.profiles p where p.id = r.target_id) end,
         op.handle, op.display_name,
         coalesce(case r.target_type
           when 'chapter' then (select c.removed_at is not null from public.chapters c where c.id = r.target_id)
           when 'shelf' then (select s.removed_at is not null from public.shelves s where s.id = r.target_id)
           else false end, false),
         (select count(*) from public.reports o where o.target_type = r.target_type and o.target_id = r.target_id and o.status = 'open')
  from public.reports r
  join public.profiles rp on rp.id = r.reporter_id
  left join public.profiles op on op.id = case r.target_type
      when 'chapter' then (select c.owner_id from public.chapters c where c.id = r.target_id)
      when 'shelf' then (select s.owner_id from public.shelves s where s.id = r.target_id)
      else r.target_id end
  where case when p_status = 'open' then r.status = 'open' else r.status <> 'open' end
  order by case when p_status = 'open' then r.created_at end asc, r.handled_at desc nulls last, r.id
  limit least(greatest(coalesce(p_limit, 30), 1), 100) offset least(greatest(coalesce(p_offset, 0), 0), 2000);
end $$;

create function public.resolve_report(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.reports; c public.chapters; v_note text := left(btrim(coalesce(p_note, '')), 1000);
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_moderator(uid) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_action not in ('dismiss', 'takedown', 'noted') then raise exception 'invalid_request' using errcode = 'P0001'; end if;
  select * into r from public.reports where id = p_id and status = 'open' for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;

  if p_action = 'takedown' then
    if r.target_type = 'chapter' then
      select * into c from public.chapters where id = r.target_id for update;
      if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
      update public.chapters set removed_at = now(), removed_reason = r.reason, published_at = null where id = c.id;
      insert into private.removed_hashes (file_hash) values (c.file_hash) on conflict do nothing;
    elsif r.target_type = 'shelf' then
      if not exists (select 1 from public.shelves where id = r.target_id) then raise exception 'not_found' using errcode = 'P0001'; end if;
      update public.shelves set removed_at = now(), removed_reason = r.reason where id = r.target_id;
    else
      raise exception 'invalid_request' using errcode = 'P0001';   -- accounts are not banned automatically
    end if;
    -- every open report about the same item is settled together
    update public.reports set status = 'actioned', resolution = 'removed', handled_by = uid, handled_at = now(), note = v_note
     where target_type = r.target_type and target_id = r.target_id and status = 'open';
  else
    update public.reports set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end::public.report_status,
           resolution = case when p_action = 'dismiss' then 'dismissed' else 'noted' end,
           handled_by = uid, handled_at = now(), note = v_note where id = r.id;
  end if;
end $$;

/* undo a takedown: the chapter comes back as a DRAFT (the owner decides about publishing again) */
create function public.restore_item(p_type public.report_target, p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); c public.chapters;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_moderator(uid) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_type = 'chapter' then
    select * into c from public.chapters where id = p_id and removed_at is not null for update;
    if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
    update public.chapters set removed_at = null, removed_reason = null where id = c.id;
    delete from private.removed_hashes where file_hash = c.file_hash;
  elsif p_type = 'shelf' then
    update public.shelves set removed_at = null, removed_reason = null where id = p_id and removed_at is not null;
    if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  else
    raise exception 'invalid_request' using errcode = 'P0001';
  end if;
end $$;

/* ------------------------------------------------------------------- function privileges */
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
grant usage on schema private to anon, authenticated;
-- policies run as the caller, so the callers need EXECUTE on the helpers (the schema is not API-exposed)
grant execute on function
  private.chapter_visible(uuid, uuid), private.shelf_visible(uuid, uuid),
  private.chapter_object_ok(text, uuid, boolean), private.media_object_ok(text, uuid)
  to anon, authenticated, service_role;

grant execute on function
  public.handle_available(text), public.create_profile(text, text, text), public.change_handle(text), public.delete_my_account(),
  public.finalize_chapter_upload(uuid), public.publish_chapters(uuid[]), public.unpublish_chapters(uuid[]), public.my_chapter_hashes(),
  public.report_content(public.report_target, uuid, public.report_reason, text), public.my_removed(),
  public.am_i_moderator(), public.moderation_queue(text, integer, integer), public.resolve_report(uuid, text, text),
  public.restore_item(public.report_target, uuid)
  to authenticated;
-- the handle format check is a pure helper and is used by clients before they ask the server
grant execute on function public.handle_is_valid(text) to anon, authenticated;
