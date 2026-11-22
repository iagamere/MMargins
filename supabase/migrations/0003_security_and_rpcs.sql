-- Row-level security, least-privilege grants and the RPCs the app calls.
-- Clients never write relationship, secret, grant or attempt tables directly.

/* ------------------------------------------------------------------- RLS on */
alter table public.profiles enable row level security;
alter table public.reserved_handles enable row level security;
alter table public.libraries enable row level security;
alter table public.shelves enable row level security;
alter table public.series enable row level security;
alter table public.books enable row level security;
alter table public.shelf_books enable row level security;
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.blocks enable row level security;
alter table public.subscriptions enable row level security;
alter table public.access_secrets enable row level security;
alter table public.access_grants enable row level security;
alter table public.access_attempts enable row level security;

/* ------------------------------------------------------------ table privileges */
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select (id, handle, display_name, bio, created_at) on public.profiles to anon, authenticated;
grant update (display_name, bio) on public.profiles to authenticated;

grant select on public.libraries to anon, authenticated;
grant update (title, description, default_access) on public.libraries to authenticated;

grant select on public.shelves to anon, authenticated;
grant insert (library_id, owner_id, name, description, position, access) on public.shelves to authenticated;
grant update (name, description, position, access) on public.shelves to authenticated;
grant delete on public.shelves to authenticated;

grant select on public.series to anon, authenticated;
grant insert (owner_id, title) on public.series to authenticated;
grant update (title) on public.series to authenticated;
grant delete on public.series to authenticated;

-- file_hash, rights_confirmed_at and storage details are never selectable
grant select (id, owner_id, title, author, description, language, tags, series_id, series_position, format,
              file_size, file_status, has_cover, access, read_allowed, download_allowed, license, origin,
              created_at, updated_at) on public.books to anon, authenticated;
grant insert (owner_id, title, author, description, language, tags, series_id, series_position, format,
              file_hash, file_size, has_cover, access, read_allowed, download_allowed, license, origin,
              rights_confirmed_at) on public.books to authenticated;
grant update (title, author, description, language, tags, series_id, series_position, has_cover, access,
              read_allowed, download_allowed, license, origin) on public.books to authenticated;
grant delete on public.books to authenticated;

grant select on public.shelf_books to anon, authenticated;
grant insert (shelf_id, book_id, owner_id, position) on public.shelf_books to authenticated;
grant update (position) on public.shelf_books to authenticated;
grant delete on public.shelf_books to authenticated;

grant select on public.friend_requests, public.friendships, public.blocks to authenticated;

grant select on public.subscriptions to authenticated;
grant insert (subscriber_id, target_type, target_id) on public.subscriptions to authenticated;
grant update (muted) on public.subscriptions to authenticated;
grant delete on public.subscriptions to authenticated;

-- access_secrets / access_grants / access_attempts / reserved_handles: no client privileges at all

/* ----------------------------------------------------------------- policies */
-- NB: the owner test comes FIRST so INSERT ... RETURNING works (a STABLE function cannot see the row
-- being inserted by the same statement).
create policy profiles_read on public.profiles for select to anon, authenticated
  using (auth.uid() = id or not private.is_blocked_between(id, auth.uid()));
create policy profiles_update on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

create policy libraries_read on public.libraries for select to anon, authenticated
  using (owner_id = auth.uid() or private.can_view_library(id, auth.uid()));
create policy libraries_update on public.libraries for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy shelves_read on public.shelves for select to anon, authenticated
  using (owner_id = auth.uid() or private.can_view_shelf(id, auth.uid()));
create policy shelves_insert on public.shelves for insert to authenticated with check (owner_id = auth.uid());
create policy shelves_update on public.shelves for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy shelves_delete on public.shelves for delete to authenticated using (owner_id = auth.uid());

create policy series_read on public.series for select to anon, authenticated
  using (owner_id = auth.uid() or private.can_view_series(id, auth.uid()));
create policy series_insert on public.series for insert to authenticated with check (owner_id = auth.uid());
create policy series_update on public.series for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy series_delete on public.series for delete to authenticated using (owner_id = auth.uid());

create policy books_read on public.books for select to anon, authenticated
  using (owner_id = auth.uid() or private.can_view_book(id, auth.uid()));
create policy books_insert on public.books for insert to authenticated with check (owner_id = auth.uid());
create policy books_update on public.books for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy books_delete on public.books for delete to authenticated using (owner_id = auth.uid());

-- a membership row is visible only when BOTH the shelf and the book are visible to the viewer
create policy shelf_books_read on public.shelf_books for select to anon, authenticated
  using (owner_id = auth.uid()
         or (private.can_view_shelf(shelf_id, auth.uid()) and private.can_view_book(book_id, auth.uid())));
create policy shelf_books_insert on public.shelf_books for insert to authenticated with check (owner_id = auth.uid());
create policy shelf_books_update on public.shelf_books for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy shelf_books_delete on public.shelf_books for delete to authenticated using (owner_id = auth.uid());

create policy friend_requests_read on public.friend_requests for select to authenticated
  using (auth.uid() in (requester_id, recipient_id));
create policy friendships_read on public.friendships for select to authenticated
  using (auth.uid() in (user_a, user_b));
create policy blocks_read on public.blocks for select to authenticated using (blocker_id = auth.uid());

create policy subscriptions_read on public.subscriptions for select to authenticated using (subscriber_id = auth.uid());
create policy subscriptions_insert on public.subscriptions for insert to authenticated
  with check (subscriber_id = auth.uid() and private.can_subscribe(target_type, target_id, auth.uid()));
create policy subscriptions_update on public.subscriptions for update to authenticated
  using (subscriber_id = auth.uid()) with check (subscriber_id = auth.uid());
create policy subscriptions_delete on public.subscriptions for delete to authenticated using (subscriber_id = auth.uid());

/* ---------------------------------------------------------------------- RPCs */
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
returns public.profiles
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); p public.profiles;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  insert into public.profiles (id, handle, display_name, bio)
  values (uid, lower(btrim(p_handle)), btrim(p_display_name), coalesce(p_bio, ''))
  returning * into p;
  insert into public.libraries (owner_id) values (uid);   -- private until the owner decides otherwise
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

/* Deletes the account and, through ON DELETE CASCADE, every profile, library, shelf, book record,
   friendship, subscription and grant of this user. Stored FILES are removed by the delete-account
   edge function (stage 3) before it calls this. */
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from auth.users where id = uid;
end $$;

/* ------------------------------------------------------------ friend requests */
create function public.send_friend_request(p_recipient uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_recipient is null or p_recipient = uid then raise exception 'invalid_request' using errcode = 'P0001'; end if;
  -- unknown user and blocked user look exactly the same
  if not exists (select 1 from public.profiles where id = p_recipient) or private.is_blocked_between(uid, p_recipient) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if private.are_friends(uid, p_recipient) then raise exception 'already_friends' using errcode = 'P0001'; end if;
  if exists (select 1 from public.friend_requests where status = 'pending'
             and least(requester_id, recipient_id) = least(uid, p_recipient)
             and greatest(requester_id, recipient_id) = greatest(uid, p_recipient)) then
    raise exception 'already_pending' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.friend_requests where requester_id = uid and recipient_id = p_recipient
             and status = 'rejected' and responded_at > now() - interval '7 days') then
    raise exception 'cooldown' using errcode = 'P0001';
  end if;
  if (select count(*) from public.friend_requests where requester_id = uid and created_at > now() - interval '1 hour') >= 20
     or (select count(*) from public.friend_requests where requester_id = uid and status = 'pending') >= 100 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.friend_requests (requester_id, recipient_id) values (uid, p_recipient) returning id into rid;
  return rid;
end $$;

create function public.respond_friend_request(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.friend_requests;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.friend_requests where id = p_id and recipient_id = uid and status = 'pending' for update;
  if not found or private.is_blocked_between(r.requester_id, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
  update public.friend_requests set status = case when p_accept then 'accepted' else 'rejected' end::public.request_status,
         responded_at = now() where id = r.id;
  if p_accept then
    insert into public.friendships (user_a, user_b) values (least(r.requester_id, uid), greatest(r.requester_id, uid))
    on conflict do nothing;
  end if;
end $$;

create function public.cancel_friend_request(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  update public.friend_requests set status = 'cancelled', responded_at = now()
  where id = p_id and requester_id = uid and status = 'pending';
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
end $$;

create function public.remove_friend(p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.friendships where user_a = least(uid, p_user) and user_b = greatest(uid, p_user);
end $$;

create function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_user is null or p_user = uid or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'invalid_request' using errcode = 'P0001';
  end if;
  insert into public.blocks (blocker_id, blocked_id) values (uid, p_user) on conflict do nothing;
  delete from public.friendships where user_a = least(uid, p_user) and user_b = greatest(uid, p_user);
  update public.friend_requests set status = 'cancelled', responded_at = now()
   where status = 'pending' and ((requester_id = uid and recipient_id = p_user) or (requester_id = p_user and recipient_id = uid));
  -- no subscription survives a block, in either direction
  delete from public.subscriptions s
   where (s.subscriber_id = p_user and private.target_owner(s.target_type, s.target_id) = uid)
      or (s.subscriber_id = uid and private.target_owner(s.target_type, s.target_id) = p_user);
  -- password access granted by / to the blocked user ends too
  delete from public.access_grants g
   where (g.user_id = p_user and private.resource_owner(g.resource_type, g.resource_id) = uid)
      or (g.user_id = uid and private.resource_owner(g.resource_type, g.resource_id) = p_user);
end $$;

create function public.unblock_user(p_user uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.blocks where blocker_id = uid and blocked_id = p_user;
end $$;

/* ------------------------------------------------------------- shelf ordering */
create function public.reorder_shelves(p_ids uuid[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  update public.shelves s set position = o.ord::integer
  from unnest(p_ids) with ordinality as o(id, ord)
  where s.id = o.id and s.owner_id = uid;
end $$;

/* ------------------------------------------------------- password-protected access */
create function public.set_access_password(p_type public.resource_type, p_id uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if private.resource_owner(p_type, p_id) is distinct from uid then raise exception 'not_found' using errcode = 'P0001'; end if;
  if p_password is null or char_length(p_password) < 8 or char_length(p_password) > 128 then
    raise exception 'password_invalid' using errcode = 'P0001';
  end if;
  insert into public.access_secrets (resource_type, resource_id, owner_id, password_hash)
  values (p_type, p_id, uid, extensions.crypt(p_password, extensions.gen_salt('bf', 10)))
  on conflict (resource_type, resource_id) do update
    set password_hash = excluded.password_hash, version = public.access_secrets.version + 1, updated_at = now();
end $$;

create function public.remove_access_password(p_type public.resource_type, p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if private.resource_owner(p_type, p_id) is distinct from uid then raise exception 'not_found' using errcode = 'P0001'; end if;
  delete from public.access_secrets where resource_type = p_type and resource_id = p_id;
  delete from public.access_grants where resource_type = p_type and resource_id = p_id;
end $$;

create function public.revoke_access_grants(p_type public.resource_type, p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if private.resource_owner(p_type, p_id) is distinct from uid then raise exception 'not_found' using errcode = 'P0001'; end if;
  delete from public.access_grants where resource_type = p_type and resource_id = p_id;
end $$;

create function public.has_access_password(p_type public.resource_type, p_id uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null or private.resource_owner(p_type, p_id) is distinct from uid then return false; end if;
  return exists (select 1 from public.access_secrets where resource_type = p_type and resource_id = p_id);
end $$;

/* The ONLY way to obtain a grant. Always answers true/false: unknown resource, wrong password, no
   password set, blocked and locked-out all look the same. 5 failures / 15 min per resource and
   20 / hour per user lock the caller out. A grant lasts 24 hours and dies when the password changes. */
create function public.redeem_access_password(p_type public.resource_type, p_id uuid, p_password text) returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  uid uuid := auth.uid();
  s public.access_secrets;
  dummy constant text := '$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5BpD8w3k1rY0m8n3v8cq3K1Yq0zXa';
  ok boolean := false;
begin
  if uid is null then return false; end if;
  delete from public.access_attempts where user_id = uid and at < now() - interval '1 day';
  if (select count(*) from public.access_attempts where user_id = uid and resource_id = p_id and at > now() - interval '15 minutes') >= 5
     or (select count(*) from public.access_attempts where user_id = uid and at > now() - interval '1 hour') >= 20 then
    return false;
  end if;
  select * into s from public.access_secrets where resource_type = p_type and resource_id = p_id;
  -- always run one bcrypt comparison so timing does not reveal whether a secret exists
  ok := extensions.crypt(coalesce(p_password, ''), coalesce(s.password_hash, dummy)) = coalesce(s.password_hash, dummy)
        and s.resource_id is not null;
  if ok and private.is_blocked_between(s.owner_id, uid) then ok := false; end if;
  if ok then
    insert into public.access_grants (user_id, resource_type, resource_id, version, expires_at)
    values (uid, p_type, p_id, s.version, now() + interval '24 hours')
    on conflict (user_id, resource_type, resource_id) do update
      set version = excluded.version, granted_at = now(), expires_at = excluded.expires_at;
    delete from public.access_attempts where user_id = uid and resource_id = p_id;
  else
    insert into public.access_attempts (user_id, resource_id) values (uid, p_id);
  end if;
  return ok;
end $$;

/* ------------------------------------------------------ function privileges */
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
grant usage on schema private to anon, authenticated;
-- policies run as the caller, so the callers need EXECUTE on the helpers (schema is not API-exposed)
grant execute on function
  private.mode_strictness(public.access_mode), private.are_friends(uuid, uuid), private.is_blocked_between(uuid, uuid),
  private.has_valid_grant(uuid, public.resource_type, uuid), private.mode_allows(uuid, public.access_mode, uuid, boolean),
  private.shelf_effective_mode(uuid), private.book_effective_mode(uuid), private.can_view_library(uuid, uuid),
  private.shelf_grant_ok(uuid, uuid), private.can_view_shelf(uuid, uuid), private.book_grant_ok(uuid, uuid),
  private.can_view_book(uuid, uuid), private.can_read_book_file(uuid, uuid), private.can_download_book_file(uuid, uuid),
  private.can_view_series(uuid, uuid), private.can_subscribe(public.subscription_target, uuid, uuid)
  to anon, authenticated, service_role;

grant execute on function
  public.handle_available(text), public.create_profile(text, text, text), public.change_handle(text),
  public.delete_my_account(), public.send_friend_request(uuid), public.respond_friend_request(uuid, boolean),
  public.cancel_friend_request(uuid), public.remove_friend(uuid), public.block_user(uuid), public.unblock_user(uuid),
  public.reorder_shelves(uuid[]), public.set_access_password(public.resource_type, uuid, text),
  public.remove_access_password(public.resource_type, uuid), public.revoke_access_grants(public.resource_type, uuid),
  public.has_access_password(public.resource_type, uuid), public.redeem_access_password(public.resource_type, uuid, text)
  to authenticated;
