\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set s1 'cccccccc-3000-4000-8000-000000000001'
\set s2 'cccccccc-3000-4000-8000-000000000002'
\set c1 'aaaaaaaa-3000-4000-8000-000000000001'
\set c2 'aaaaaaaa-3000-4000-8000-000000000002'
\set c3 'aaaaaaaa-3000-4000-8000-000000000003'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');

/* ---------- a new shelf is invisible to others until a chapter is published ---------- */
-- fixed ids need the table owner (clients cannot choose ids)
select t.admin();
insert into public.shelves (id, owner_id, title, description) values (:'s1', :'alice', 'The Long Night', 'a novel');
select t.login(:'alice');
insert into public.shelves (owner_id, title) values (:'alice', 'Made by the client') returning id as made \gset
select t.ok('C1 a client can create her own shelf (without choosing the id)', exists (select 1 from public.shelves where id = :'made'));
select t.throws('C1 a client cannot choose the id', format($$insert into public.shelves (id, owner_id, title) values (%L, %L, 'x')$$, :'s2', :'alice'), 'permission denied');
select t.ok('C1 owner sees her new shelf', (select count(*) from public.shelves where id = :'s1') = 1);
select t.login(:'bob');
select t.ok('C1 others do not see an empty shelf', (select count(*) from public.shelves where id = :'s1') = 0);
select t.anon();
select t.ok('C1 anonymous does not see it either', (select count(*) from public.shelves) = 0);

/* ---------- chapters: what a client may set on insert ---------- */
select t.admin();
insert into public.chapters (id, shelf_id, owner_id, position, title, format, file_hash, file_size) values
  (:'c1', :'s1', :'alice', 1, 'Chapter 1', 'epub', repeat('1', 64), 1000);
select t.login(:'alice');
insert into public.chapters (shelf_id, owner_id, position, title, format, file_hash, file_size) values (:'s1', :'alice', 9, 'By the client', 'pdf', repeat('f', 64), 10) returning id as made_c \gset
select t.ok('C2 a client can add a chapter to her own shelf', exists (select 1 from public.chapters where id = :'made_c'));
delete from public.chapters where id = :'made_c';
select t.eq('C2 a new chapter is a draft and pending', (select file_status::text || ':' || coalesce(published_at::text, 'draft') from public.chapters where id = :'c1'), 'pending:draft');
select t.throws('C2 a client cannot set published_at on insert', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size, published_at) values (%L, %L, 'x', 'epub', repeat('2', 64), 10, now())$$, :'s1', :'alice'), 'permission denied');
select t.throws('C2 a client cannot set file_status on insert', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size, file_status) values (%L, %L, 'x', 'epub', repeat('2', 64), 10, 'ready')$$, :'s1', :'alice'), 'permission denied');
select t.throws('C2 file_hash is never readable', $$select file_hash from public.chapters$$, 'permission denied');
select t.throws('C2 removed_at is never readable', $$select removed_at from public.chapters$$, 'permission denied');
select t.throws('C2 bad format refused', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'x', 'txt', repeat('2', 64), 10)$$, :'s1', :'alice'), 'chapters_format');
select t.throws('C2 bad hash refused', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'x', 'epub', 'nothex', 10)$$, :'s1', :'alice'), 'chapters_hash');
select t.throws('C2 file over 50 MB refused', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'x', 'epub', repeat('2', 64), 52428801)$$, :'s1', :'alice'), 'chapters_size');
select t.throws('C2 empty title refused', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, '  ', 'epub', repeat('2', 64), 10)$$, :'s1', :'alice'), 'chapters_title_len');
select t.throws('C2 the same file twice by one owner refused', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'dup', 'epub', repeat('1', 64), 10)$$, :'s1', :'alice'), 'duplicate');

/* ---------- nobody else can put chapters on my shelf, or touch them ---------- */
select t.login(:'bob');
select t.throws('C3 bob cannot add a chapter to alice''s shelf (as alice)', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'x', 'epub', repeat('3', 64), 10)$$, :'s1', :'alice'), 'row-level security');
select t.throws('C3 bob cannot add a chapter to alice''s shelf (as himself)', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'x', 'epub', repeat('3', 64), 10)$$, :'s1', :'bob'), 'violates foreign key');
select t.throws('C3 bob cannot create a shelf in alice''s name', format($$insert into public.shelves (owner_id, title) values (%L, 'fake')$$, :'alice'), 'row-level security');
select t.ok('C3 bob cannot even see the draft', (select count(*) from public.chapters) = 0);

/* ---------- publishing (the file must be 'ready' first; the test plays the role of finalize_chapter_upload) ---------- */
select t.login(:'alice');
select t.eq('C4 a pending chapter cannot be published', public.publish_chapters(array[:'c1']::uuid[]), 0);
select t.admin();
update public.chapters set file_status = 'ready' where id = :'c1';
select t.login(:'alice');
select t.throws('C4 a client cannot publish by updating the column', format($$update public.chapters set published_at = now() where id = %L$$, :'c1'), 'permission denied');
select t.throws('C4 a client cannot mark a file ready', format($$update public.chapters set file_status = 'ready' where id = %L$$, :'c1'), 'permission denied');
select t.login(:'bob');
select t.eq('C4 bob cannot publish alice''s chapter', public.publish_chapters(array[:'c1']::uuid[]), 0);
select t.ok('C4 it is still invisible to bob', (select count(*) from public.chapters) = 0 and (select count(*) from public.shelves) = 0);
select t.login(:'alice');
select t.eq('C4 the owner publishes a ready chapter', public.publish_chapters(array[:'c1']::uuid[]), 1);
select t.login(:'bob');
select t.ok('C4 now bob sees the shelf', (select count(*) from public.shelves where id = :'s1') = 1);
select t.ok('C4 and the chapter, with a publish date', (select count(*) from public.chapters where id = :'c1' and published_at is not null) = 1);
select t.anon();
select t.ok('C4 anonymous sees both too', (select count(*) from public.shelves) = 1 and (select count(*) from public.chapters) = 1);

/* a second chapter stays a draft: invisible to others, visible to the owner */
select t.admin();
insert into public.chapters (id, shelf_id, owner_id, position, title, format, file_hash, file_size, file_status) values (:'c2', :'s1', :'alice', 2, 'Chapter 2', 'pdf', repeat('2', 64), 2000, 'ready');
select t.login(:'bob');
select t.eq('C5 bob sees only the published chapter', (select count(*) from public.chapters), 1::bigint);
select t.login(:'alice');
select t.eq('C5 alice sees both', (select count(*) from public.chapters), 2::bigint);
select t.eq('C5 my_chapter_hashes lists only mine', (select count(*) from public.my_chapter_hashes()), 2::bigint);
select t.login(:'bob');
select t.eq('C5 bob has no chapter hashes', (select count(*) from public.my_chapter_hashes()), 0::bigint);

/* ---------- editing and deleting ---------- */
update public.chapters set title = 'Hacked' where id = :'c1';
delete from public.chapters where id = :'c1';
update public.shelves set title = 'Hacked' where id = :'s1';
delete from public.shelves where id = :'s1';
select t.admin();
select t.ok('C6 nobody else edits or deletes my chapter or shelf', (select title from public.chapters where id = :'c1') = 'Chapter 1' and (select title from public.shelves where id = :'s1') = 'The Long Night');
select t.login(:'alice');
update public.chapters set title = 'Chapter One', position = 5 where id = :'c1';
select t.ok('C6 the owner renames and reorders', (select title = 'Chapter One' and position = 5 from public.chapters where id = :'c1'));
select t.throws('C6 a chapter cannot be moved to another shelf', format($$update public.chapters set shelf_id = %L where id = %L$$, :'s2', :'c1'), 'permission denied');
select t.throws('C6 shelf cannot change owner', format($$update public.shelves set owner_id = %L where id = %L$$, :'bob', :'s1'), 'permission denied');
select t.throws('C6 shelf title empty refused', format($$update public.shelves set title = '' where id = %L$$, :'s1'), 'shelves_title_len');
select t.throws('C6 shelf description too long refused', format($$update public.shelves set description = %L where id = %L$$, repeat('x', 1001), :'s1'), 'shelves_description_len');
select t.throws('C6 removed_at on shelves is not writable', format($$update public.shelves set removed_at = now() where id = %L$$, :'s1'), 'permission denied');

/* ---------- unpublish hides again; a shelf with only drafts vanishes ---------- */
select t.eq('C7 owner unpublishes', public.unpublish_chapters(array[:'c1']::uuid[]), 1);
select t.login(:'bob');
select t.ok('C7 chapter and shelf are hidden again', (select count(*) from public.chapters) = 0 and (select count(*) from public.shelves) = 0);
select t.login(:'alice');
select t.eq('C7 the owner publishes it again', (select public.publish_chapters(array[:'c1']::uuid[])), 1);
select t.login(:'bob');
select t.eq('C7 (and really cannot)', public.unpublish_chapters(array[:'c1']::uuid[]), 0);
select t.eq('C7 the shelf is visible again after republishing', (select count(*) from public.shelves), 1::bigint);

/* ---------- a taken-down shelf / chapter disappears for others ---------- */
select t.admin();
update public.chapters set removed_at = now() where id = :'c1';
select t.login(:'bob');
select t.ok('C8 a removed chapter is hidden even though it is published', (select count(*) from public.chapters) = 0 and (select count(*) from public.shelves) = 0);
select t.login(:'alice');
select t.eq('C8 the owner still sees it', (select count(*) from public.chapters where id = :'c1'), 1::bigint);
select t.eq('C8 and cannot publish it again', public.publish_chapters(array[:'c1']::uuid[]), 0);
select t.admin();
update public.chapters set removed_at = null where id = :'c1';
update public.shelves set removed_at = now() where id = :'s1';
select t.login(:'bob');
select t.ok('C8 a removed shelf hides its published chapters', (select count(*) from public.shelves) = 0 and (select count(*) from public.chapters) = 0);
select t.admin();
update public.shelves set removed_at = null where id = :'s1';

/* ---------- quotas ---------- */
select t.admin();
insert into public.shelves (owner_id, title) select :'bob', 'filler ' || g from generate_series(1, 200) g;
select t.login(:'bob');
select t.throws('C9 201st shelf refused', format($$insert into public.shelves (owner_id, title) values (%L, 'one too many')$$, :'bob'), 'quota_exceeded');
select t.admin();
insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size)
  select :'s1', :'alice', 'q' || g, 'epub', md5(g::text) || md5(g::text || 'x'), 10 from generate_series(1, 298) g;   -- 2 existing + 298 = 300
select t.login(:'alice');
select t.throws('C9 301st chapter on a shelf refused', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'one too many', 'epub', repeat('9', 64), 10)$$, :'s1', :'alice'), 'quota_exceeded');

/* ---------- deleting a shelf deletes its chapters ---------- */
delete from public.shelves where id = :'s1';
select t.admin();
select t.eq('C10 chapters go with the shelf', (select count(*) from public.chapters where shelf_id = :'s1'), 0::bigint);
select t.anon();
select t.throws('C10 anonymous cannot create a shelf', format($$insert into public.shelves (owner_id, title) values (%L, 'x')$$, :'alice'), 'permission denied');
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
