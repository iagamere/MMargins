\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
\set dave  '44444444-4444-4444-4444-444444444444'
\set eve   '55555555-5555-4555-8555-555555555555'
\set bpub  'aaaaaaaa-0000-4000-8000-000000000001'
\set bdl   'aaaaaaaa-0000-4000-8000-000000000002'
\set bnone 'aaaaaaaa-0000-4000-8000-000000000003'
\set bpriv 'aaaaaaaa-0000-4000-8000-000000000004'
\set bpw   'aaaaaaaa-0000-4000-8000-000000000005'
\set bfr   'aaaaaaaa-0000-4000-8000-000000000006'
\set bpend 'aaaaaaaa-0000-4000-8000-000000000007'
\set bbob  'bbbbbbbb-0000-4000-8000-000000000008'
\set sopen 'cccccccc-0000-4000-8000-000000000001'
\set spriv 'cccccccc-0000-4000-8000-000000000002'
\set spw   'cccccccc-0000-4000-8000-000000000003'
\set sinh  'cccccccc-0000-4000-8000-000000000004'
\set snopw 'cccccccc-0000-4000-8000-000000000005'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test'),(:'dave','d@x.test'),(:'eve','e@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'dave');  select public.create_profile('dave', 'Dave');
select t.login(:'eve');   select public.create_profile('eve', 'Eve');
-- carol has an auth account but NO profile
select t.admin();
select id as alib from public.libraries where owner_id = :'alice' \gset
insert into public.friendships (user_a, user_b) values (least(:'alice'::uuid, :'dave'::uuid), greatest(:'alice'::uuid, :'dave'::uuid));
insert into public.blocks (blocker_id, blocked_id) values (:'alice', :'eve');
insert into public.books (id, owner_id, title, format, file_hash, file_size, file_status, access, read_allowed, download_allowed, has_cover, rights_confirmed_at) values
  (:'bpub',  :'alice', 'Pub',  'epub', repeat('1',64), 100, 'ready',   'public',   true,  false, true,  now()),
  (:'bdl',   :'alice', 'Dl',   'pdf',  repeat('2',64), 100, 'ready',   'public',   false, true,  false, now()),
  (:'bnone', :'alice', 'None', 'epub', repeat('3',64), 100, 'ready',   'public',   false, false, false, now()),
  (:'bpriv', :'alice', 'Priv', 'epub', repeat('4',64), 100, 'ready',   'private',  true,  true,  true,  now()),
  (:'bpw',   :'alice', 'Pw',   'epub', repeat('5',64), 100, 'ready',   'password', true,  true,  false, now()),
  (:'bfr',   :'alice', 'Fr',   'epub', repeat('6',64), 100, 'ready',   'friends',  true,  true,  false, now()),
  (:'bpend', :'alice', 'Pend', 'epub', repeat('7',64), 100, 'pending', 'public',   true,  true,  false, now()),
  (:'bbob',  :'bob',   'Bob',  'epub', repeat('8',64), 100, 'ready',   'private',  true,  true,  false, now());
insert into storage.objects (bucket_id, name, metadata)
select 'books', :'alice' || '/' || b.id || '.' || b.format, '{"size": 100}' from public.books b where b.owner_id = :'alice';
insert into storage.objects (bucket_id, name, metadata) values
  ('covers', :'alice' || '/' || :'bpub' || '.jpg', '{"size": 10}'),
  ('covers', :'alice' || '/' || :'bpriv' || '.jpg', '{"size": 10}'),
  ('books', :'bob' || '/' || :'bpub' || '.epub', '{"size": 100}');   -- forged: bob's folder, alice's book id
select t.login(:'alice');
select public.set_access_password('book', :'bpw', 'book-secret-1');
select t.admin();
create function t.can_get(u uuid, bucket text, nm text) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform case when u is null then t.anon() else t.login(u) end;
  select exists (select 1 from storage.objects where bucket_id = bucket and name = nm) into r;
  perform t.admin();
  return r;
end $$;
grant execute on function t.can_get(uuid, text, text) to public;

/* ---------------------------------------------------------- V1 files: read / download switches */
select t.ok('V1 visitor may fetch a book with read_allowed', t.can_get(:'bob', 'books', :'alice' || '/' || :'bpub' || '.epub'));
select t.ok('V1 visitor may fetch a book with download_allowed only', t.can_get(:'bob', 'books', :'alice' || '/' || :'bdl' || '.pdf'));
select t.ok('V1 neither read nor download allowed -> refused', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bnone' || '.epub'));
select t.ok('V1 private book -> refused even with both switches on', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bpriv' || '.epub'));
select t.ok('V1 friends-only book -> refused to a stranger', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bfr' || '.epub'));
select t.ok('V1 friends-only book -> allowed to a friend', t.can_get(:'dave', 'books', :'alice' || '/' || :'bfr' || '.epub'));
select t.ok('V1 a book that is not ready is refused', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bpend' || '.epub'));
select t.ok('V1 anonymous cannot fetch any file (even a public one)', not t.can_get(null, 'books', :'alice' || '/' || :'bpub' || '.epub'));
select t.ok('V1 a blocked user is refused even for a public book', not t.can_get(:'eve', 'books', :'alice' || '/' || :'bpub' || '.epub'));
select t.ok('V1 the owner still reads her own files', t.can_get(:'alice', 'books', :'alice' || '/' || :'bpriv' || '.epub'));
select t.ok('V1 wrong extension for the format -> refused', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bpub' || '.pdf'));
select t.ok('V1 a visitor never sees the OTHER user''s private book', not t.can_get(:'alice', 'books', :'bob' || '/' || :'bbob' || '.epub'));

/* ------------------------------------------------------------------------------ V2 covers */
select t.ok('V2 cover of a visible book with a cover', t.can_get(:'bob', 'covers', :'alice' || '/' || :'bpub' || '.jpg'));
select t.ok('V2 cover of a private book is hidden', not t.can_get(:'bob', 'covers', :'alice' || '/' || :'bpriv' || '.jpg'));
select t.ok('V2 blocked user does not get the cover', not t.can_get(:'eve', 'covers', :'alice' || '/' || :'bpub' || '.jpg'));

/* ------------------------------------------------------------------- V3 forged paths */
select t.ok('V3 a forged folder (visitor id + someone else''s book id) is refused', not t.can_get(:'bob', 'books', :'bob' || '/' || :'bpub' || '.epub'));

/* ------------------------------------------------------------ V4 password-protected book */
select t.ok('V4 locked book file is refused before the password', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bpw' || '.epub'));
select t.login(:'bob');
select t.eq('V4 wrong password is refused', public.redeem_access_password('book', :'bpw', 'nope-nope-1'), false);
select t.ok('V4 ...and still locked', (select count(*) from public.books where id = :'bpw') = 0);
select t.eq('V4 right password is accepted', public.redeem_access_password('book', :'bpw', 'book-secret-1'), true);
select t.admin();
select t.ok('V4 file is now readable', t.can_get(:'bob', 'books', :'alice' || '/' || :'bpw' || '.epub'));
select t.login(:'alice'); select public.set_access_password('book', :'bpw', 'book-secret-2');
select t.admin();
select t.ok('V4 changing the password revokes the access to the file', not t.can_get(:'bob', 'books', :'alice' || '/' || :'bpw' || '.epub'));
select t.login(:'alice'); select public.set_access_password('book', :'bpw', 'book-secret-1'); select t.admin();

/* -------------------------------------------------------------- V5 visitors cannot write */
select t.login(:'bob');
update storage.objects set metadata = '{"size": 1}' where name = :'alice' || '/' || :'bpub' || '.epub';
delete from storage.objects where name = :'alice' || '/' || :'bpub' || '.epub';
select t.admin();
select t.eq('V5 neither overwrite nor delete changes the file', (select metadata ->> 'size' from storage.objects where name = :'alice' || '/' || :'bpub' || '.epub'), '100');

/* ---------------------------------------------------------------- V6 visit_library */
select t.login(:'bob');
select t.throws('V6 unknown handle -> not_found', $$select public.visit_library('nobody.here')$$, 'not_found');
select t.throws('V6 empty handle -> not_found', $$select public.visit_library('')$$, 'not_found');
select t.login(:'eve');
select t.throws('V6 a blocked visitor gets not_found (same as unknown)', $$select public.visit_library('alice')$$, 'not_found');
select t.login(:'alice');
select t.eq('V6 the owner sees her library open', public.visit_library('alice') #>> '{library,state}', 'open');
select t.login(:'bob');
select t.eq('V6 a private library is unavailable', public.visit_library('alice') #>> '{library,state}', 'unavailable');
select t.ok('V6 ...and says nothing else about it', not (public.visit_library('alice') -> 'library' ? 'title'));
select t.eq('V6 handle lookup is case- and space-insensitive', public.visit_library('  ALICE ') #>> '{profile,handle}', 'alice');
select t.ok('V6 the profile never exposes an e-mail or extra field', (select count(*) from jsonb_object_keys(public.visit_library('alice') -> 'profile')) = 4);

select t.login(:'alice');
update public.libraries set default_access = 'public' where owner_id = :'alice';
update public.libraries set title = 'Alice Lib', description = 'desc' where owner_id = :'alice';
select t.admin();
insert into public.shelves (id, library_id, owner_id, name, access, position) values
  (:'sopen', :'alib', :'alice', 'Open shelf', 'public', 1),
  (:'spriv', :'alib', :'alice', 'Secret shelf name', 'private', 2),
  (:'spw',   :'alib', :'alice', 'Hidden pw shelf name', 'password', 3),
  (:'snopw', :'alib', :'alice', 'Pw shelf w/o secret', 'password', 4);
select t.login(:'alice');
select public.set_access_password('shelf', :'spw', 'shelf-secret-1');
select t.login(:'bob');
select t.eq('V6 public library is open', public.visit_library('alice') #>> '{library,state}', 'open');
select t.eq('V6 ...with its title', public.visit_library('alice') #>> '{library,title}', 'Alice Lib');
select t.ok('V6 an open shelf is listed with its name', public.visit_library('alice') -> 'shelves' @> '[{"id": "cccccccc-0000-4000-8000-000000000001", "name": "Open shelf", "state": "open"}]'::jsonb);
select t.ok('V6 a private shelf is not listed at all', not (public.visit_library('alice')::text like '%cccccccc-0000-4000-8000-000000000002%'));
select t.ok('V6 its name does not leak anywhere', not (public.visit_library('alice')::text like '%Secret shelf name%'));
select t.ok('V6 a password shelf is listed as locked, id only', public.visit_library('alice') -> 'shelves' @> '[{"id": "cccccccc-0000-4000-8000-000000000003", "state": "locked"}]'::jsonb);
select t.ok('V6 ...and its name does not leak', not (public.visit_library('alice')::text like '%Hidden pw shelf name%'));
select t.ok('V6 a password shelf with no password set is not listed (cannot be unlocked)', not (public.visit_library('alice')::text like '%cccccccc-0000-4000-8000-000000000005%'));
select t.ok('V6 own-password book is listed as locked (id only)', public.visit_library('alice') -> 'locked_books' @> '[{"id": "aaaaaaaa-0000-4000-8000-000000000005"}]'::jsonb);
select t.ok('V6 ...but its title is not in the result', not (public.visit_library('alice')::text like '%Pw%'));
select t.ok('V6 a not-ready book is never listed', not (public.visit_library('alice')::text like '%aaaaaaaa-0000-4000-8000-000000000007%'));
select t.ok('V6 books of a public library: the table read still hides private ones', (select count(*) from public.books where owner_id = :'alice' and id = :'bpriv') = 0);
select t.eq('V6 unlocking the shelf', public.redeem_access_password('shelf', :'spw', 'shelf-secret-1'), true);
select t.ok('V6 after unlocking, the shelf shows its name', public.visit_library('alice') -> 'shelves' @> '[{"id": "cccccccc-0000-4000-8000-000000000003", "name": "Hidden pw shelf name", "state": "open"}]'::jsonb);
select t.eq('V6 unlocking the book', public.redeem_access_password('book', :'bpw', 'book-secret-1'), true);
select t.ok('V6 the unlocked book leaves the locked list', not (public.visit_library('alice') -> 'locked_books' @> '[{"id": "aaaaaaaa-0000-4000-8000-000000000005"}]'::jsonb));

select t.anon();
select t.eq('V6 anonymous can open a public library', public.visit_library('alice') #>> '{library,state}', 'open');
select t.ok('V6 anonymous sees the shelf as locked', public.visit_library('alice') -> 'shelves' @> '[{"id": "cccccccc-0000-4000-8000-000000000003", "state": "locked"}]'::jsonb);

/* password library */
select t.login(:'alice');
update public.libraries set default_access = 'password' where owner_id = :'alice';
select t.admin();
insert into public.shelves (id, library_id, owner_id, name, access, position) values (:'sinh', :'alib', :'alice', 'Inherits', 'inherit', 5);
select t.login(:'dave');
select t.eq('V6 password library without a password set -> unavailable', public.visit_library('alice') #>> '{library,state}', 'unavailable');
select t.login(:'alice');
select public.set_access_password('library', :'alib', 'lib-secret-1');
select t.login(:'dave');
select t.eq('V6 password library -> locked', public.visit_library('alice') #>> '{library,state}', 'locked');
select t.ok('V6 ...no title while locked', not (public.visit_library('alice') -> 'library' ? 'title'));
select t.ok('V6 ...a shelf that only inherits the lock is not listed', not (public.visit_library('alice')::text like '%cccccccc-0000-4000-8000-000000000004%'));
select t.eq('V6 wrong library password', public.redeem_access_password('library', :'alib', 'xxxxxxxx'), false);
select t.eq('V6 right library password', public.redeem_access_password('library', :'alib', 'lib-secret-1'), true);
select t.eq('V6 -> open', public.visit_library('alice') #>> '{library,state}', 'open');
select t.ok('V6 ...and the inheriting shelf is visible now', public.visit_library('alice') -> 'shelves' @> '[{"id": "cccccccc-0000-4000-8000-000000000004", "state": "open"}]'::jsonb);
select t.anon();
select t.throws('V6 anonymous cannot call redeem', format($$select public.redeem_access_password('library', %L, 'lib-secret-1')$$, :'alib'), 'permission denied');
select t.eq('V6 anonymous sees a password library as locked', public.visit_library('alice') #>> '{library,state}', 'locked');

/* friends-only library */
select t.login(:'alice');
update public.libraries set default_access = 'friends' where owner_id = :'alice';
select t.login(:'bob');
select t.eq('V6 friends-only library -> unavailable to a stranger', public.visit_library('alice') #>> '{library,state}', 'unavailable');
select t.login(:'dave');
select t.eq('V6 ...open to a friend', public.visit_library('alice') #>> '{library,state}', 'open');

/* a user without a profile */
select t.login(:'carol');
select t.throws('V7 a user with no profile cannot get a grant (profile needed)', format($$select public.redeem_access_password('shelf', %L, 'shelf-secret-1')$$, :'spw'), 'violates foreign key');
select t.login(:'alice');
update public.libraries set default_access = 'public' where owner_id = :'alice';
select t.login(:'carol');
select t.eq('V7 ...but can still visit a public library', public.visit_library('alice') #>> '{library,state}', 'open');

select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
