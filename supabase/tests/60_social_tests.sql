\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
\set dave  '44444444-4444-4444-4444-444444444444'
\set eve   '55555555-5555-4555-8555-555555555555'
\set frank '66666666-6666-4666-8666-666666666666'
\set gina  '77777777-7777-4777-8777-777777777777'
\set s_open 'cccccccc-2000-4000-8000-000000000001'
\set s_priv 'cccccccc-2000-4000-8000-000000000002'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test'),(:'dave','d@x.test'),(:'eve','e@x.test'),(:'frank','f@x.test'),(:'gina','g@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'carol'); select public.create_profile('carol', 'Carol');
select t.login(:'dave');  select public.create_profile('dave', 'Dave');
select t.login(:'eve');   select public.create_profile('eve', 'Eve');
select t.login(:'frank'); select public.create_profile('frank', 'Frank');
-- gina has an auth account and NO profile

-- alice <-> bob friends; carol -> alice pending; alice -> dave pending; frank -> alice rejected; eve -> alice then alice blocks eve
select t.login(:'bob');   select public.send_friend_request(:'alice');
select t.login(:'alice'); select public.respond_friend_request((select id from public.friend_requests where requester_id = :'bob'), true);
select t.login(:'carol'); select public.send_friend_request(:'alice');
select t.login(:'alice'); select public.send_friend_request(:'dave');
select t.login(:'frank'); select public.send_friend_request(:'alice');
select t.login(:'alice'); select public.respond_friend_request((select id from public.friend_requests where requester_id = :'frank'), false);
select t.login(:'eve');   select public.send_friend_request(:'alice');
select t.login(:'alice'); select public.block_user(:'eve');
select t.admin();
\o

/* ---------- relationships ---------- */
select t.login(:'alice');
select t.eq('R1 friends = bob', public.my_relationships() #>> '{friends,0,handle}', 'bob');
select t.eq('R1 exactly one friend', jsonb_array_length(public.my_relationships()->'friends'), 1);
select t.eq('R1 incoming = carol only (rejected frank and cancelled eve do not show)', (select string_agg(x->>'handle', ',') from jsonb_array_elements(public.my_relationships()->'incoming') x), 'carol');
select t.eq('R1 outgoing = dave', (select string_agg(x->>'handle', ',') from jsonb_array_elements(public.my_relationships()->'outgoing') x), 'dave');
select t.eq('R1 blocked = eve', (select string_agg(x->>'handle', ',') from jsonb_array_elements(public.my_relationships()->'blocked') x), 'eve');
select t.eq('R1 an incoming entry carries the request id', (public.my_relationships() #>> '{incoming,0,request_id}') = (select id::text from public.friend_requests where requester_id = :'carol'), true);
select t.eq('R2 the table alone could NOT list the blocked user (that is why the function exists)', (select count(*) from public.profiles where handle = 'eve'), 0::bigint);
select t.eq('R2 ...but the blocker gets name and handle from the function', public.my_relationships() #>> '{blocked,0,display_name}', 'Eve');
select t.eq('R3 an entry exposes only id, handle, display_name, bio, since',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(public.my_relationships() #> '{friends,0}') k), 'bio,display_name,handle,id,since');

select t.login(:'bob');
select t.eq('R4 bob sees alice as friend', public.my_relationships() #>> '{friends,0,handle}', 'alice');
select t.eq('R4 ...and nothing else (no one else''s requests / blocks)', jsonb_array_length(public.my_relationships()->'incoming') + jsonb_array_length(public.my_relationships()->'outgoing') + jsonb_array_length(public.my_relationships()->'blocked'), 0);
select t.login(:'carol');
select t.eq('R4 carol has an outgoing request to alice and no friends', (public.my_relationships() #>> '{outgoing,0,handle}') || '/' || jsonb_array_length(public.my_relationships()->'friends'), 'alice/0');
select t.login(:'dave');
select t.eq('R4 dave has alice''s request incoming', public.my_relationships() #>> '{incoming,0,handle}', 'alice');

select t.login(:'eve');
select t.eq('R5 the blocked user sees nothing of the blocker (no pending request, no friend, no block)',
  jsonb_array_length(public.my_relationships()->'friends') + jsonb_array_length(public.my_relationships()->'incoming') + jsonb_array_length(public.my_relationships()->'outgoing') + jsonb_array_length(public.my_relationships()->'blocked'), 0);
select t.login(:'frank');
select t.eq('R5 a rejected requester has no open request', jsonb_array_length(public.my_relationships()->'outgoing'), 0);
select t.login(:'gina');
select t.eq('R6 a user without a profile gets empty lists, not an error', public.my_relationships() = '{"friends": [], "blocked": [], "incoming": [], "outgoing": []}'::jsonb, true);
select t.anon();
select t.throws('R7 anonymous cannot call my_relationships', 'select public.my_relationships()', 'permission denied');

select t.login(:'alice');
select public.remove_friend(:'bob');
select t.eq('R8 after remove_friend the list is empty', jsonb_array_length(public.my_relationships()->'friends'), 0);
select public.unblock_user(:'eve');
select t.eq('R8 after unblock the list is empty', jsonb_array_length(public.my_relationships()->'blocked'), 0);

/* ---------- subscriptions ---------- */
select t.admin();
select id as alib from public.libraries where owner_id = :'alice' \gset
update public.libraries set default_access = 'public', title = 'Alice Books' where id = :'alib';
insert into public.shelves (id, library_id, owner_id, name, access) values (:'s_open', :'alib', :'alice', 'Open Shelf', 'public'), (:'s_priv', :'alib', :'alice', 'Secret Shelf', 'private');
select t.login(:'bob');
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'bob', 'library', :'alib');
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'bob', 'shelf', :'s_open');
insert into public.subscriptions (subscriber_id, target_type, target_id) values (:'bob', 'user', :'alice');
select t.admin();
update public.subscriptions set created_at = now() - interval '3 hours' where subscriber_id = :'bob' and target_type = 'library';
update public.subscriptions set created_at = now() - interval '2 hours' where subscriber_id = :'bob' and target_type = 'shelf';
update public.subscriptions set created_at = now() - interval '1 hour'  where subscriber_id = :'bob' and target_type = 'user';
select t.login(:'bob');
select t.throws('S0 a private shelf cannot be followed (the write rule still holds)', format($$insert into public.subscriptions (subscriber_id, target_type, target_id) values (%L, 'shelf', %L)$$, :'bob', :'s_priv'), 'row-level security');
select t.eq('S1 three rows, newest first', (select string_agg(target_type::text, ',') from public.my_subscriptions()), 'user,shelf,library');
select t.eq('S1 names are resolved', (select string_agg(coalesce(target_name, '-'), ',') from public.my_subscriptions()), 'Alice,Open Shelf,Alice Books');
select t.eq('S1 owner handle is returned and all are available', (select string_agg(owner_handle || available::text, ',') from public.my_subscriptions()), 'alicetrue,alicetrue,alicetrue');
update public.subscriptions set muted = true where subscriber_id = :'bob' and target_type = 'shelf';
select t.eq('S2 the muted flag comes through', (select muted from public.my_subscriptions() where target_type = 'shelf'), true);

-- the owner closes things: old subscriptions must not leak titles
select t.login(:'alice');
update public.libraries set default_access = 'private' where id = :'alib';
update public.shelves set access = 'private' where id = :'s_open';
select t.login(:'bob');
select t.eq('S3 a library that became private: still listed, but unavailable', (select available from public.my_subscriptions() where target_type = 'library'), false);
select t.ok('S3 ...and its title is NOT returned', (select target_name is null from public.my_subscriptions() where target_type = 'library'));
select t.ok('S3 ...nor the shelf name', (select target_name is null and available = false from public.my_subscriptions() where target_type = 'shelf'));
select t.eq('S3 the user subscription is unaffected', (select target_name || available::text from public.my_subscriptions() where target_type = 'user'), 'Alicetrue');

select t.login(:'carol');
select t.eq('S4 another user sees none of bob''s subscriptions', (select count(*) from public.my_subscriptions()), 0::bigint);
select t.login(:'alice');
select t.eq('S4 neither does the owner', (select count(*) from public.my_subscriptions()), 0::bigint);
select t.anon();
select t.throws('S5 anonymous cannot call my_subscriptions', 'select * from public.my_subscriptions()', 'permission denied');

select t.login(:'alice'); select public.block_user(:'bob');
select t.login(:'bob');
select t.eq('S6 blocking ends the subscriptions', (select count(*) from public.my_subscriptions()), 0::bigint);

select t.ok('S7 anon has no execute right on either function',
  not has_function_privilege('anon', 'public.my_relationships()', 'execute') and not has_function_privilege('anon', 'public.my_subscriptions()', 'execute'));
select t.ok('S7 authenticated has', has_function_privilege('authenticated', 'public.my_relationships()', 'execute') and has_function_privilege('authenticated', 'public.my_subscriptions()', 'execute'));

select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
