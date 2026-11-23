/* =====================================================================================
   Stage 4: friends, blocks and subscriptions: what the screens need to READ.
   The write side already exists and is tested (send/respond/cancel_friend_request, remove_friend, block_user,
   unblock_user, and INSERT/UPDATE/DELETE on subscriptions under RLS).
   Two problems the tables alone cannot solve:
   1. profiles_read hides a user from someone who blocked them (and the reverse), so the blocker could not even
      list WHO she blocked. my_relationships() returns the blocker's own list.
   2. A subscription row says only "library <uuid>". my_subscriptions() resolves it to names, and returns the
      target's name ONLY while the viewer may still see it (can_subscribe), so a library that became private
      does not leak its title through an old subscription.
   Both answer the signed-in caller only (about herself). No table or column privilege changes.
   ===================================================================================== */

create function public.my_relationships() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return jsonb_build_object(
    'friends', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'bio', p.bio, 'since', f.created_at)
                                order by f.created_at desc), '[]'::jsonb)
      from (select * from public.friendships where uid in (user_a, user_b) order by created_at desc limit 500) f
      join public.profiles p on p.id = case when f.user_a = uid then f.user_b else f.user_a end
      where not private.is_blocked_between(p.id, uid)),
    'incoming', (
      select coalesce(jsonb_agg(jsonb_build_object('request_id', r.id, 'id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'bio', p.bio, 'since', r.created_at)
                                order by r.created_at desc), '[]'::jsonb)
      from (select * from public.friend_requests where recipient_id = uid and status = 'pending' order by created_at desc limit 200) r
      join public.profiles p on p.id = r.requester_id
      where not private.is_blocked_between(p.id, uid)),
    'outgoing', (
      select coalesce(jsonb_agg(jsonb_build_object('request_id', r.id, 'id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'bio', p.bio, 'since', r.created_at)
                                order by r.created_at desc), '[]'::jsonb)
      from (select * from public.friend_requests where requester_id = uid and status = 'pending' order by created_at desc limit 200) r
      join public.profiles p on p.id = r.recipient_id
      where not private.is_blocked_between(p.id, uid)),
    'blocked', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'bio', p.bio, 'since', b.created_at)
                                order by b.created_at desc), '[]'::jsonb)
      from (select * from public.blocks where blocker_id = uid order by created_at desc limit 500) b
      join public.profiles p on p.id = b.blocked_id)
  );
end $$;

create function public.my_subscriptions() returns table (
  id uuid, target_type public.subscription_target, target_id uuid, muted boolean, created_at timestamptz,
  available boolean, target_name text, owner_handle text, owner_name text
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  return query
  select s.id, s.target_type, s.target_id, s.muted, s.created_at, a.ok,
         case when a.ok then
           case s.target_type
             when 'user' then p.display_name
             when 'library' then (select l.title from public.libraries l where l.id = s.target_id)
             when 'shelf' then (select h.name from public.shelves h where h.id = s.target_id)
             when 'series' then (select r.title from public.series r where r.id = s.target_id)
           end
         end,
         p.handle, p.display_name
  from (select * from public.subscriptions where subscriber_id = uid order by created_at desc, id limit 1000) s
  cross join lateral (select private.can_subscribe(s.target_type, s.target_id, uid) as ok) a
  left join public.profiles p on p.id = private.target_owner(s.target_type, s.target_id)
  where p.id is null or not private.is_blocked_between(p.id, uid)
  order by s.created_at desc, s.id;
end $$;

revoke all on function public.my_relationships(), public.my_subscriptions() from public, anon, authenticated;
grant execute on function public.my_relationships(), public.my_subscriptions() to authenticated;
