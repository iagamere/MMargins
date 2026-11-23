\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
\set dave  '44444444-4444-4444-4444-444444444444'
\set eve   '55555555-5555-4555-8555-555555555555'
\set gina  '77777777-7777-4777-8777-777777777777'
\set b1 'aaaaaaaa-3000-4000-8000-000000000001'
\set b2 'aaaaaaaa-3000-4000-8000-000000000002'
\set b3 'aaaaaaaa-3000-4000-8000-000000000003'
\set b4 'aaaaaaaa-3000-4000-8000-000000000004'
\set b5 'aaaaaaaa-3000-4000-8000-000000000005'
\set s1 'cccccccc-3000-4000-8000-000000000001'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test'),(:'dave','d@x.test'),(:'eve','e@x.test'),(:'gina','g@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'carol'); select public.create_profile('carol', 'Carol');
select t.login(:'dave');  select public.create_profile('dave', 'Dave');
select t.login(:'eve');   select public.create_profile('eve', 'Eve');
-- gina: an auth account without a profile
select t.admin();
create function t.n(u uuid) returns text language plpgsql as $$
begin
  perform t.login(u);
  return coalesce((select string_agg(type::text || ':' || coalesce(actor_handle, '-') || ':' || (read_at is not null)::text, ',' order by created_at desc, id) from public.my_notifications(100, 0)), '');
end $$;
create function t.types(u uuid) returns text language plpgsql as $$
begin
  perform t.login(u);
  return coalesce((select string_agg(distinct type::text, ',') from public.my_notifications(100, 0)), '');
end $$;
grant execute on function t.n(uuid), t.types(uuid) to public;

/* ---------- friend requests ---------- */
select t.login(:'bob'); select public.send_friend_request(:'alice');
select t.eq('N1 the recipient is told about the request, with who sent it', t.n(:'alice'), 'friend_request:bob:false');
select t.eq('N1 the sender is told nothing', t.n(:'bob'), '');
select t.eq('N1 unread count is 1', (select public.unread_notification_count()), 1) where t.login(:'alice') is not null;
select t.login(:'alice');
select public.respond_friend_request((select id from public.friend_requests where requester_id = :'bob'), true);
select t.eq('N2 once answered, the stale request notice is gone', t.n(:'alice'), '');
select t.eq('N2 the sender is told it was accepted, and by whom', t.n(:'bob'), 'friend_accepted:alice:false');
select t.login(:'carol'); select public.send_friend_request(:'alice');
select t.login(:'alice'); select public.respond_friend_request((select id from public.friend_requests where requester_id = :'carol'), false);
select t.eq('N3 a declined request leaves no notice for the recipient', t.n(:'alice'), '');
select t.eq('N3 ...and tells the sender nothing', t.n(:'carol'), '');
select t.login(:'dave'); select public.send_friend_request(:'alice');
select t.eq('N4 a new request shows up', t.n(:'alice'), 'friend_request:dave:false');
select t.login(:'dave'); select public.cancel_friend_request((select id from public.friend_requests where requester_id = :'dave'));
select t.eq('N4 a cancelled request takes its notice with it', t.n(:'alice'), '');

/* ---------- read / delete are strictly mine ---------- */
select t.login(:'dave'); select public.send_friend_request(:'alice');
select t.login(:'eve');   select public.send_friend_request(:'alice');
select t.login(:'alice');
select t.eq('N5 two unread', (select public.unread_notification_count()), 2);
select public.mark_notifications_read(array[(select id from public.my_notifications(100,0) where actor_handle = 'dave')]);
select t.eq('N5 marking one read lowers the count', (select public.unread_notification_count()), 1);
select t.login(:'bob');
select public.mark_notifications_read();
select public.delete_notifications();
select t.login(:'alice');
select t.eq('N5 another user marking all read / deleting all does not touch mine', (select public.unread_notification_count()), 1);
select t.eq('N5 ...nor does it remove them', (select count(*) from public.my_notifications(100, 0)), 2::bigint);
select public.mark_notifications_read();
select t.eq('N5 mark all read', (select public.unread_notification_count()), 0);
select public.delete_notifications(array[(select id from public.my_notifications(100,0) where actor_handle = 'eve')]);
select t.eq('N5 delete one', (select count(*) from public.my_notifications(100, 0)), 1::bigint);
select public.delete_notifications();
select t.eq('N5 delete all', (select count(*) from public.my_notifications(100, 0)), 0::bigint);
select t.login(:'dave'); select public.cancel_friend_request((select id from public.friend_requests where requester_id = :'dave' and status = 'pending'));
select t.login(:'eve');  select public.cancel_friend_request((select id from public.friend_requests where requester_id = :'eve' and status = 'pending'));

/* ---------- preferences ---------- */
select t.login(:'alice');
select t.eq('P1 default: everything on', (select friend_requests::text || new_books::text from public.my_notification_prefs()), 'truetrue');
select public.set_notification_prefs(false, true, true);
select t.eq('P1 saved', (select friend_requests::text || friend_accepted::text from public.my_notification_prefs()), 'falsetrue');
select t.login(:'dave'); select public.send_friend_request(:'alice');
select t.eq('P2 a muted category creates no notice', t.n(:'alice'), '');
select t.login(:'dave'); select public.cancel_friend_request((select id from public.friend_requests where requester_id = :'dave' and status = 'pending'));
select t.login(:'bob');
select t.eq('P3 preferences are per person', (select friend_requests::text from public.my_notification_prefs()), 'true');
select t.login(:'gina');
select t.throws('P4 no profile -> cannot set preferences', 'select public.set_notification_prefs(true, true, true)', 'profile_required');
select t.eq('P4 ...but reading gives the defaults', (select friend_requests::text from public.my_notification_prefs()), 'true');
select t.login(:'alice'); select public.set_notification_prefs(true, true, true);

/* ---------- blocks hide what the other person caused ---------- */
select t.login(:'alice'); select public.remove_friend(:'bob');
select t.login(:'bob');   select public.send_friend_request(:'alice');
select t.login(:'alice'); select public.respond_friend_request((select id from public.friend_requests where requester_id = :'bob' and status = 'pending'), true);
select t.eq('B1 bob has the "accepted" notice from alice', t.types(:'bob'), 'friend_accepted');
select t.login(:'bob'); select public.block_user(:'alice');
select t.eq('B1 after bob blocks alice it disappears from his inbox', t.types(:'bob'), '');
select t.eq('B1 ...and from his unread count', (select public.unread_notification_count()), 0) where t.login(:'bob') is not null;
select t.login(:'bob'); select public.unblock_user(:'alice');

/* ---------- new books reach followers who can SEE them ---------- */
select t.admin();
select id as alib from public.libraries where owner_id = :'alice' \gset
insert into public.books (id, owner_id, title, format, file_hash, file_size, file_status, access, rights_confirmed_at) values
  (:'b1', :'alice', 'Public Book',  'epub', repeat('1',64), 10, 'pending', 'public',  now()),
  (:'b2', :'alice', 'Private Book', 'epub', repeat('2',64), 10, 'pending', 'private', now()),
  (:'b3', :'alice', 'Friends Book', 'epub', repeat('3',64), 10, 'pending', 'friends', now()),
  (:'b4', :'alice', 'Later Public',  'epub', repeat('4',64), 10, 'pending', 'private', now()),
  (:'b5', :'alice', 'Shelf Book',   'epub', repeat('5',64), 10, 'ready',   'public',  now());
insert into public.subscriptions (subscriber_id, target_type, target_id) values
  (:'bob', 'library', :'alib'), (:'bob', 'user', :'alice'),     -- bob follows the same owner twice
  (:'carol', 'user', :'alice'),                                 -- carol will mute
  (:'dave', 'library', :'alib');                                -- dave is a friend of nobody: sees public only
update public.subscriptions set muted = true where subscriber_id = :'carol';
select t.admin();
update public.books set file_status = 'ready' where id = :'b1';
select t.login(:'bob');
select t.eq('F1 a follower is told about a newly published public book (once, though he follows twice)', (select count(*) from public.my_notifications(100, 0) where type = 'new_book' and actor_handle = 'alice'), 1::bigint);
select t.eq('F1 the notice names the book', (select resource_title from public.my_notifications(10, 0) where type = 'new_book') , 'Public Book') where t.login(:'bob') is not null;
select t.eq('F1 another follower too', t.types(:'dave'), 'new_book');
select t.eq('F1 a MUTED follow is silent', t.types(:'carol'), '');
select t.eq('F1 the owner is not told about her own book', t.types(:'alice'), '');
select t.admin();
update public.books set file_status = 'ready' where id in (:'b2', :'b3');
select t.eq('F2 a private book tells nobody', (select count(*) from public.notifications where resource_id = :'b2'), 0::bigint);
select t.eq('F2 a friends-only book tells followers who are not friends nothing', (select count(*) from public.notifications where resource_id = :'b3'), 0::bigint);
update public.books set file_status = 'ready' where id = :'b4';
update public.books set access = 'public' where id = :'b4';
select t.eq('F3 a book that BECOMES public later tells followers then', (select count(*) from public.notifications where resource_id = :'b4' and user_id = :'bob'), 1::bigint);
select t.eq('F3 a pending file never does', (select count(*) from public.notifications where type = 'new_book' and resource_id not in (:'b1', :'b4')), 0::bigint);
insert into public.shelves (id, library_id, owner_id, name, access) values (:'s1', :'alib', :'alice', 'Shelf', 'public');
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'eve', 'shelf', :'s1');
insert into public.shelf_books (shelf_id, book_id, owner_id) values (:'s1', :'b5', :'alice');
select t.eq('F4 following a SHELF: adding a visible book to it notifies', (select count(*) from public.notifications where user_id = :'eve' and resource_id = :'b5'), 1::bigint);
select t.eq('F4 ...and the library followers hear about that book too, once', (select count(*) from public.notifications where user_id = :'bob' and resource_id = :'b5'), 1::bigint);
update public.books set access = 'private' where id = :'b1';
select t.ok('F5 the title is hidden once the book is no longer visible to the reader',
  (select resource_title is null from public.my_notifications(10, 0) where resource_id = :'b1') ) where t.login(:'bob') is not null;
select t.admin();
update public.notification_prefs set new_books = false where user_id = :'bob';
insert into public.notification_prefs (user_id, new_books) values (:'bob', false) on conflict (user_id) do update set new_books = false;
insert into public.books (id, owner_id, title, format, file_hash, file_size, file_status, access, rights_confirmed_at)
  values ('aaaaaaaa-3000-4000-8000-0000000000f1', :'alice', 'Another', 'epub', repeat('f',64), 10, 'pending', 'public', now());
update public.books set file_status = 'ready' where id = 'aaaaaaaa-3000-4000-8000-0000000000f1';
select t.eq('F6 a person who turned "new books" off gets none', (select count(*) from public.notifications where user_id = :'bob' and resource_id = 'aaaaaaaa-3000-4000-8000-0000000000f1'), 0::bigint);
select t.eq('F6 the others still do', (select count(*) from public.notifications where user_id = :'dave' and resource_id = 'aaaaaaaa-3000-4000-8000-0000000000f1'), 1::bigint);

/* ---------- cap ---------- */
select private.notify(:'eve', 'friend_request', null, 'request', gen_random_uuid()) from generate_series(1, 230);
select t.eq('C1 an inbox keeps at most the newest 200', (select count(*) from public.notifications where user_id = :'eve'), 200::bigint);

/* ---------- the tables are closed ---------- */
select t.login(:'alice');
select t.throws('X1 clients cannot read the table', 'select * from public.notifications', 'permission denied');
select t.throws('X1 ...nor write it', $$insert into public.notifications (user_id, type) values ('11111111-1111-1111-1111-111111111111', 'new_book')$$, 'permission denied');
select t.throws('X1 ...nor the preferences table', 'select * from public.notification_prefs', 'permission denied');
select t.throws('X1 ...nor call the private writer', $$select private.notify('11111111-1111-1111-1111-111111111111', 'new_book', null, 'book', gen_random_uuid())$$, 'permission denied');
select t.anon();
select t.throws('X2 anonymous cannot read an inbox', 'select * from public.my_notifications()', 'permission denied');
select t.throws('X2 ...nor count', 'select public.unread_notification_count()', 'permission denied');
select t.throws('X2 ...nor set preferences', 'select public.set_notification_prefs(true,true,true)', 'permission denied');
select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
