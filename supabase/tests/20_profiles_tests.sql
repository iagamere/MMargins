\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test');

/* the old (0001-0008) world is gone */
select t.ok('R1 old tables are gone', to_regclass('public.friendships') is null and to_regclass('public.books') is null and to_regclass('public.libraries') is null
  and to_regclass('public.access_secrets') is null and to_regclass('public.blocks') is null and to_regclass('public.notifications') is null);
select t.ok('R1 old functions are gone', to_regprocedure('public.send_friend_request(uuid)') is null and to_regprocedure('public.visit_library(text)') is null);
select t.ok('R1 old privacy types are gone', to_regtype('public.access_mode') is null and to_regtype('public.resource_type') is null);

/* creating a profile */
select t.login(:'alice');
select public.create_profile('  Alice  ', '  Alice A  ', 'hello');
select t.eq('P1 handle is lower-cased and trimmed', (select handle from public.profiles where id = :'alice'), 'alice');
select t.eq('P1 display name is trimmed', (select display_name from public.profiles where id = :'alice'), 'Alice A');
select t.login(:'bob');
select public.create_profile('bob', 'Bob');
select t.throws('P2 duplicate handle refused', $$select public.create_profile('alice', 'Another')$$, 'duplicate');
select t.login(:'carol');
select t.throws('P2 too short', $$select public.create_profile('ab', 'C')$$, 'profiles_handle_format');
select t.throws('P2 double dot', $$select public.create_profile('a..b', 'C')$$, 'profiles_handle_format');
select t.throws('P2 uppercase / space garbage', $$select public.create_profile('bad handle', 'C')$$, 'profiles_handle_format');
select t.throws('P2 reserved handle', $$select public.create_profile('admin', 'C')$$, 'handle_reserved');
select t.throws('P2 empty display name', $$select public.create_profile('carol', '   ')$$, 'profiles_display_name_len');
select t.throws('P2 bio too long', format($$select public.create_profile('carol', 'C', %L)$$, repeat('x', 301)), 'profiles_bio_len');
select t.ok('P2 handle_available false for taken, reserved, invalid; true for free',
  not public.handle_available('alice') and not public.handle_available('admin') and not public.handle_available('x') and public.handle_available('carol'));
select t.anon();
select t.throws('P2 anonymous cannot create a profile', $$select public.create_profile('zed', 'Z')$$, 'permission denied');
select t.throws('P2 anonymous cannot ask handle_available', $$select public.handle_available('zed')$$, 'permission denied');

/* reading */
select t.ok('P3 anonymous can read public profile fields', (select count(*) from public.profiles) = 2);
select t.throws('P3 handle_changed_at is not readable', $$select handle_changed_at from public.profiles$$, 'permission denied');
select t.login(:'bob');
select t.ok('P3 signed-in users read profiles too', (select count(*) from public.profiles) = 2);

/* writing */
update public.profiles set display_name = 'Hacked' where id = :'alice';
select t.admin();
select t.eq('P4 nobody edits another profile', (select display_name from public.profiles where id = :'alice'), 'Alice A');
select t.login(:'alice');
update public.profiles set bio = 'new bio', avatar_v = 3, cover_v = 2 where id = :'alice';
select t.ok('P4 owner edits bio and picture versions', (select bio = 'new bio' and avatar_v = 3 and cover_v = 2 from public.profiles where id = :'alice'));
select t.throws('P4 handle cannot be changed directly', $$update public.profiles set handle = 'other' where id = '11111111-1111-1111-1111-111111111111'$$, 'permission denied');
select t.throws('P4 id cannot be changed directly', $$update public.profiles set id = gen_random_uuid() where id = '11111111-1111-1111-1111-111111111111'$$, 'permission denied');
select t.throws('P4 negative picture version refused', $$update public.profiles set avatar_v = -1 where id = '11111111-1111-1111-1111-111111111111'$$, 'profiles_versions');
select t.throws('P4 profile cannot be deleted by the client', $$delete from public.profiles where id = '11111111-1111-1111-1111-111111111111'$$, 'permission denied');

/* handle change: allowed, then a 30-day cool-down */
select public.change_handle('alice2');
select t.eq('P5 handle changed', (select handle from public.profiles where id = :'alice'), 'alice2');
select t.throws('P5 second change inside 30 days refused', $$select public.change_handle('alice3')$$, 'handle_cooldown');
select t.login(:'bob');
select t.throws('P5 taking someone else''s handle refused', $$select public.change_handle('alice2')$$, 'duplicate');

/* account deletion removes everything of the user */
select t.login(:'bob');
insert into public.shelves (owner_id, title) values (:'bob', 'Bob shelf');
select public.delete_my_account();
select t.admin();
select t.ok('P6 profile and shelves are gone with the account', not exists (select 1 from public.profiles where id = :'bob') and not exists (select 1 from public.shelves where owner_id = :'bob'));
select t.ok('P6 other users are untouched', exists (select 1 from public.profiles where id = :'alice'));
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
