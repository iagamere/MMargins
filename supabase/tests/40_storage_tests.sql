\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set s1 'cccccccc-4000-4000-8000-000000000001'
\set s2 'cccccccc-4000-4000-8000-000000000002'
\set c1 'aaaaaaaa-4000-4000-8000-000000000001'
\set c2 'aaaaaaaa-4000-4000-8000-000000000002'
\set c3 'bbbbbbbb-4000-4000-8000-000000000003'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.admin();
insert into public.shelves (id, owner_id, title) values (:'s1', :'alice', 'Alice novel'), (:'s2', :'bob', 'Bob novel');
insert into public.chapters (id, shelf_id, owner_id, title, format, file_hash, file_size) values
  (:'c1', :'s1', :'alice', 'E', 'epub', repeat('a',64), 1000), (:'c2', :'s1', :'alice', 'P', 'pdf', repeat('b',64), 2000),
  (:'c3', :'s2', :'bob', 'B', 'epub', repeat('c',64), 500);

/* buckets */
select t.ok('S1 books bucket is private with a size limit and mime allow-list', (select not public and file_size_limit = 52428800 and allowed_mime_types @> array['application/epub+zip'] from storage.buckets where id = 'books'));
select t.ok('S1 media bucket is public, small, images only', (select public and file_size_limit = 409600 and allowed_mime_types @> array['image/webp'] and not allowed_mime_types @> array['application/pdf'] from storage.buckets where id = 'media'));

/* chapter files: upload rules */
select t.login(:'alice');
insert into storage.objects (bucket_id, name, metadata) values ('books', :'alice' || '/' || :'c1' || '.epub', '{"size": 1000}');
select t.ok('S2 owner uploads to her own path', exists (select 1 from storage.objects where name = :'alice' || '/' || :'c1' || '.epub'));
select t.throws('S2 wrong extension for the chapter format is refused', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'alice' || '/' || :'c1' || '.pdf'), 'row-level security');
select t.throws('S2 a chapter that is not hers is refused', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'alice' || '/' || :'c3' || '.epub'), 'row-level security');
select t.throws('S2 writing into another user''s folder is refused', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'bob' || '/' || :'c3' || '.epub'), 'row-level security');
select t.throws('S2 a malformed path is refused (no cast error)', $$insert into storage.objects (bucket_id, name) values ('books', 'x/y.epub')$$, 'row-level security');
select t.throws('S2 an unknown bucket is refused', format($$insert into storage.objects (bucket_id, name) values ('covers', %L)$$, :'alice' || '/' || :'c1' || '.png'), 'row-level security');
select t.anon();
select t.throws('S2 anonymous cannot upload', format($$insert into storage.objects (bucket_id, name) values ('books', %L)$$, :'alice' || '/' || :'c2' || '.pdf'), 'row-level security');
select t.ok('S2 anonymous sees no chapter files', (select count(*) from storage.objects where bucket_id = 'books') = 0);

/* a draft file is private to its owner */
select t.login(:'bob');
select t.ok('S3 another user cannot see a draft file', (select count(*) from storage.objects where bucket_id = 'books') = 0);
delete from storage.objects where name = :'alice' || '/' || :'c1' || '.epub';
select t.admin();
select t.ok('S3 another user cannot delete it', exists (select 1 from storage.objects where name = :'alice' || '/' || :'c1' || '.epub'));

/* finalize */
select t.login(:'alice');
select t.throws('S4 finalize without an uploaded file fails', format($$select public.finalize_chapter_upload(%L)$$, :'c2'), 'upload_missing');
select t.throws('S4 finalize of somebody else''s chapter fails', format($$select public.finalize_chapter_upload(%L)$$, :'c3'), 'not_found');
select t.eq('S4 right size -> ready', public.finalize_chapter_upload(:'c1'), 'ready'::public.file_status);
insert into storage.objects (bucket_id, name, metadata) values ('books', :'alice' || '/' || :'c2' || '.pdf', '{"size": 1}');
select t.eq('S4 wrong size -> failed', public.finalize_chapter_upload(:'c2'), 'failed'::public.file_status);
update storage.objects set metadata = '{"size": 2000}' where name = :'alice' || '/' || :'c2' || '.pdf';
select t.eq('S4 a failed chapter can be retried with the right file', public.finalize_chapter_upload(:'c2'), 'ready'::public.file_status);

/* a ready file never changes */
update storage.objects set metadata = '{"size": 7}' where name = :'alice' || '/' || :'c1' || '.epub';
select t.admin();
select t.eq('S5 a ready file cannot be overwritten', (select (metadata ->> 'size')::int from storage.objects where name = :'alice' || '/' || :'c1' || '.epub'), 1000);

/* reading: only while the chapter is visible */
select t.login(:'bob');
select t.ok('S6 a ready but UNPUBLISHED chapter is still private', (select count(*) from storage.objects where bucket_id = 'books') = 0);
select t.login(:'alice');
select public.publish_chapters(array[:'c1']::uuid[]);
select t.login(:'bob');
select t.eq('S6 a published chapter file is readable by another signed-in user (and only that one)', (select count(*) from storage.objects where bucket_id = 'books'), 1::bigint);
delete from storage.objects where name = :'alice' || '/' || :'c1' || '.epub';
update storage.objects set name = :'bob' || '/' || :'c3' || '.epub' where name = :'alice' || '/' || :'c1' || '.epub';
select t.admin();
select t.ok('S6 reading does not give write or delete access', exists (select 1 from storage.objects where name = :'alice' || '/' || :'c1' || '.epub') and not exists (select 1 from storage.objects where name = :'bob' || '/' || :'c3' || '.epub'));
select t.anon();
select t.ok('S6 anonymous still cannot read chapter files', (select count(*) from storage.objects where bucket_id = 'books') = 0);
select t.admin();
update public.chapters set removed_at = now() where id = :'c1';
select t.login(:'bob');
select t.ok('S6 a taken-down chapter file is no longer readable', (select count(*) from storage.objects where bucket_id = 'books') = 0);
select t.login(:'alice');
select t.ok('S6 the owner still reads her own file', (select count(*) from storage.objects where bucket_id = 'books') = 2);
delete from storage.objects where name = :'alice' || '/' || :'c2' || '.pdf';
select t.ok('S6 the owner can delete her own file', not exists (select 1 from storage.objects where name = :'alice' || '/' || :'c2' || '.pdf'));

/* pictures */
select t.login(:'alice');
insert into storage.objects (bucket_id, name) values ('media', :'alice' || '/avatar.webp'), ('media', :'alice' || '/cover.jpg'), ('media', :'alice' || '/shelf-' || :'s1' || '.webp');
select t.ok('M1 owner uploads avatar, cover and a cover for her shelf', (select count(*) from storage.objects where bucket_id = 'media') = 3);
select t.throws('M1 a cover for somebody else''s shelf is refused', format($$insert into storage.objects (bucket_id, name) values ('media', %L)$$, :'alice' || '/shelf-' || :'s2' || '.webp'), 'row-level security');
select t.throws('M1 another user''s folder is refused', format($$insert into storage.objects (bucket_id, name) values ('media', %L)$$, :'bob' || '/avatar.webp'), 'row-level security');
select t.throws('M1 arbitrary names are refused', format($$insert into storage.objects (bucket_id, name) values ('media', %L)$$, :'alice' || '/anything.webp'), 'row-level security');
select t.throws('M1 other extensions are refused', format($$insert into storage.objects (bucket_id, name) values ('media', %L)$$, :'alice' || '/avatar.png'), 'row-level security');
select t.throws('M1 nested paths are refused', format($$insert into storage.objects (bucket_id, name) values ('media', %L)$$, :'alice' || '/x/avatar.webp'), 'row-level security');
select t.anon();
select t.ok('M2 pictures are public: anonymous lists them', (select count(*) from storage.objects where bucket_id = 'media') = 3);
select t.throws('M2 anonymous cannot upload a picture', format($$insert into storage.objects (bucket_id, name) values ('media', %L)$$, :'alice' || '/avatar.webp'), 'row-level security');
select t.login(:'bob');
delete from storage.objects where name = :'alice' || '/avatar.webp';
update storage.objects set name = :'bob' || '/avatar.webp' where name = :'alice' || '/avatar.webp';
select t.admin();
select t.ok('M2 nobody else deletes or renames my picture', exists (select 1 from storage.objects where name = :'alice' || '/avatar.webp'));
select t.login(:'alice');
update storage.objects set metadata = '{"v":2}' where name = :'alice' || '/avatar.webp';
delete from storage.objects where name = :'alice' || '/cover.jpg';
select t.ok('M2 the owner replaces and deletes her pictures', (select count(*) from storage.objects where bucket_id = 'media') = 2);
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
