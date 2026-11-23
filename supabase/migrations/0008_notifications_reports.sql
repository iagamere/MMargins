/* =====================================================================================
   Stage 5: in-app notifications (+ preferences) and reports / takedown.
   NO push: notifications are rows the app reads when it is opened. Push needs Firebase and is not set up.

   Design rules
   - New tables are closed to the API (RLS on, all privileges revoked): everything goes through the RPCs below,
     each of which answers about the CALLER only.
   - A notification is created by database triggers (a client can never write one), only for events the
     recipient may know about: a blocked pair gets nothing, preferences are honoured, a new-book notice is sent
     only to a follower who can actually see that book right now and has not muted the follow.
   - Moderators are rows in `moderators`, added by SQL only (see docs). A moderator sees the METADATA of reported
     items (title, owner, reason); the app never gives a moderator file access.
   - Takedown of a book = it is forced private with read/download off, flagged `removed_at`, its file hash is put
     on a blocklist (so the same file cannot simply be uploaded again), and the owner is told. Enforcement reuses the
     existing visibility rules, so nothing else had to change. A client update cannot undo it (trigger below);
     only a moderator's `restore_book` can.
   ===================================================================================== */

create type public.notification_type as enum ('friend_request', 'friend_accepted', 'new_book', 'content_removed', 'content_restored', 'report_resolved');
create type public.report_target as enum ('book', 'library', 'shelf', 'profile');
create type public.report_reason as enum ('copyright', 'illegal', 'abuse', 'spam', 'other');
create type public.report_status as enum ('open', 'dismissed', 'actioned');

/* ------------------------------------------------------------------ tables */
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  type public.notification_type not null,
  actor_id uuid references public.profiles (id) on delete cascade,
  resource_type text check (resource_type in ('request', 'book', 'report')),
  resource_id uuid,
  detail text check (char_length(detail) <= 40),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index notifications_inbox on public.notifications (user_id, created_at desc);
-- one "new book" notice per person per book, however many follows (library, shelf, person) matched
create unique index notifications_one_new_book on public.notifications (user_id, resource_id) where type = 'new_book';

create table public.notification_prefs (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  friend_requests boolean not null default true,
  friend_accepted boolean not null default true,
  new_books boolean not null default true,
  updated_at timestamptz not null default now()
);

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

alter table public.books add column removed_at timestamptz, add column removed_reason public.report_reason;
-- (the column-level SELECT grant of 0003 does not include the new columns: clients cannot read them)

alter table public.notifications enable row level security;
alter table public.notification_prefs enable row level security;
alter table public.reports enable row level security;
alter table public.moderators enable row level security;
revoke all on public.notifications, public.notification_prefs, public.reports, public.moderators from public, anon, authenticated;

/* ------------------------------------------------------------------ helpers */
create function private.is_moderator(u uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select u is not null and exists (select 1 from public.moderators where user_id = u)
$$;

/* the single door through which a notification is written */
create function private.notify(p_user uuid, p_type public.notification_type, p_actor uuid, p_rtype text, p_rid uuid, p_detail text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_user is null or p_user = p_actor then return; end if;
  if p_actor is not null and private.is_blocked_between(p_user, p_actor) then return; end if;
  if exists (select 1 from public.notification_prefs q where q.user_id = p_user and (
       (p_type = 'friend_request' and not q.friend_requests)
    or (p_type = 'friend_accepted' and not q.friend_accepted)
    or (p_type = 'new_book' and not q.new_books))) then
    return;
  end if;
  insert into public.notifications (user_id, type, actor_id, resource_type, resource_id, detail)
  values (p_user, p_type, p_actor, p_rtype, p_rid, p_detail)
  on conflict do nothing;
  -- keep only the newest 200 per person
  delete from public.notifications where id in (
    select id from public.notifications where user_id = p_user order by created_at desc, id offset 200);
end $$;

/* tell the followers who can see this book right now (and did not mute) */
create function private.notify_book_followers(p_book uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.books; r record;
begin
  select * into b from public.books where id = p_book;
  if not found or b.file_status <> 'ready' or b.removed_at is not null then return; end if;
  for r in
    select distinct s.subscriber_id from public.subscriptions s
    where not s.muted and (
         (s.target_type = 'user' and s.target_id = b.owner_id)
      or (s.target_type = 'library' and s.target_id in (select l.id from public.libraries l where l.owner_id = b.owner_id))
      or (s.target_type = 'shelf' and s.target_id in (select sb.shelf_id from public.shelf_books sb where sb.book_id = b.id)))
  loop
    if private.can_view_book(b.id, r.subscriber_id) then
      perform private.notify(r.subscriber_id, 'new_book', b.owner_id, 'book', b.id);
    end if;
  end loop;
end $$;

/* ------------------------------------------------------------------ triggers: who gets told what */
create function private.trg_request_created() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'pending' then
    perform private.notify(new.recipient_id, 'friend_request', new.requester_id, 'request', new.id);
  end if;
  return null;
end $$;
create trigger friend_requests_notify after insert on public.friend_requests for each row execute function private.trg_request_created();

create function private.trg_request_answered() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.status = 'pending' and new.status <> 'pending' then
    -- the request is settled: its notice to the recipient is stale
    delete from public.notifications where type = 'friend_request' and resource_id = new.id;
    if new.status = 'accepted' then
      perform private.notify(new.requester_id, 'friend_accepted', new.recipient_id, 'request', new.id);
    end if;
  end if;
  return null;
end $$;
create trigger friend_requests_answered after update of status on public.friend_requests for each row execute function private.trg_request_answered();

create function private.trg_book_visible() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.file_status = 'ready' and (old.file_status <> 'ready' or old.access is distinct from new.access) then
    perform private.notify_book_followers(new.id);
  end if;
  return null;
end $$;
create trigger books_notify after update of file_status, access on public.books for each row execute function private.trg_book_visible();

create function private.trg_shelf_book_added() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.notify_book_followers(new.book_id);
  return null;
end $$;
create trigger shelf_books_notify after insert on public.shelf_books for each row execute function private.trg_shelf_book_added();

/* ------------------------------------------------------------------ takedown enforcement */
/* a client (anon / authenticated) can not loosen a removed book; moderators' own functions run as their owner and may */
create function private.keep_removed_private() returns trigger language plpgsql as $$
begin
  if old.removed_at is not null and current_user in ('authenticated', 'anon') then
    new.access := 'private'; new.read_allowed := false; new.download_allowed := false;
    new.removed_at := old.removed_at; new.removed_reason := old.removed_reason;
  end if;
  return new;
end $$;
create trigger books_keep_removed before update on public.books for each row execute function private.keep_removed_private();

/* the same file cannot be added again after a takedown */
create function private.refuse_removed_hash() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from private.removed_hashes where file_hash = new.file_hash) then
    raise exception 'content_removed' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger books_refuse_removed before insert on public.books for each row execute function private.refuse_removed_hash();

/* ------------------------------------------------------------------ RPCs: notifications */
create function public.my_notifications(p_limit integer default 50, p_offset integer default 0)
returns table (id uuid, type public.notification_type, created_at timestamptz, read_at timestamptz, actor_handle text, actor_name text,
               resource_type text, resource_id uuid, resource_title text, detail text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return query
  select n.id, n.type, n.created_at, n.read_at, p.handle, p.display_name, n.resource_type, n.resource_id,
         case when n.resource_type = 'book' and private.can_view_book(n.resource_id, uid)
              then (select b.title from public.books b where b.id = n.resource_id) end,
         n.detail
  from public.notifications n
  left join public.profiles p on p.id = n.actor_id
  where n.user_id = uid and not (n.actor_id is not null and private.is_blocked_between(n.actor_id, uid))
  order by n.created_at desc, n.id
  limit least(greatest(coalesce(p_limit, 50), 1), 100) offset least(greatest(coalesce(p_offset, 0), 0), 1000);
end $$;

create function public.unread_notification_count() returns integer
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return (select count(*)::integer from public.notifications n
          where n.user_id = uid and n.read_at is null and not (n.actor_id is not null and private.is_blocked_between(n.actor_id, uid)));
end $$;

create function public.mark_notifications_read(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  update public.notifications set read_at = now() where user_id = uid and read_at is null and (p_ids is null or id = any(p_ids));
end $$;

create function public.delete_notifications(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.notifications where user_id = uid and (p_ids is null or id = any(p_ids));
end $$;

create function public.my_notification_prefs() returns table (friend_requests boolean, friend_accepted boolean, new_books boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return query select coalesce(q.friend_requests, true), coalesce(q.friend_accepted, true), coalesce(q.new_books, true)
               from (select 1) x left join public.notification_prefs q on q.user_id = uid;
end $$;

create function public.set_notification_prefs(p_friend_requests boolean, p_friend_accepted boolean, p_new_books boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'profile_required' using errcode = 'P0001'; end if;
  insert into public.notification_prefs (user_id, friend_requests, friend_accepted, new_books)
  values (uid, coalesce(p_friend_requests, true), coalesce(p_friend_accepted, true), coalesce(p_new_books, true))
  on conflict (user_id) do update set friend_requests = excluded.friend_requests, friend_accepted = excluded.friend_accepted,
    new_books = excluded.new_books, updated_at = now();
end $$;

/* ------------------------------------------------------------------ RPCs: reports */
create function public.report_content(p_type public.report_target, p_id uuid, p_reason public.report_reason, p_details text default '')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); v_owner uuid; rid uuid;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then raise exception 'profile_required' using errcode = 'P0001'; end if;
  -- the reporter must be able to see what they report (so a report cannot be used to probe hidden things)
  if p_type = 'book' then
    if not private.can_view_book(p_id, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
    select b.owner_id into v_owner from public.books b where b.id = p_id;
  elsif p_type = 'library' then
    if not private.can_view_library(p_id, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
    select l.owner_id into v_owner from public.libraries l where l.id = p_id;
  elsif p_type = 'shelf' then
    if not private.can_view_shelf(p_id, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
    select h.owner_id into v_owner from public.shelves h where h.id = p_id;
  else
    select p.id into v_owner from public.profiles p where p.id = p_id;
    if v_owner is null or private.is_blocked_between(v_owner, uid) then raise exception 'not_found' using errcode = 'P0001'; end if;
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

/* the owner of removed books can see what was removed and why (the columns themselves are not readable) */
create function public.my_removed_books() returns table (book_id uuid, title text, reason public.report_reason, removed_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return query select b.id, b.title, b.removed_reason, b.removed_at from public.books b
               where b.owner_id = uid and b.removed_at is not null order by b.removed_at desc;
end $$;

/* ------------------------------------------------------------------ RPCs: moderation */
create function public.am_i_moderator() returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return private.is_moderator(auth.uid());
end $$;

create function public.moderation_queue(p_status text default 'open', p_limit integer default 30, p_offset integer default 0)
returns table (id uuid, target_type public.report_target, target_id uuid, reason public.report_reason, details text, status public.report_status,
               created_at timestamptz, handled_at timestamptz, resolution text, note text, reporter_handle text,
               target_title text, owner_handle text, owner_name text, book_removed boolean, open_reports bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_moderator(uid) then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
  select r.id, r.target_type, r.target_id, r.reason, r.details, r.status, r.created_at, r.handled_at, r.resolution, r.note, rp.handle,
         case r.target_type
           when 'book' then (select b.title from public.books b where b.id = r.target_id)
           when 'library' then (select l.title from public.libraries l where l.id = r.target_id)
           when 'shelf' then (select h.name from public.shelves h where h.id = r.target_id)
           else (select p.display_name from public.profiles p where p.id = r.target_id) end,
         op.handle, op.display_name,
         coalesce(r.target_type = 'book' and (select b.removed_at is not null from public.books b where b.id = r.target_id), false),
         (select count(*) from public.reports o where o.target_type = r.target_type and o.target_id = r.target_id and o.status = 'open')
  from public.reports r
  join public.profiles rp on rp.id = r.reporter_id
  left join public.profiles op on op.id = case r.target_type
      when 'book' then (select b.owner_id from public.books b where b.id = r.target_id)
      when 'library' then (select l.owner_id from public.libraries l where l.id = r.target_id)
      when 'shelf' then (select h.owner_id from public.shelves h where h.id = r.target_id)
      else r.target_id end
  where case when p_status = 'open' then r.status = 'open' else r.status <> 'open' end
  order by case when p_status = 'open' then r.created_at end asc, r.handled_at desc nulls last, r.id
  limit least(greatest(coalesce(p_limit, 30), 1), 100) offset least(greatest(coalesce(p_offset, 0), 0), 2000);
end $$;

create function public.resolve_report(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); r public.reports; b public.books; v_note text := left(btrim(coalesce(p_note, '')), 1000); x record;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_moderator(uid) then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_action not in ('dismiss', 'takedown', 'noted') then raise exception 'invalid_request' using errcode = 'P0001'; end if;
  select * into r from public.reports where id = p_id and status = 'open' for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;

  if p_action = 'takedown' then
    if r.target_type <> 'book' then raise exception 'invalid_request' using errcode = 'P0001'; end if;
    select * into b from public.books where id = r.target_id for update;
    if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
    update public.books set removed_at = now(), removed_reason = r.reason, access = 'private', read_allowed = false, download_allowed = false
      where id = b.id;
    insert into private.removed_hashes (file_hash) values (b.file_hash) on conflict do nothing;
    -- the owner is told even if they muted everything else
    insert into public.notifications (user_id, type, resource_type, resource_id, detail) values (b.owner_id, 'content_removed', 'book', b.id, r.reason::text);
    -- every open report about this same book is settled together
    for x in select * from public.reports where target_type = 'book' and target_id = b.id and status = 'open' for update loop
      update public.reports set status = 'actioned', resolution = 'removed', handled_by = uid, handled_at = now(), note = v_note where id = x.id;
      perform private.notify(x.reporter_id, 'report_resolved', null, 'report', x.id, 'removed');
    end loop;
  else
    update public.reports set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end::public.report_status,
           resolution = case when p_action = 'dismiss' then 'dismissed' else 'noted' end,
           handled_by = uid, handled_at = now(), note = v_note where id = r.id;
    perform private.notify(r.reporter_id, 'report_resolved', null, 'report', r.id, case when p_action = 'dismiss' then 'dismissed' else 'noted' end);
  end if;
end $$;

create function public.restore_book(p_book uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); b public.books;
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_moderator(uid) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into b from public.books where id = p_book and removed_at is not null for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  update public.books set removed_at = null, removed_reason = null where id = b.id;   -- stays private: the owner decides again
  delete from private.removed_hashes where file_hash = b.file_hash;
  insert into public.notifications (user_id, type, resource_type, resource_id) values (b.owner_id, 'content_restored', 'book', b.id);
end $$;

/* ------------------------------------------------------------------ privileges */
revoke all on function private.is_moderator(uuid), private.notify(uuid, public.notification_type, uuid, text, uuid, text), private.notify_book_followers(uuid)
  from public, anon, authenticated;
revoke all on function
  public.my_notifications(integer, integer), public.unread_notification_count(), public.mark_notifications_read(uuid[]), public.delete_notifications(uuid[]),
  public.my_notification_prefs(), public.set_notification_prefs(boolean, boolean, boolean),
  public.report_content(public.report_target, uuid, public.report_reason, text), public.my_removed_books(),
  public.am_i_moderator(), public.moderation_queue(text, integer, integer), public.resolve_report(uuid, text, text), public.restore_book(uuid)
  from public, anon, authenticated;
grant execute on function
  public.my_notifications(integer, integer), public.unread_notification_count(), public.mark_notifications_read(uuid[]), public.delete_notifications(uuid[]),
  public.my_notification_prefs(), public.set_notification_prefs(boolean, boolean, boolean),
  public.report_content(public.report_target, uuid, public.report_reason, text), public.my_removed_books(),
  public.am_i_moderator(), public.moderation_queue(text, integer, integer), public.resolve_report(uuid, text, text), public.restore_book(uuid)
  to authenticated;
