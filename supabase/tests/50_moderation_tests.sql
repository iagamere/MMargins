\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
\set mia   '88888888-8888-4888-8888-888888888888'
\set noprof '99999999-9999-4999-8999-999999999999'
\set s1 'cccccccc-5000-4000-8000-000000000001'
\set s2 'cccccccc-5000-4000-8000-000000000002'
\set c1 'aaaaaaaa-5000-4000-8000-000000000001'
\set c2 'aaaaaaaa-5000-4000-8000-000000000002'
\set c3 'aaaaaaaa-5000-4000-8000-000000000003'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test'),(:'mia','m@x.test'),(:'noprof','n@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'carol'); select public.create_profile('carol', 'Carol');
select t.login(:'mia');   select public.create_profile('mia', 'Mia');
select t.admin();
insert into public.moderators (user_id) values (:'mia');
insert into public.shelves (id, owner_id, title) values (:'s1', :'alice', 'Open Shelf'), (:'s2', :'alice', 'Draft Shelf');
insert into public.chapters (id, shelf_id, owner_id, title, format, file_hash, file_size, file_status, published_at) values
  (:'c1', :'s1', :'alice', 'Pirated Copy', 'epub', repeat('1',64), 10, 'ready', now()),
  (:'c2', :'s1', :'alice', 'Fine Chapter', 'epub', repeat('2',64), 10, 'ready', now()),
  (:'c3', :'s2', :'alice', 'Hidden Draft', 'epub', repeat('3',64), 10, 'ready', null);

/* ---------- filing a report ---------- */
select t.login(:'bob');
select public.report_content('chapter', :'c1', 'copyright', '   they copied my book   ');
select t.admin();
select t.eq('V1 details are trimmed', (select details from public.reports where reporter_id = :'bob' and target_id = :'c1'), 'they copied my book');
select t.login(:'bob');
select t.throws('V1 the same open report twice is refused', format($$select public.report_content('chapter', %L, 'spam')$$, :'c1'), 'already_reported');
select t.throws('V1 a draft chapter cannot be reported (it cannot be seen)', format($$select public.report_content('chapter', %L, 'abuse')$$, :'c3'), 'not_found');
select t.throws('V1 a shelf of drafts cannot be reported either', format($$select public.report_content('shelf', %L, 'abuse')$$, :'s2'), 'not_found');
select t.throws('V1 an unknown id gives the same answer', $$select public.report_content('chapter', gen_random_uuid(), 'abuse')$$, 'not_found');
select t.throws('V1 an unknown account is not found', $$select public.report_content('profile', gen_random_uuid(), 'abuse')$$, 'not_found');
select t.login(:'alice');
select t.throws('V1 nobody reports their own chapter', format($$select public.report_content('chapter', %L, 'abuse')$$, :'c1'), 'invalid_request');
select t.throws('V1 nobody reports themselves', format($$select public.report_content('profile', %L, 'abuse')$$, :'alice'), 'invalid_request');
select t.login(:'noprof');
select t.throws('V1 a signed-in user without a profile cannot report', format($$select public.report_content('chapter', %L, 'abuse')$$, :'c1'), 'profile_required');
select t.anon();
select t.throws('V1 anonymous cannot report', format($$select public.report_content('chapter', %L, 'abuse')$$, :'c1'), 'permission denied');
select t.login(:'bob');
select t.throws('V1 a client cannot read reports', $$select * from public.reports$$, 'permission denied');
select t.throws('V1 a client cannot write reports', format($$insert into public.reports (reporter_id, target_type, target_id, reason) values (%L, 'chapter', %L, 'spam')$$, :'bob', :'c2'), 'permission denied');
select t.throws('V1 a client cannot read the moderators list', $$select * from public.moderators$$, 'permission denied');
select t.throws('V1 a client cannot make themselves a moderator', format($$insert into public.moderators (user_id) values (%L)$$, :'bob'), 'permission denied');
select t.ok('V1 a client cannot reach the blocklist', not has_table_privilege('authenticated', 'private.removed_hashes', 'select'));

/* rate limit: 10 reports per rolling day */
select t.admin();
insert into public.reports (reporter_id, target_type, target_id, reason, status)
  select :'carol', 'profile', gen_random_uuid(), 'spam', 'dismissed' from generate_series(1, 10);
select t.login(:'carol');
select t.throws('V2 the 11th report in a day is refused', format($$select public.report_content('chapter', %L, 'spam')$$, :'c2'), 'rate_limited');
select t.admin();
delete from public.reports where reporter_id = :'carol';   -- the rest of the file needs carol to be allowed to report again

/* ---------- only moderators moderate ---------- */
select t.login(:'bob');
select t.ok('V3 a normal user is not a moderator', not public.am_i_moderator());
select t.throws('V3 the queue is closed to them', $$select * from public.moderation_queue()$$, 'forbidden');
select t.admin();
select id as rid from public.reports where reporter_id = :'bob' and target_id = :'c1' \gset
select t.login(:'bob');
select t.throws('V3 resolving is closed to them', format($$select public.resolve_report(%L, 'takedown')$$, :'rid'), 'forbidden');
select t.throws('V3 restoring is closed to them', format($$select public.restore_item('chapter', %L)$$, :'c1'), 'forbidden');
select t.login(:'mia');
select t.ok('V3 a moderator is recognised', public.am_i_moderator());
select t.eq('V3 the moderator sees the open reports about c1 (one, plus none for others)', (select count(*) from public.moderation_queue('open') where target_id = :'c1'), 1::bigint);
select t.eq('V3 the queue shows the title and the owner', (select target_title || '/' || owner_handle from public.moderation_queue('open') where target_id = :'c1'), 'Pirated Copy/alice');
select t.throws('V3 an unknown action is refused', format($$select public.resolve_report(%L, 'explode')$$, :'rid'), 'invalid_request');

/* ---------- dismissing ---------- */
select t.login(:'carol');
select t.admin();
insert into public.reports (reporter_id, target_type, target_id, reason) values (:'carol', 'chapter', :'c2', 'abuse');
select id as rid2 from public.reports where reporter_id = :'carol' and target_id = :'c2' \gset
select t.login(:'mia');
select public.resolve_report(:'rid2', 'dismiss', 'looks fine');
select t.admin();
select t.eq('V4 a dismissed report is closed', (select status::text || ':' || resolution from public.reports where id = :'rid2'), 'dismissed:dismissed');
select t.ok('V4 the chapter stays visible', (select removed_at is null and published_at is not null from public.chapters where id = :'c2'));
select t.login(:'mia');
select t.throws('V4 a closed report cannot be resolved twice', format($$select public.resolve_report(%L, 'dismiss')$$, :'rid2'), 'not_found');

/* ---------- takedown of a chapter ---------- */
select t.login(:'carol');
select public.report_content('chapter', :'c1', 'copyright');
select t.login(:'mia');
select public.resolve_report(:'rid', 'takedown', 'copyright holder confirmed');
select t.admin();
select t.ok('V5 the chapter is removed and unpublished', (select removed_at is not null and published_at is null and removed_reason = 'copyright' from public.chapters where id = :'c1'));
select t.eq('V5 both open reports about it are settled together', (select count(*) from public.reports where target_id = :'c1' and status = 'actioned' and resolution = 'removed'), 2::bigint);
select t.login(:'bob');
select t.ok('V5 others no longer see it', (select count(*) from public.chapters where id = :'c1') = 0);
select t.login(:'alice');
select t.eq('V5 the owner is told what was removed and why', (select kind || ':' || title || ':' || reason::text from public.my_removed()), 'chapter:Pirated Copy:copyright');
select t.eq('V5 and cannot publish it again', public.publish_chapters(array[:'c1']::uuid[]), 0);
select t.throws('V5 the same file cannot be uploaded again', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'again', 'epub', repeat('1',64), 10)$$, :'s1', :'alice'), 'content_removed');
select t.login(:'bob');
insert into public.shelves (owner_id, title) values (:'bob', 'Bob shelf') returning id as bshelf \gset
select t.throws('V5 nor by anybody else', format($$insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (%L, %L, 'copy', 'epub', repeat('1',64), 10)$$, :'bshelf', :'bob'), 'content_removed');
select t.login(:'alice');
select t.throws('V5 the owner cannot clear the takedown', format($$update public.chapters set removed_at = null where id = %L$$, :'c1'), 'permission denied');
select t.login(:'bob');
select t.eq('V5 my_removed answers about the caller only (bob has nothing removed)', (select count(*) from public.my_removed()), 0::bigint);

/* ---------- restoring ---------- */
select t.login(:'mia');
select public.restore_item('chapter', :'c1');
select t.admin();
select t.ok('V6 a restored chapter comes back as a DRAFT', (select removed_at is null and published_at is null from public.chapters where id = :'c1'));
select t.login(:'bob');
select t.ok('V6 and is still invisible to others', (select count(*) from public.chapters where id = :'c1') = 0);
insert into public.chapters (shelf_id, owner_id, title, format, file_hash, file_size) values (:'bshelf', :'bob', 'copy', 'epub', repeat('1',64), 10);
select t.ok('V6 the file is no longer blocked', exists (select 1 from public.chapters where owner_id = :'bob' and title = 'copy'));
select t.login(:'alice');
select t.eq('V6 the owner has nothing listed as removed any more', (select count(*) from public.my_removed()), 0::bigint);
select t.eq('V6 and can publish it again', public.publish_chapters(array[:'c1']::uuid[]), 1);

/* ---------- takedown of a shelf; profiles are not banned ---------- */
select t.login(:'bob');
select public.report_content('shelf', :'s1', 'illegal', 'the whole novel');
select public.report_content('profile', :'alice', 'abuse');
select t.login(:'mia');
select id as rsh from public.moderation_queue('open') where target_type = 'shelf' and target_id = :'s1' \gset
select id as rpr from public.moderation_queue('open') where target_type = 'profile' and target_id = :'alice' \gset
select t.throws('V7 a profile cannot be taken down by a report', format($$select public.resolve_report(%L, 'takedown')$$, :'rpr'), 'invalid_request');
select public.resolve_report(:'rpr', 'noted', 'warned');
select public.resolve_report(:'rsh', 'takedown');
select t.login(:'bob');
select t.ok('V7 a removed shelf disappears for others, with its chapters', (select count(*) from public.shelves where id = :'s1') = 0 and (select count(*) from public.chapters where shelf_id = :'s1') = 0);
select t.login(:'alice');
select t.eq('V7 the owner is told about the shelf', (select count(*) from public.my_removed() where kind = 'shelf' and item_id = :'s1'), 1::bigint);
select t.login(:'mia');
select public.restore_item('shelf', :'s1');
select t.login(:'bob');
select t.ok('V7 a restored shelf is visible again', (select count(*) from public.shelves where id = :'s1') = 1);
select t.login(:'mia');
select t.ok('V7 the moderator''s history lists the closed reports', (select count(*) from public.moderation_queue('closed')) >= 4);
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
