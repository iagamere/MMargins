\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set dave  '44444444-4444-4444-4444-444444444444'
\set eve   '55555555-5555-4555-8555-555555555555'
\set zed   '66666666-6666-4666-8666-666666666666'
\set b1 'aaaaaaaa-1000-4000-8000-000000000001'
\set b2 'aaaaaaaa-1000-4000-8000-000000000002'
\set b3 'aaaaaaaa-1000-4000-8000-000000000003'
\set b4 'aaaaaaaa-1000-4000-8000-000000000004'
\set b5 'aaaaaaaa-1000-4000-8000-000000000005'
\set b6 'aaaaaaaa-1000-4000-8000-000000000006'
\set b7 'aaaaaaaa-1000-4000-8000-000000000007'
\set b8 'aaaaaaaa-1000-4000-8000-000000000008'
\set e1 'eeeeeeee-1000-4000-8000-000000000001'
\set bb 'bbbbbbbb-1000-4000-8000-000000000001'
\set s_pub 'cccccccc-1000-4000-8000-000000000001'
\set s_priv 'cccccccc-1000-4000-8000-000000000002'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'dave','d@x.test'),(:'eve','e@x.test'),(:'zed','z@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice Reader');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'dave');  select public.create_profile('dave', 'Dave');
select t.login(:'eve');   select public.create_profile('eve', 'Eve');
select t.login(:'zed');  select public.create_profile('zed', 'Zed');
select t.admin();
select id as alib from public.libraries where owner_id = :'alice' \gset
select id as blib from public.libraries where owner_id = :'bob' \gset
insert into public.friendships (user_a, user_b) values (least(:'alice'::uuid, :'dave'::uuid), greatest(:'alice'::uuid, :'dave'::uuid));
insert into public.books (id, owner_id, title, author, format, file_hash, file_size, file_status, access, rights_confirmed_at, created_at) values
  (:'b1', :'alice', 'Dune Saga',            'Frank Herbert', 'epub', repeat('1',64), 100, 'ready',   'public',   now(), now() - interval '5 hours'),
  (:'b2', :'alice', 'الأيام',                'طه حسين',        'epub', repeat('2',64), 100, 'ready',   'public',   now(), now() - interval '4 hours'),
  (:'b3', :'alice', 'Pending Public',       '',              'epub', repeat('3',64), 100, 'pending', 'public',   now(), now() - interval '3 hours'),
  (:'b4', :'alice', 'Private One',          '',              'epub', repeat('4',64), 100, 'ready',   'private',  now(), now() - interval '2 hours'),
  (:'b5', :'alice', 'Password One',         '',              'epub', repeat('5',64), 100, 'ready',   'password', now(), now() - interval '2 hours'),
  (:'b6', :'alice', 'Friends One',          '',              'epub', repeat('6',64), 100, 'ready',   'friends',  now(), now() - interval '2 hours'),
  (:'b7', :'alice', '100% Pure_Fun',        '',              'epub', repeat('7',64), 100, 'ready',   'public',   now(), now() - interval '1 hour'),
  (:'b8', :'alice', 'Inherits Library',     '',              'epub', repeat('8',64), 100, 'ready',   'inherit',  now(), now() - interval '30 minutes'),
  (:'bb', :'bob',   'Bob Public Book',      '',              'pdf',  repeat('9',64), 100, 'ready',   'public',   now(), now() - interval '10 minutes'),
  (:'e1', :'eve',   'Eve Public Book',      '',              'epub', repeat('a',64), 100, 'ready',   'public',   now(), now() - interval '20 minutes');
select t.login(:'alice');
select public.set_access_password('book', :'b5', 'book-secret-1');
select t.admin();

create function t.ids(q text, lim int default 30, off int default 0) returns text language sql as $$
  select coalesce(string_agg(right(id::text, 2) || '', ',' order by ord), '') from (
    select id, row_number() over () as ord from public.discover_books(q, lim, off)) x
$$;
create function t.libs(q text) returns text language sql as $$
  select coalesce(string_agg(handle || ':' || book_count, ',' order by handle), '') from public.discover_libraries(q, 30, 0)
$$;
grant execute on function t.ids(text, int, int), t.libs(text) to public;

/* ---------- books: only what a signed-out stranger could already read ---------- */
select t.anon();
-- newest first: bb(10m) b7(1h) b2(4h) b1(5h); eve's e1 is public too (20m) -> bb, e1, b7, b2, b1  (ids end 01,01,07,02,01)
select t.eq('D1 anonymous sees exactly the public, ready books, newest first', t.ids(''), '01,01,07,02,01');
select t.eq('D1 no query / null query behave the same', t.ids(null), '01,01,07,02,01');
select t.eq('D2 pending / private / password / friends / inheriting-private-library books never appear',
  (select count(*)::text from public.discover_books('', 60, 0) where id in (:'b3',:'b4',:'b5',:'b6',:'b8')), '0');
select t.login(:'dave');
select t.eq('D2 a FRIEND still gets public books only (discovery is public-only)',
  (select count(*)::text from public.discover_books('', 60, 0) where id in (:'b3',:'b4',:'b5',:'b6',:'b8')), '0');
select t.login(:'zed');
select t.eq('D2 a signed-in stranger can browse', t.ids(''), '01,01,07,02,01');
-- a password grant does not make a book discoverable either
select t.admin();
insert into public.access_grants (user_id, resource_type, resource_id, version, expires_at)
  select :'dave', 'book', :'b5', s.version, now() + interval '1 day' from public.access_secrets s where s.resource_type = 'book' and s.resource_id = :'b5';
select t.login(:'dave');
select t.eq('D2 even with a live password grant the book is not listed', (select count(*)::text from public.discover_books('', 60, 0) where id = :'b5'), '0');
select t.anon();

/* ---------- search ---------- */
select t.eq('D3 title word, case-insensitive', t.ids('DUNE'), '01');
select t.eq('D3 substring of a word', t.ids('agaa'), '');
select t.eq('D3 substring inside a word matches', t.ids('aga'), '01');
select t.eq('D3 author', t.ids('herbert'), '01');
select t.eq('D3 all words must match (AND)', t.ids('dune herbert'), '01');
select t.eq('D3 one word missing -> no result', t.ids('dune tolkien'), '');
select t.eq('D3 Arabic title', t.ids('الأيام'), '02');
select t.eq('D3 Arabic author', t.ids('حسين'), '02');
select t.eq('D3 owner handle', t.ids('bob'), '01');
select t.eq('D3 owner display name', t.ids('reader'), '07,02,01');
select t.eq('D3 extra whitespace is ignored', t.ids('   dune    saga  '), '01');
select t.eq('D3 a private book cannot be found by its title', t.ids('Private One'), '');
select t.eq('D3 ...nor a pending one', t.ids('Pending'), '');

/* ---------- wildcards and odd input are literal ---------- */
select t.eq('D4 % is literal: matches only the book containing a percent sign', t.ids('%'), '07');
select t.eq('D4 _ is literal', t.ids('_'), '07');
select t.eq('D4 100% matches the literal text', t.ids('100%'), '07');
select t.eq('D4 a backslash is literal and harmless', t.ids('\'), '');
select t.eq('D4 quotes are harmless', t.ids($$' or 1=1 --$$), '');
select t.eq('D4 an overlong query is cut, not an error', (select count(*)::text from public.discover_books(repeat('x', 5000), 30, 0)), '0');
select t.eq('D4 more than 6 words: extra words are ignored', t.ids('dune saga frank herbert alice reader zzz yyy'), '01');

/* ---------- paging ---------- */
select t.eq('D5 limit 2', t.ids('', 2, 0), '01,01');
select t.eq('D5 offset 2 limit 2', t.ids('', 2, 2), '07,02');
select t.eq('D5 offset past the end', t.ids('', 5, 50), '');
select t.eq('D5 a huge limit is accepted (capped at 60 inside)', (select count(*)::text from public.discover_books('', 100000, 0)), '5');
select t.eq('D5 limit 0 / negative become 1', t.ids('', 0, 0) || '|' || t.ids('', -5, 0), '01|01');
select t.eq('D5 negative offset becomes 0', t.ids('', 1, -9), '01');
select t.eq('D5 null limit / offset use the defaults', (select count(*)::text from public.discover_books('', null, null)), '5');

/* ---------- blocks ---------- */
select t.admin();
insert into public.blocks (blocker_id, blocked_id) values (:'alice', :'eve');
select t.login(:'eve');
select t.eq('D6 a blocked user no longer sees the blocker''s books', (select count(*)::text from public.discover_books('', 60, 0) where owner_id = :'alice'), '0');
select t.eq('D6 ...but still sees everybody else''s', t.ids(''), '01,01');
select t.login(:'alice');
select t.eq('D6 the blocker does not see the blocked user''s books either', (select count(*)::text from public.discover_books('', 60, 0) where owner_id = :'eve'), '0');
select t.anon();
select t.eq('D6 anonymous visitors are not affected by a block', (select count(*)::text from public.discover_books('', 60, 0) where owner_id in (:'alice', :'eve')), '4');
select t.admin();
delete from public.blocks where blocker_id = :'alice';

/* ---------- the rules follow the data immediately ---------- */
update public.books set access = 'private' where id = :'b1';
select t.anon();
select t.eq('D7 a book switched to private disappears at once', t.ids('dune'), '');
select t.admin();
update public.books set access = 'public' where id = :'b1';
update public.books set file_status = 'failed' where id = :'b2';
select t.anon();
select t.eq('D7 a failed file disappears', t.ids('الأيام'), '');
select t.admin();
update public.books set file_status = 'ready' where id = :'b2';

-- an inheriting book follows the strictest of its shelves (same rule as everywhere)
insert into public.shelves (id, library_id, owner_id, name, access) values (:'s_pub', :'alib', :'alice', 'Open', 'public'), (:'s_priv', :'alib', :'alice', 'Closed', 'private');
insert into public.shelf_books (shelf_id, book_id, owner_id) values (:'s_pub', :'b8', :'alice');
select t.anon();
select t.eq('D8 an inheriting book on a PUBLIC shelf is discoverable', t.ids('inherits'), '08');
select t.admin();
insert into public.shelf_books (shelf_id, book_id, owner_id) values (:'s_priv', :'b8', :'alice');
select t.anon();
select t.eq('D8 ...and hidden again once it also sits on a PRIVATE shelf', t.ids('inherits'), '');
select t.admin();
delete from public.shelf_books where book_id = :'b8';

/* ---------- libraries ---------- */
select t.anon();
select t.eq('D9 a private library is not listed', t.libs(''), '');
select t.admin();
update public.libraries set default_access = 'public', title = 'The Great Reading Room' where owner_id = :'alice';
select t.anon();
select t.eq('D9 a public library is listed with the number of its PUBLIC books only (b1, b2, b7 + the inheriting b8)', t.libs(''), 'alice:4');
select t.eq('D9 search by library title', t.libs('reading room'), 'alice:4');
select t.eq('D9 search by handle', t.libs('alice'), 'alice:4');
select t.eq('D9 search by display name', t.libs('reader'), 'alice:4');
select t.eq('D9 no match', t.libs('zzz'), '');
select t.admin();
update public.libraries set default_access = 'public' where owner_id = :'bob';
update public.books set access = 'private' where id = :'bb';
select t.anon();
select t.eq('D9 a public library with no public book is not listed', t.libs(''), 'alice:4');
select t.admin();
update public.books set access = 'public' where id = :'bb';
update public.libraries set default_access = 'password' where owner_id = :'bob';
select t.anon();
select t.eq('D9 a password library is not listed', t.libs(''), 'alice:4');
select t.admin();
update public.libraries set default_access = 'public' where owner_id = :'bob';
insert into public.blocks (blocker_id, blocked_id) values (:'bob', :'zed');
select t.login(:'zed');
select t.eq('D9 a blocked viewer does not see the blocker''s library', t.libs(''), 'alice:4');
select t.login(:'dave');
select t.eq('D9 everyone else sees both', t.libs(''), 'alice:4,bob:1');
select t.admin();
delete from public.blocks where blocker_id = :'bob';

/* ---------- what is returned, and who may call ---------- */
select t.ok('D10 books result has no file hash / storage path column',
  pg_get_function_result('public.discover_books(text,integer,integer)'::regprocedure) !~* 'hash|path|rights');
select t.ok('D10 libraries result has no owner id',
  pg_get_function_result('public.discover_libraries(text,integer,integer)'::regprocedure) !~* 'owner_id|\mid\M');
select t.ok('D10 the private helper is not exposed as an RPC',
  not has_function_privilege('public', 'private.search_words(text)', 'execute'));
select t.ok('D10 anon may call discover_books', has_function_privilege('anon', 'public.discover_books(text,integer,integer)', 'execute'));
select t.ok('D10 anon may call discover_libraries', has_function_privilege('anon', 'public.discover_libraries(text,integer,integer)', 'execute'));
select t.ok('D10 PUBLIC has no direct execute right on discover_books', not has_function_privilege('public', 'public.discover_books(text,integer,integer)', 'execute'));
select t.anon();
select t.throws('D10 the tables themselves stay closed: anon cannot select file_hash', 'select file_hash from public.books', 'permission denied');
select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
