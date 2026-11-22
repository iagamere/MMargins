\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set b1 'aaaaaaaa-0000-4000-8000-000000000001'
\set b2 'aaaaaaaa-0000-4000-8000-000000000002'
\set b3 'bbbbbbbb-0000-4000-8000-000000000003'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
-- fixed ids need the table owner (clients cannot choose ids)
select t.admin();
insert into public.books (id, owner_id, title, format, file_hash, file_size, rights_confirmed_at) values
  (:'b1', :'alice', 'E', 'epub', repeat('a',64), 1000, now()), (:'b2', :'alice', 'P', 'pdf', repeat('b',64), 2000, now()),
  (:'b3', :'bob', 'B', 'epub', repeat('c',64), 500, now());

/* buckets */
select t.admin();
select t.ok('S1 books bucket is private with a size limit and mime allow-list', (select not public and file_size_limit = 52428800 and allowed_mime_types @> array['application/epub+zip'] from storage.buckets where id = 'books'));
select t.ok('S1 covers bucket is private', (select not public from storage.buckets where id = 'covers'));

/* upload rules */
select t.login(:'alice');
insert into storage.objects (bucket_id, name, metadata) values ('books', :'alice' || '/' || :'b1' || '.epub', '{"size": 1000}');
select t.ok('S2 owner uploads to her own path', exists (select 1 from storage.objects where name = :'alice' || '/' || :'b1' || '.epub'));
select t.throws('S2 wrong extension for the book format is refused', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'alice' || '/' || :'b1' || '.pdf'), 'row-level security');
select t.throws('S2 a book that is not hers is refused (in her own folder)', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'alice' || '/' || :'b3' || '.epub'), 'row-level security');
select t.throws('S2 writing into another user''s folder is refused', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'bob' || '/' || :'b3' || '.epub'), 'row-level security');
select t.throws('S2 a malformed path is refused (no cast error)', $$insert into storage.objects (bucket_id, name) values ('books', 'x/y.epub')$$, 'row-level security');
select t.throws('S2 an unknown bucket is refused', format($$insert into storage.objects (bucket_id, name) values ('covers', %L)$$, :'alice' || '/' || :'b1' || '.png'), 'row-level security');
select t.anon();
select t.throws('S2 anonymous cannot upload', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'alice' || '/' || :'b2' || '.pdf'), 'row-level security');
select t.ok('S2 anonymous sees no files', (select count(*) from storage.objects) = 0);
select t.login(:'bob');
select t.ok('S3 another user cannot see the file', (select count(*) from storage.objects) = 0);
delete from storage.objects where name = :'alice' || '/' || :'b1' || '.epub';
select t.admin();
select t.ok('S3 another user cannot delete the file', exists (select 1 from storage.objects where name = :'alice' || '/' || :'b1' || '.epub'));

/* finalize */
select t.login(:'alice');
select t.throws('S4 finalize without an uploaded file fails', format($$select public.finalize_book_upload(%L)$$, :'b2'), 'upload_missing');
select t.eq('S4 right size -> ready', public.finalize_book_upload(:'b1'), 'ready'::public.file_status);
select t.eq('S4 the book is now ready', (select file_status from public.books where id = :'b1'), 'ready'::public.file_status);
insert into storage.objects (bucket_id, name, metadata) values ('books', :'alice' || '/' || :'b2' || '.pdf', '{"size": 1}');
select t.eq('S4 wrong size -> failed', public.finalize_book_upload(:'b2'), 'failed'::public.file_status);
update storage.objects set metadata = '{"size": 2000}' where name = :'alice' || '/' || :'b2' || '.pdf';
select t.eq('S4 a failed book can be retried with the right file', public.finalize_book_upload(:'b2'), 'ready'::public.file_status);
select t.throws('S4 the client cannot mark a book ready itself', format($$update public.books set file_status = 'ready' where id = %L$$, :'b3'), 'permission denied');
select t.login(:'bob');
select t.throws('S4 another user cannot finalize my book', format($$select public.finalize_book_upload(%L)$$, :'b1'), 'not_found');
select t.anon();
select t.throws('S4 anonymous cannot finalize', format($$select public.finalize_book_upload(%L)$$, :'b1'), 'permission denied');

/* a published file cannot be swapped */
select t.login(:'alice');
select t.throws('S5 no new upload over a ready book', format($$insert into storage.objects (bucket_id, name, metadata) values ('books', %L, '{"size": 1000}')$$, :'alice' || '/' || :'b1' || '.epub'), 'row-level security');
update storage.objects set metadata = '{"size": 9}' where name = :'alice' || '/' || :'b1' || '.epub';
select t.admin();
select t.eq('S5 ...nor an overwrite of it (size unchanged)', (select metadata ->> 'size' from storage.objects where name = :'alice' || '/' || :'b1' || '.epub'), '1000');

/* covers */
select t.login(:'alice');
insert into storage.objects (bucket_id, name, metadata) values ('covers', :'alice' || '/' || :'b1' || '.jpg', '{"size": 10}');
select t.ok('S6 owner uploads a cover for her book', exists (select 1 from storage.objects where bucket_id = 'covers'));
select t.throws('S6 cover for someone else''s book is refused', format($$insert into storage.objects (bucket_id, name) values ('covers', %L)$$, :'alice' || '/' || :'b3' || '.jpg'), 'row-level security');
delete from storage.objects where bucket_id = 'covers' and name = :'alice' || '/' || :'b1' || '.jpg';
select t.ok('S6 owner removes her cover', not exists (select 1 from storage.objects where bucket_id = 'covers'));

/* hashes */
select t.eq('S7 my_book_hashes returns only my books', (select count(*) from public.my_book_hashes()), 2::bigint);
select t.login(:'bob');
select t.eq('S7 ...and bob sees only his own', (select count(*) from public.my_book_hashes()), 1::bigint);
select t.anon();
select t.throws('S7 anonymous cannot call it', $$select * from public.my_book_hashes()$$, 'permission denied');

select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
