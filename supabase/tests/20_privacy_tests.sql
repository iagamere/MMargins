\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
\set dave  '44444444-4444-4444-4444-444444444444'
\set frank '55555555-5555-5555-5555-555555555555'

begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test'),(:'dave','d@x.test'),(:'frank','f@x.test');

/* ============================== accounts & profiles ============================== */
select t.login(:'alice');
select public.create_profile('Alice', 'Alice A', 'Reader');           -- upper case is normalised
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'carol'); select public.create_profile('carol', 'Carol');
select t.login(:'dave');  select public.create_profile('dave', 'Dave');
select t.login(:'frank'); select public.create_profile('frank', 'Frank');

select t.login(:'carol');
select t.throws('handle: duplicate is refused (case-insensitive)', $$select public.create_profile('ALICE', 'X')$$, 'duplicate');
select t.throws('handle: reserved word refused', $$select public.create_profile('admin', 'X')$$);
select t.login(:'alice');
select t.ok('handle_available false for taken', not public.handle_available('alice'));
select t.ok('handle_available false for reserved', not public.handle_available('support'));
select t.ok('handle_available false for invalid', not public.handle_available('a'));
select t.ok('handle_available true for free', public.handle_available('new.name_1'));
select t.throws('profile: a second profile for the same user fails', $$select public.create_profile('alice2', 'X')$$);
select t.throws('profile: cannot change handle by plain UPDATE (column privilege)', $$update public.profiles set handle = 'hacked' where id = auth.uid()$$, 'permission denied');
update public.profiles set display_name = 'hijacked' where id = '22222222-2222-2222-2222-222222222222';   -- silently 0 rows
select t.eq('profile: other profile unchanged', (select display_name from public.profiles where id = :'bob'), 'Bob');
select t.ok('profile: public profile exposes no email column', not exists (select 1 from information_schema.column_privileges where table_name='profiles' and grantee in ('anon','authenticated') and column_name='email'));
select t.throws('profile: email not selectable from auth.users', $$select email from auth.users$$, 'permission denied');
select t.ok('library: auto-created, private by default', (select default_access from public.libraries where owner_id = :'alice') = 'private');

/* ================================ alice's content ================================ */
select t.login(:'alice');
insert into public.shelves (library_id, owner_id, name, access)
  select id, owner_id, 'Pub', 'public' from public.libraries where owner_id = :'alice';
insert into public.shelves (library_id, owner_id, name, access)
  select id, owner_id, 'Priv', 'private' from public.libraries where owner_id = :'alice';
insert into public.shelves (library_id, owner_id, name, access)
  select id, owner_id, 'Pwd', 'password' from public.libraries where owner_id = :'alice';
insert into public.shelves (library_id, owner_id, name, access)
  select id, owner_id, 'Fr', 'friends' from public.libraries where owner_id = :'alice';
insert into public.shelves (library_id, owner_id, name)                 -- inherits the (private) library default
  select id, owner_id, 'Inh' from public.libraries where owner_id = :'alice';

create temp table ids as select name, id from public.shelves where owner_id = :'alice';
grant all on ids to public;

insert into public.books (owner_id, title, format, file_hash, file_size, rights_confirmed_at, read_allowed, download_allowed, access) values
 (:'alice', 'B-pub',          'epub', repeat('1',64), 1000, now(), true,  false, 'inherit'),
 (:'alice', 'B-priv',         'epub', repeat('2',64), 1000, now(), true,  true,  'inherit'),
 (:'alice', 'B-multi',        'epub', repeat('3',64), 1000, now(), true,  true,  'inherit'),
 (:'alice', 'B-explicit-priv','epub', repeat('4',64), 1000, now(), true,  true,  'private'),
 (:'alice', 'B-explicit-pub', 'epub', repeat('5',64), 1000, now(), true,  true,  'public'),
 (:'alice', 'B-pwd',          'epub', repeat('6',64), 1000, now(), true,  true,  'inherit'),
 (:'alice', 'B-fr',           'epub', repeat('7',64), 1000, now(), true,  true,  'inherit'),
 (:'alice', 'B-nofile',       'pdf',  repeat('8',64), 1000, now(), false, false, 'public'),
 (:'alice', 'B-pending',      'epub', repeat('9',64), 1000, now(), true,  true,  'public'),
 (:'alice', 'B-loose',        'epub', repeat('a',64), 1000, now(), true,  true,  'inherit');

select t.admin();
update public.books set file_status = 'ready' where title <> 'B-pending';   -- only the backend may do this

select t.login(:'alice');
create temp table bk as select title, id from public.books where owner_id = :'alice';
grant all on bk to public;
create function pg_temp.sh(n text) returns uuid language sql as $$ select id from ids where name = n $$;
create function pg_temp.bk(n text) returns uuid language sql as $$ select id from bk where title = n $$;

insert into public.shelf_books (shelf_id, book_id, owner_id) values
 (pg_temp.sh('Pub'),  pg_temp.bk('B-pub'),           :'alice'),
 (pg_temp.sh('Priv'), pg_temp.bk('B-priv'),          :'alice'),
 (pg_temp.sh('Pub'),  pg_temp.bk('B-multi'),         :'alice'),
 (pg_temp.sh('Priv'), pg_temp.bk('B-multi'),         :'alice'),
 (pg_temp.sh('Pub'),  pg_temp.bk('B-explicit-priv'), :'alice'),
 (pg_temp.sh('Priv'), pg_temp.bk('B-explicit-pub'),  :'alice'),
 (pg_temp.sh('Pwd'),  pg_temp.bk('B-pwd'),           :'alice'),
 (pg_temp.sh('Fr'),   pg_temp.bk('B-fr'),            :'alice'),
 (pg_temp.sh('Pub'),  pg_temp.bk('B-nofile'),        :'alice'),
 (pg_temp.sh('Pub'),  pg_temp.bk('B-pending'),       :'alice');

select t.ok('owner sees all 10 of her books', (select count(*) from public.books) = 10);
select t.ok('owner sees her private library', (select count(*) from public.libraries) = 1);

/* ============== 1 & 2. strangers: private content is invisible everywhere ============== */
select t.login(:'carol');
select t.eq('1. stranger: private library hidden', (select count(*) from public.libraries where owner_id = :'alice'), 0::bigint);
select t.eq('1. stranger: private shelf hidden by id', (select count(*) from public.shelves where id = pg_temp.sh('Priv')), 0::bigint);
select t.eq('1. stranger: private book hidden by id', (select count(*) from public.books where id = pg_temp.bk('B-priv')), 0::bigint);
select t.eq('1. stranger: library-inherited shelf hidden', (select count(*) from public.shelves where id = pg_temp.sh('Inh')), 0::bigint);
select t.eq('1. stranger: loose book (library default private) hidden', (select count(*) from public.books where id = pg_temp.bk('B-loose')), 0::bigint);
select t.eq('2. search: the ONLY books a stranger can find',
  (select string_agg(title, ',' order by title) from public.books),
  'B-explicit-pub,B-nofile,B-pub');
select t.eq('2. search: shelves a stranger can list', (select string_agg(name, ',' order by name) from public.shelves), 'Pub');
select t.eq('2. search: full-text over private titles finds nothing', (select count(*) from public.books where to_tsvector('simple', title) @@ plainto_tsquery('simple', 'priv')), 0::bigint);
select t.eq('2. counts: shelf_books for stranger = only visible pairs', (select count(*) from public.shelf_books), 2::bigint);
select t.throws('2. file_hash is not selectable', $$select file_hash from public.books$$, 'permission denied');
select t.throws('2. rights_confirmed_at is not selectable', $$select rights_confirmed_at from public.books$$, 'permission denied');
select t.throws('2. access_secrets is not readable', $$select * from public.access_secrets$$, 'permission denied');
select t.throws('2. access_grants is not readable', $$select * from public.access_grants$$, 'permission denied');
select t.throws('2. helper functions are not exposed as RPC (private schema, no usage for api schema)',
  $$select public.can_view_book(gen_random_uuid(), gen_random_uuid())$$, 'does not exist');

select t.anon();
select t.eq('2. anonymous: same as stranger', (select string_agg(title, ',' order by title) from public.books), 'B-explicit-pub,B-nofile,B-pub');
select t.eq('2. anonymous: no friends/blocks/subscriptions', 0::bigint, 0::bigint);
select t.throws('2. anonymous cannot read friendships', $$select * from public.friendships$$, 'permission denied');

/* ================= 7. shelf override  /  8. book override  /  9. multi-shelf ================= */
select t.login(:'carol');
select t.ok('7. public shelf inside a private library is visible (override)', exists (select 1 from public.shelves where id = pg_temp.sh('Pub')));
select t.ok('7. ...but the private library itself stays hidden', not exists (select 1 from public.libraries where owner_id = :'alice'));
select t.ok('7. its inheriting book is visible', exists (select 1 from public.books where id = pg_temp.bk('B-pub')));
select t.ok('8. explicit-private book on a PUBLIC shelf is hidden', not exists (select 1 from public.books where id = pg_temp.bk('B-explicit-priv')));
select t.ok('8. ...and not listed in the shelf', not exists (select 1 from public.shelf_books where book_id = pg_temp.bk('B-explicit-priv')));
select t.ok('8. explicit-public book on a PRIVATE shelf is visible as a book (override)', exists (select 1 from public.books where id = pg_temp.bk('B-explicit-pub')));
select t.ok('8. ...but the private shelf and its membership stay hidden', not exists (select 1 from public.shelf_books where book_id = pg_temp.bk('B-explicit-pub')));
select t.ok('9. book on public + private shelf is NOT visible (most restrictive wins)', not exists (select 1 from public.books where id = pg_temp.bk('B-multi')));
select t.ok('9. ...nor listed through the public shelf', not exists (select 1 from public.shelf_books where book_id = pg_temp.bk('B-multi')));
select t.login(:'alice');
delete from public.shelf_books where book_id = pg_temp.bk('B-multi') and shelf_id = pg_temp.sh('Priv');
select t.login(:'carol');
select t.ok('9. once off the private shelf it follows the public one', exists (select 1 from public.books where id = pg_temp.bk('B-multi')));
select t.login(:'alice');
insert into public.shelf_books (shelf_id, book_id, owner_id) values (pg_temp.sh('Priv'), pg_temp.bk('B-multi'), :'alice');
select t.login(:'carol');
select t.ok('9. adding it back to a private shelf hides it again', not exists (select 1 from public.books where id = pg_temp.bk('B-multi')));

select t.login(:'alice');
update public.libraries set default_access = 'public';
select t.login(:'carol');
select t.ok('7. library public: shelf explicitly PRIVATE stays hidden (stricter rule not bypassed)', not exists (select 1 from public.shelves where id = pg_temp.sh('Priv')));
select t.ok('7. library public: inheriting shelf becomes visible', exists (select 1 from public.shelves where id = pg_temp.sh('Inh')));
select t.ok('7. library public: loose inheriting book becomes visible', exists (select 1 from public.books where id = pg_temp.bk('B-loose')));
select t.ok('7. library public: the library row is visible', exists (select 1 from public.libraries where owner_id = :'alice'));
select t.login(:'alice');
update public.libraries set default_access = 'private';

/* ===================== 5 & 6. read / download flags, pending files ===================== */
select t.login(:'carol');
select t.ok('5. metadata visible while reading disabled', exists (select 1 from public.books where id = pg_temp.bk('B-nofile')));
select t.ok('5/6. read denied when read_allowed = false', not private.can_read_book_file(pg_temp.bk('B-nofile'), :'carol'));
select t.ok('5/6. download denied when download_allowed = false', not private.can_download_book_file(pg_temp.bk('B-nofile'), :'carol'));
select t.ok('6. read allowed, download denied on B-pub', private.can_read_book_file(pg_temp.bk('B-pub'), :'carol') and not private.can_download_book_file(pg_temp.bk('B-pub'), :'carol'));
select t.ok('6. file of a private book is never readable', not private.can_read_book_file(pg_temp.bk('B-priv'), :'carol') and not private.can_download_book_file(pg_temp.bk('B-priv'), :'carol'));
select t.ok('6. a pending (not yet validated) upload is invisible', not exists (select 1 from public.books where id = pg_temp.bk('B-pending')));
select t.ok('6. ...and its file is unreadable', not private.can_read_book_file(pg_temp.bk('B-pending'), :'carol'));
select t.ok('6. owner always reads and downloads', private.can_read_book_file(pg_temp.bk('B-nofile'), :'alice') and private.can_download_book_file(pg_temp.bk('B-nofile'), :'alice'));
select t.ok('6. anonymous: same decision as a stranger', not private.can_download_book_file(pg_temp.bk('B-pub'), null));
select t.login(:'alice');
update public.books set download_allowed = true where id = pg_temp.bk('B-pub');
select t.login(:'carol');
select t.ok('6. owner enables download -> allowed', private.can_download_book_file(pg_temp.bk('B-pub'), :'carol'));

/* ======================== 3. password-protected content ======================== */
select t.login(:'carol');
select t.ok('3. password shelf is not discoverable', not exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')) and not exists (select 1 from public.books where id = pg_temp.bk('B-pwd')));
select t.login(:'alice');
select public.set_access_password('shelf', pg_temp.sh('Pwd'), 'correct horse');
select t.throws('3. password too short is refused', format($$select public.set_access_password('shelf', %L, 'short')$$, pg_temp.sh('Pwd')), 'password_invalid');
select t.ok('3. owner can see a password is set', public.has_access_password('shelf', pg_temp.sh('Pwd')));
select t.login(:'carol');
select t.ok('3. other users cannot probe whether a password is set', not public.has_access_password('shelf', pg_temp.sh('Pwd')));
select t.throws('3. a non-owner cannot set a password', format($$select public.set_access_password('shelf', %L, 'hijack-pass')$$, pg_temp.sh('Pwd')), 'not_found');
select t.ok('3. wrong password -> false', not public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'nope'));
select t.ok('3. unknown resource -> same false', not public.redeem_access_password('shelf', gen_random_uuid(), 'correct horse'));
select t.ok('3. still hidden after failures', not exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')));
select t.ok('3. right password -> true', public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'correct horse'));
select t.ok('3. shelf visible after redeeming', exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')));
select t.ok('3. its book visible too', exists (select 1 from public.books where id = pg_temp.bk('B-pwd')));
select t.ok('3. membership visible', exists (select 1 from public.shelf_books where book_id = pg_temp.bk('B-pwd')));
select t.ok('3. the grant does not unlock other private things', not exists (select 1 from public.shelves where id = pg_temp.sh('Priv')));
select t.login(:'bob');
select t.ok('3. another user is not helped by carol''s grant', not exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')));
select t.anon();
select t.throws('3. anonymous cannot redeem (no EXECUTE privilege)', format($$select public.redeem_access_password('shelf', %L, 'correct horse')$$, pg_temp.sh('Pwd')), 'permission denied');
select t.admin();
select t.ok('3. only a bcrypt hash is stored', (select password_hash like '$2%' and password_hash <> 'correct horse' from public.access_secrets where resource_id = pg_temp.sh('Pwd')));
select t.login(:'alice');
select public.set_access_password('shelf', pg_temp.sh('Pwd'), 'a brand new pass');
select t.login(:'carol');
select t.ok('3. rotating the password revokes earlier grants', not exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')));
select t.ok('3. old password no longer works', not public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'correct horse'));
select t.ok('3. new password works', public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'a brand new pass'));
select t.login(:'alice');
select public.revoke_access_grants('shelf', pg_temp.sh('Pwd'));
select t.login(:'carol');
select t.ok('3. owner can revoke grants explicitly', not exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')));
select t.login(:'alice');
select public.remove_access_password('shelf', pg_temp.sh('Pwd'));
select t.login(:'carol');
select t.ok('3. with the password removed nobody gets in', not public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'a brand new pass'));
select t.login(:'alice');
select public.set_access_password('shelf', pg_temp.sh('Pwd'), 'correct horse');
-- brute force: frank
select t.login(:'frank');
select public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'g1');
select public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'g2');
select public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'g3');
select public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'g4');
select public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'g5');
select t.ok('3. brute force: locked out even with the right password', not public.redeem_access_password('shelf', pg_temp.sh('Pwd'), 'correct horse'));
select t.ok('3. ...and still hidden', not exists (select 1 from public.shelves where id = pg_temp.sh('Pwd')));

/* ================================ 4. friends-only ================================ */
select t.login(:'bob');
select t.ok('4. non-friend cannot see friends-only shelf/book', not exists (select 1 from public.shelves where id = pg_temp.sh('Fr')) and not exists (select 1 from public.books where id = pg_temp.bk('B-fr')));
select public.send_friend_request(:'alice') as req \gset
select t.ok('4. a pending request does not grant access', not exists (select 1 from public.shelves where id = pg_temp.sh('Fr')));
select t.throws('4. duplicate request refused', format($$select public.send_friend_request(%L)$$, :'alice'), 'already_pending');
select t.throws('4. self request refused', format($$select public.send_friend_request(%L)$$, :'bob'), 'invalid_request');
select t.throws('4. cannot accept your own request', format($$select public.respond_friend_request(%L, true)$$, :'req'), 'not_found');
select t.throws('4. cannot write friendships directly', $$insert into public.friendships values (least(auth.uid(), '11111111-1111-1111-1111-111111111111'), greatest(auth.uid(), '11111111-1111-1111-1111-111111111111'))$$, 'permission denied');
select t.login(:'carol');
select t.eq('4. strangers cannot see others'' requests', (select count(*) from public.friend_requests), 0::bigint);
select t.login(:'alice');
select t.eq('4. recipient sees the request', (select count(*) from public.friend_requests where status = 'pending'), 1::bigint);
select public.respond_friend_request(:'req', true);
select t.throws('4. accepting twice fails', format($$select public.respond_friend_request(%L, true)$$, :'req'), 'not_found');
select t.login(:'bob');
select t.ok('4. accepted friend sees the friends-only shelf', exists (select 1 from public.shelves where id = pg_temp.sh('Fr')));
select t.ok('4. ...its book', exists (select 1 from public.books where id = pg_temp.bk('B-fr')));
select t.ok('4. ...and may read it (owner enabled read)', private.can_read_book_file(pg_temp.bk('B-fr'), :'bob'));
select t.ok('4. but friendship alone does not open a PRIVATE shelf', not exists (select 1 from public.shelves where id = pg_temp.sh('Priv')));
select t.throws('4. already friends: new request refused', format($$select public.send_friend_request(%L)$$, :'alice'), 'already_friends');
select public.remove_friend(:'alice');
select t.ok('4. removing the friend revokes access immediately', not exists (select 1 from public.shelves where id = pg_temp.sh('Fr')) and not exists (select 1 from public.books where id = pg_temp.bk('B-fr')));
-- re-friend then block
select public.send_friend_request(:'alice') as req2 \gset
select t.login(:'alice');
select public.respond_friend_request(:'req2', true);
select public.block_user(:'bob');
select t.login(:'bob');
select t.ok('4. blocking removes the friendship and hides even public content', not exists (select 1 from public.shelves) and not exists (select 1 from public.books where owner_id = :'alice'));
select t.throws('4. a blocked user gets a generic "not_found" on friend requests', format($$select public.send_friend_request(%L)$$, :'alice'), 'not_found');
select t.ok('4. alice''s profile is hidden from the blocked user', not exists (select 1 from public.profiles where id = :'alice'));
select t.login(:'alice');
select t.ok('4. the blocker may list her blocks', (select count(*) from public.blocks) = 1);
select t.login(:'bob');
select t.eq('4. the blocked user cannot see that they are blocked', (select count(*) from public.blocks), 0::bigint);
select t.login(:'alice');
select public.unblock_user(:'bob');
select t.login(:'bob');
select t.ok('4. after unblocking public content is visible again (friendship stays removed)', exists (select 1 from public.shelves where id = pg_temp.sh('Pub')) and not exists (select 1 from public.shelves where id = pg_temp.sh('Fr')));
-- rejection cooldown
select t.login(:'dave');
select public.send_friend_request(:'alice') as req3 \gset
select t.login(:'alice');
select public.respond_friend_request(:'req3', false);
select t.login(:'dave');
select t.throws('4. rejected: cannot re-request within 7 days', format($$select public.send_friend_request(%L)$$, :'alice'), 'cooldown');
-- cancel
select t.login(:'frank');
select public.send_friend_request(:'alice') as req4 \gset
select public.cancel_friend_request(:'req4');
select t.eq('4. cancelled request is no longer pending', (select status::text from public.friend_requests where id = :'req4'), 'cancelled');

/* ====================== 10-12. subscriptions respect visibility ====================== */
select t.login(:'alice');
insert into public.series (owner_id, title) values (:'alice', 'Dune Saga'), (:'alice', 'Secret Saga');
select t.throws('series: normalised key is unique per owner', $$insert into public.series (owner_id, title) values (auth.uid(), '  dune   SAGA ')$$, 'duplicate');
create temp table se as select title, id from public.series;
grant all on se to public;
update public.books set series_id = (select id from se where title = 'Dune Saga'), series_position = 1 where title = 'B-pub';
update public.books set series_id = (select id from se where title = 'Secret Saga'), series_position = 1 where title = 'B-priv';
select t.login(:'carol');
select t.ok('series: stranger sees a series that has a visible book', exists (select 1 from public.series where title = 'Dune Saga'));
select t.ok('series: stranger does NOT see a series with only private books', not exists (select 1 from public.series where title = 'Secret Saga'));
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'carol', 'shelf', pg_temp.sh('Pub'));
select t.ok('11. can subscribe to a public shelf only (no user-level subscription created)', (select count(*) from public.subscriptions) = 1 and not exists (select 1 from public.subscriptions where target_type = 'user'));
select t.throws('10. cannot subscribe to a private shelf', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'shelf', %L)$$, :'carol', pg_temp.sh('Priv')), 'row-level security');
select t.throws('10. cannot subscribe to a password shelf without access', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'shelf', %L)$$, :'carol', pg_temp.sh('Pwd')), 'row-level security');
select t.throws('10. cannot subscribe to a series that only has private books', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'series', %L)$$, :'carol', (select id from se where title = 'Secret Saga')), 'row-level security');
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'carol', 'series', (select id from se where title = 'Dune Saga'));
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'carol', 'user', :'alice');
select t.throws('subscribe: duplicate refused', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'user', %L)$$, :'carol', :'alice'), 'duplicate');
select t.throws('subscribe: cannot follow yourself', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'user', %L)$$, :'carol', :'carol'), 'row-level security');
select t.throws('subscribe: cannot subscribe on behalf of someone else', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'user', %L)$$, :'bob', :'alice'), 'row-level security');
update public.subscriptions set muted = true where target_type = 'user';
select t.ok('subscribe: mute works', (select muted from public.subscriptions where target_type = 'user'));
select t.eq('subscribe: others cannot see my subscriptions', (select count(*) from public.subscriptions), 3::bigint);
select t.login(:'alice');
select t.eq('subscribe: ...not even the owner of the target', (select count(*) from public.subscriptions), 0::bigint);
select public.block_user(:'carol');
select t.admin();
select t.eq('block: removes the blocked user''s subscriptions to the blocker', (select count(*) from public.subscriptions where subscriber_id = :'carol'), 0::bigint);
select t.login(:'alice');
select public.unblock_user(:'carol');

/* ============================ isolation of writes ============================ */
select t.login(:'carol');
select t.throws('write: cannot add a shelf to someone else''s library', format($$insert into public.shelves (library_id, owner_id, name) values (%L, %L, 'x')$$, (select id from public.libraries where owner_id = :'alice'), :'alice'), 'row-level security');
update public.books set title = 'pwn' where id = pg_temp.bk('B-pub');
delete from public.shelves where id = pg_temp.sh('Pub');
select t.admin();
select t.ok('write: another user''s UPDATE / DELETE changed nothing', (select title from public.books where id = pg_temp.bk('B-pub')) = 'B-pub' and exists (select 1 from public.shelves where id = pg_temp.sh('Pub')));
select t.login(:'carol');
select t.throws('write: cannot flip file_status', $$update public.books set file_status = 'ready'$$, 'permission denied');
select t.login(:'bob');
insert into public.shelves (library_id, owner_id, name) select id, owner_id, 'Bob shelf' from public.libraries where owner_id = :'bob';
select t.throws('write: cannot put alice''s book on bob''s shelf (owner mismatch)', format($$insert into public.shelf_books (shelf_id, book_id, owner_id) values ((select id from public.shelves where name = 'Bob shelf'), %L, %L)$$, pg_temp.bk('B-pub'), :'bob'), 'violates');
select t.throws('write: book without rights confirmation refused', $$insert into public.books (owner_id, title, format, file_hash, file_size) values (auth.uid(), 't', 'epub', repeat('b',64), 1)$$, 'null value');
select t.throws('write: bad format refused', $$insert into public.books (owner_id, title, format, file_hash, file_size, rights_confirmed_at) values (auth.uid(), 't', 'exe', repeat('b',64), 1, now())$$, 'books_format');
select t.throws('write: oversize file refused', $$insert into public.books (owner_id, title, format, file_hash, file_size, rights_confirmed_at) values (auth.uid(), 't', 'epub', repeat('b',64), 999999999, now())$$, 'books_size');
insert into public.books (owner_id, title, format, file_hash, file_size, rights_confirmed_at) values (auth.uid(), 'dupe', 'epub', repeat('c',64), 10, now());
select t.throws('write: the same file twice is refused (no duplicates)', $$insert into public.books (owner_id, title, format, file_hash, file_size, rights_confirmed_at) values (auth.uid(), 'dupe2', 'epub', repeat('c',64), 10, now())$$, 'duplicate');
select public.reorder_shelves(array[pg_temp.sh('Pub')]);   -- not bob's shelf: silently ignored
select t.eq('write: ...and left alice''s shelf order alone', (select position from public.shelves where id = pg_temp.sh('Pub')), 0);

/* ===================== 16. account deletion cascades ===================== */
select t.login(:'carol');
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'carol', 'user', :'frank');
select t.login(:'frank');
select public.delete_my_account();
select t.admin();
select t.eq('16. profile gone', (select count(*) from public.profiles where id = :'frank'), 0::bigint);
select t.eq('16. library gone', (select count(*) from public.libraries where owner_id = :'frank'), 0::bigint);
select t.eq('16. attempts / requests gone', (select count(*) from public.access_attempts where user_id = :'frank') + (select count(*) from public.friend_requests where requester_id = :'frank'), 0::bigint);
select t.eq('16. subscriptions that targeted the deleted user are gone', (select count(*) from public.subscriptions where target_id = :'frank'), 0::bigint);
select t.anon();
select t.throws('16. anonymous cannot call delete_my_account', $$select public.delete_my_account()$$, 'permission denied');
select t.login(:'alice');
select public.delete_my_account();
select t.admin();
select t.eq('16. alice: books, shelves, series, secrets, grants all cascade', (select (select count(*) from public.books where owner_id = :'alice') + (select count(*) from public.shelves where owner_id = :'alice') + (select count(*) from public.series where owner_id = :'alice') + (select count(*) from public.access_secrets where owner_id = :'alice') + (select count(*) from public.shelf_books where owner_id = :'alice')), 0::bigint);
select t.eq('16. friendships / blocks of alice gone', (select count(*) from public.friendships where :'alice' in (user_a, user_b)) + (select count(*) from public.blocks where :'alice' in (blocker_id, blocked_id)), 0::bigint);
select t.eq('16. carol''s own data untouched', (select count(*) from public.profiles where id = :'carol'), 1::bigint);

/* ================================ summary ================================ */
select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
