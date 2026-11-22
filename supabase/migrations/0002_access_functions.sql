create schema if not exists private;   -- not exposed by the API: helpers cannot be called as /rpc

-- The single place where "who may see what" is decided. Row-level security (0003) and the storage
-- policies call ONLY these functions, so the rules cannot drift apart.
--
-- RULES (also documented in docs/ONLINE_SETUP.md)
--  1. Modes: public > password > friends > private  (strictness 1..4). 'inherit' means "ask the parent".
--  2. A shelf inherits the library default unless it has its own mode.
--  3. A book with its OWN mode uses it, whatever its shelves say (an explicit choice is never loosened).
--  4. A book that inherits takes the MOST RESTRICTIVE mode of all the shelves it sits on
--     (or the library default when it is on no shelf). So a book on a public shelf AND a private
--     shelf is private: no path can leak it.
--  5. The owner always sees everything of theirs. A block hides everything in both directions,
--     even public content.
--  6. Non-owners never see a book until its file is 'ready'.
--  7. Reading / downloading the FILE additionally needs books.read_allowed / download_allowed.
--  8. 'password' needs a live grant (see redeem_access_password) for the resource that carries the password.

create function private.mode_strictness(m public.access_mode) returns integer
language sql immutable as $$
  select case m when 'public' then 1 when 'password' then 2 when 'friends' then 3 when 'private' then 4 else 0 end
$$;

create function private.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select a is not null and b is not null and exists (
    select 1 from public.friendships where user_a = least(a, b) and user_b = greatest(a, b))
$$;

create function private.is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select a is not null and b is not null and exists (
    select 1 from public.blocks where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a))
$$;

create function private.has_valid_grant(viewer uuid, t public.resource_type, rid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select viewer is not null and exists (
    select 1
    from public.access_grants g
    join public.access_secrets s on s.resource_type = g.resource_type and s.resource_id = g.resource_id and s.version = g.version
    where g.user_id = viewer and g.resource_type = t and g.resource_id = rid and g.expires_at > now())
$$;

/* does `mode` let `viewer` in, for content owned by `owner`? grant_ok = viewer holds the password grant */
create function private.mode_allows(owner uuid, mode public.access_mode, viewer uuid, grant_ok boolean) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if viewer is not null and viewer = owner then return true; end if;
  if viewer is not null and private.is_blocked_between(owner, viewer) then return false; end if;
  return case mode
    when 'public' then true
    when 'password' then viewer is not null and coalesce(grant_ok, false)
    when 'friends' then viewer is not null and private.are_friends(owner, viewer)
    else false
  end;
end $$;

/* ------------------------------------------------------------ effective modes */
create function private.shelf_effective_mode(p_shelf uuid) returns public.access_mode
language sql stable security definer set search_path = public, pg_temp as $$
  select case when s.access = 'inherit' then l.default_access else s.access end
  from public.shelves s join public.libraries l on l.id = s.library_id
  where s.id = p_shelf
$$;

create function private.book_effective_mode(p_book uuid) returns public.access_mode
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when b.access <> 'inherit' then b.access
    else coalesce(
      (select m from (
         select private.shelf_effective_mode(sb.shelf_id) as m
         from public.shelf_books sb where sb.book_id = b.id
       ) x order by private.mode_strictness(m) desc limit 1),
      (select l.default_access from public.libraries l where l.owner_id = b.owner_id))
  end
  from public.books b where b.id = p_book
$$;

/* ---------------------------------------------------------------- visibility */
create function private.can_view_library(p_library uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare l public.libraries;
begin
  select * into l from public.libraries where id = p_library;
  if not found then return false; end if;
  return private.mode_allows(l.owner_id, l.default_access, viewer, private.has_valid_grant(viewer, 'library', l.id));
end $$;

create function private.shelf_grant_ok(p_shelf uuid, viewer uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case when s.access = 'inherit'
              then private.has_valid_grant(viewer, 'library', s.library_id)
              else private.has_valid_grant(viewer, 'shelf', s.id) end
  from public.shelves s where s.id = p_shelf
$$;

create function private.can_view_shelf(p_shelf uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.shelves;
begin
  select * into s from public.shelves where id = p_shelf;
  if not found then return false; end if;
  return private.mode_allows(s.owner_id, private.shelf_effective_mode(s.id), viewer, private.shelf_grant_ok(s.id, viewer));
end $$;

/* the password grant that unlocks a book whose effective mode is 'password' */
create function private.book_grant_ok(p_book uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b public.books;
begin
  select * into b from public.books where id = p_book;
  if not found or viewer is null then return false; end if;
  if b.access <> 'inherit' then return private.has_valid_grant(viewer, 'book', b.id); end if;
  if exists (select 1 from public.shelf_books where book_id = b.id) then
    return exists (
      select 1 from public.shelf_books sb
      where sb.book_id = b.id
        and private.shelf_effective_mode(sb.shelf_id) = 'password'
        and private.shelf_grant_ok(sb.shelf_id, viewer));
  end if;
  return private.has_valid_grant(viewer, 'library', (select l.id from public.libraries l where l.owner_id = b.owner_id));
end $$;

create function private.can_view_book(p_book uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b public.books;
begin
  select * into b from public.books where id = p_book;
  if not found then return false; end if;
  if viewer is not null and viewer = b.owner_id then return true; end if;
  if b.file_status <> 'ready' then return false; end if;
  return private.mode_allows(b.owner_id, private.book_effective_mode(b.id), viewer, private.book_grant_ok(b.id, viewer));
end $$;

/* file access = can see the book AND the owner switched the action on */
create function private.can_read_book_file(p_book uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b public.books;
begin
  select * into b from public.books where id = p_book;
  if not found then return false; end if;
  if viewer is not null and viewer = b.owner_id then return true; end if;
  return b.read_allowed and private.can_view_book(p_book, viewer);
end $$;

create function private.can_download_book_file(p_book uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b public.books;
begin
  select * into b from public.books where id = p_book;
  if not found then return false; end if;
  if viewer is not null and viewer = b.owner_id then return true; end if;
  return b.download_allowed and private.can_view_book(p_book, viewer);
end $$;

/* a series is visible when the owner looks, or when at least one of its books is visible */
create function private.can_view_series(p_series uuid, viewer uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.series s where s.id = p_series and viewer is not null and s.owner_id = viewer)
      or exists (select 1 from public.books b where b.series_id = p_series and private.can_view_book(b.id, viewer))
$$;

create function private.can_subscribe(t public.subscription_target, tid uuid, viewer uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if viewer is null then return false; end if;
  return case t
    when 'user' then tid <> viewer and exists (select 1 from public.profiles where id = tid) and not private.is_blocked_between(tid, viewer)
    when 'library' then private.can_view_library(tid, viewer)
    when 'shelf' then private.can_view_shelf(tid, viewer)
    when 'series' then private.can_view_series(tid, viewer)
  end;
end $$;

/* ------------------------------------------------------------------- cleanup */
-- polymorphic references have no foreign key: these triggers keep them tidy
create function private.cleanup_resource() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare rt public.resource_type;
begin
  rt := tg_argv[0]::public.resource_type;
  delete from public.access_secrets where resource_type = rt and resource_id = old.id;
  delete from public.access_grants where resource_type = rt and resource_id = old.id;
  if rt = 'shelf' then delete from public.subscriptions where target_type = 'shelf' and target_id = old.id; end if;
  if rt = 'library' then delete from public.subscriptions where target_type = 'library' and target_id = old.id; end if;
  return old;
end $$;
create trigger shelves_cleanup after delete on public.shelves for each row execute function private.cleanup_resource('shelf');
create trigger books_cleanup after delete on public.books for each row execute function private.cleanup_resource('book');
create trigger libraries_cleanup after delete on public.libraries for each row execute function private.cleanup_resource('library');

create function private.cleanup_series() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from public.subscriptions where target_type = 'series' and target_id = old.id;
  return old;
end $$;
create trigger series_cleanup after delete on public.series for each row execute function private.cleanup_series();

create function private.cleanup_profile() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from public.subscriptions where target_type = 'user' and target_id = old.id;
  return old;
end $$;
create trigger profiles_cleanup after delete on public.profiles for each row execute function private.cleanup_profile();

/* ----------------------------------------------------------- validation / quotas */
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
create trigger books_quota before insert on public.books for each row execute function private.enforce_quota('books', '2000', 'owner_id');
create trigger subscriptions_quota before insert on public.subscriptions for each row execute function private.enforce_quota('subscriptions', '1000', 'subscriber_id');

/* who owns a resource / a subscription target */
create function private.resource_owner(t public.resource_type, rid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case t
    when 'library' then (select owner_id from public.libraries where id = rid)
    when 'shelf' then (select owner_id from public.shelves where id = rid)
    when 'book' then (select owner_id from public.books where id = rid) end
$$;

create function private.target_owner(t public.subscription_target, tid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case t
    when 'user' then (select id from public.profiles where id = tid)
    when 'library' then (select owner_id from public.libraries where id = tid)
    when 'shelf' then (select owner_id from public.shelves where id = tid)
    when 'series' then (select owner_id from public.series where id = tid) end
$$;
