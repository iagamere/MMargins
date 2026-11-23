\set ON_ERROR_STOP on
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set carol '33333333-3333-3333-3333-333333333333'
\set dave  '44444444-4444-4444-4444-444444444444'
\set eve   '55555555-5555-4555-8555-555555555555'
\set mia   '88888888-8888-4888-8888-888888888888'
\set gina  '77777777-7777-4777-8777-777777777777'
\set b1 'aaaaaaaa-4000-4000-8000-000000000001'
\set b2 'aaaaaaaa-4000-4000-8000-000000000002'
\set b3 'aaaaaaaa-4000-4000-8000-000000000003'
\set s1 'cccccccc-4000-4000-8000-000000000001'
begin;
\o /dev/null
select t.admin();
insert into auth.users (id, email) values (:'alice','a@x.test'),(:'bob','b@x.test'),(:'carol','c@x.test'),(:'dave','d@x.test'),(:'eve','e@x.test'),(:'mia','m@x.test'),(:'gina','g@x.test');
select t.login(:'alice'); select public.create_profile('alice', 'Alice');
select t.login(:'bob');   select public.create_profile('bob', 'Bob');
select t.login(:'carol'); select public.create_profile('carol', 'Carol');
select t.login(:'dave');  select public.create_profile('dave', 'Dave');
select t.login(:'eve');   select public.create_profile('eve', 'Eve');
select t.login(:'mia');   select public.create_profile('mia', 'Mia');
select t.admin();
insert into public.moderators (user_id) values (:'mia');
select id as alib from public.libraries where owner_id = :'alice' \gset
update public.libraries set default_access = 'public' where id = :'alib';
insert into public.books (id, owner_id, title, format, file_hash, file_size, file_status, access, read_allowed, download_allowed, rights_confirmed_at) values
  (:'b1', :'alice', 'Pirated Copy', 'epub', repeat('1',64), 10, 'ready', 'public',  true,  true,  now()),
  (:'b2', :'alice', 'Hidden Draft', 'epub', repeat('2',64), 10, 'ready', 'private', false, false, now()),
  (:'b3', :'alice', 'Fine Book',    'epub', repeat('3',64), 10, 'ready', 'public',  true,  false, now());
insert into public.shelves (id, library_id, owner_id, name, access) values (:'s1', :'alib', :'alice', 'Open Shelf', 'public');
create function t.types(u uuid) returns text language plpgsql as $$
begin
  perform t.login(u);
  return coalesce((select string_agg(type::text || coalesce(':' || detail, ''), ',' order by type, detail) from public.my_notifications(100, 0)), '');
end $$;
grant execute on function t.types(uuid) to public;

/* ---------- filing a report ---------- */
select t.login(:'bob');   select public.report_content('book', :'b1', 'copyright', '   they copied my book   ');
select t.login(:'carol'); select public.report_content('book', :'b1', 'illegal', 'x');
select t.login(:'dave');  select public.report_content('book', :'b1', 'copyright');
select t.admin();
select id as r_bob from public.reports where reporter_id = :'bob' \gset
select id as r_carol from public.reports where reporter_id = :'carol' \gset
select id as r_dave from public.reports where reporter_id = :'dave' \gset

select t.eq('R1 three reports are open', (select count(*) from public.reports where status = 'open'), 3::bigint);
select t.eq('R1 details are trimmed', (select details from public.reports where id = :'r_bob'), 'they copied my book');
select t.login(:'bob');
select t.throws('R2 a private book cannot be reported (and its existence is not revealed)', format($$select public.report_content('book', %L, 'spam')$$, :'b2'), 'not_found');
select t.throws('R2 an unknown id looks the same', $$select public.report_content('book', gen_random_uuid(), 'spam')$$, 'not_found');
select t.throws('R3 a duplicate open report is refused', format($$select public.report_content('book', %L, 'spam')$$, :'b1'), 'already_reported');
select t.ok('R3 another target is fine', public.report_content('profile', :'alice', 'abuse') is not null);
select t.login(:'alice');
select t.throws('R4 you cannot report your own book', format($$select public.report_content('book', %L, 'spam')$$, :'b1'), 'invalid_request');
select t.throws('R4 ...nor yourself', format($$select public.report_content('profile', %L, 'spam')$$, :'alice'), 'invalid_request');
select t.login(:'carol'); select public.report_content('book', :'b3', 'other', repeat('x', 1500));
select t.admin();
select t.eq('R5 a report longer than 1000 characters is cut', (select char_length(details) from public.reports where reporter_id = :'carol' and target_id = :'b3'), 1000);
select id as r_carol_b3 from public.reports where reporter_id = :'carol' and target_id = :'b3' \gset
insert into public.reports (reporter_id, target_type, target_id, reason) select :'eve', 'profile', gen_random_uuid(), 'spam' from generate_series(1, 10);
select t.login(:'eve');
select t.throws('R5 more than 10 reports in 24 hours are refused', format($$select public.report_content('book', %L, 'spam')$$, :'b3'), 'rate_limited');
select t.login(:'gina');
select t.throws('R6 no profile -> cannot report', format($$select public.report_content('book', %L, 'spam')$$, :'b3'), 'profile_required');
select t.login(:'carol');
select t.throws('R6 an unknown reason is rejected', format($$select public.report_content('book', %L, 'nonsense')$$, :'b3'), 'invalid input value for enum');
select t.anon();
select t.throws('R7 anonymous cannot report', format($$select public.report_content('book', %L, 'spam')$$, :'b1'), 'permission denied');
select t.login(:'dave'); select public.block_user(:'alice');
select t.throws('R8 a blocked pair cannot report each other''s profile (it is not found)', format($$select public.report_content('profile', %L, 'spam')$$, :'alice'), 'not_found');
select public.unblock_user(:'alice');

/* ---------- who is a moderator ---------- */
select t.login(:'bob');
select t.eq('M1 an ordinary user is not one', public.am_i_moderator(), false);
select t.throws('M1 and cannot read the queue', $$select * from public.moderation_queue()$$, 'forbidden');
select t.throws('M1 nor resolve', format($$select public.resolve_report(%L, 'dismiss')$$, :'r_bob'), 'forbidden');
select t.throws('M1 nor restore', format($$select public.restore_book(%L)$$, :'b1'), 'forbidden');
select t.throws('M2 nobody can make themselves a moderator through the API', format($$insert into public.moderators (user_id) values (%L)$$, :'bob'), 'permission denied');
select t.throws('M2 the reports table is closed', 'select * from public.reports', 'permission denied');
select t.anon();
select t.throws('M3 anonymous cannot ask', 'select public.am_i_moderator()', 'permission denied');
select t.login(:'mia');
select t.eq('M4 the moderator is recognised', public.am_i_moderator(), true);
select t.eq('M4 sees the open queue', (select count(*) from public.moderation_queue('open', 100, 0) where target_id = :'b1'), 3::bigint);
select t.eq('M4 each row says how many reports that book has', (select max(open_reports) from public.moderation_queue('open', 100, 0) where target_id = :'b1'), 3::bigint);
select t.eq('M4 metadata: title, owner, reporter', (select target_title || '/' || owner_handle || '/' || reporter_handle from public.moderation_queue('open', 100, 0) where target_id = :'b1' and reporter_handle = 'bob'), 'Pirated Copy/alice/bob');

/* ---------- dismiss ---------- */
select public.resolve_report(:'r_bob', 'dismiss', 'not a copy');
select t.eq('D1 the reporter is told it was reviewed', t.types(:'bob'), 'report_resolved:dismissed');
select t.anon();
select t.eq('D1 the book is untouched', (select count(*) from public.books where id = :'b1'), 1::bigint);
select t.login(:'mia');
select t.eq('D2 a handled report moves to the other list', (select resolution from public.moderation_queue('handled', 100, 0) where id = :'r_bob'), 'dismissed');
select t.throws('D2 it cannot be resolved twice', format($$select public.resolve_report(%L, 'dismiss')$$, :'r_bob'), 'not_found');
select t.throws('D2 an unknown action is refused', format($$select public.resolve_report(%L, 'delete')$$, :'r_carol'), 'invalid_request');

/* ---------- takedown ---------- */
select t.admin();
insert into public.notification_prefs (user_id, friend_requests, friend_accepted, new_books) values (:'alice', false, false, false);
select t.login(:'mia');
select public.resolve_report(:'r_carol', 'takedown', 'confirmed');
select t.admin();
select t.eq('T1 the book is now private, unreadable, not downloadable', (select access::text || read_allowed::text || download_allowed::text from public.books where id = :'b1'), 'privatefalsefalse');
select t.eq('T1 and marked removed with the reporter''s reason', (select removed_reason::text from public.books where id = :'b1'), 'illegal');
select t.eq('T1 every open report about that book is settled together', (select status::text || '/' || resolution from public.reports where id = :'r_dave'), 'actioned/removed');
select t.anon();
select t.eq('T2 strangers no longer see it', (select count(*) from public.books where id = :'b1'), 0::bigint);
select t.eq('T2 discovery does not list it', (select count(*) from public.discover_books('Pirated', 10, 0)), 0::bigint);
select t.eq('T3 the owner is told, even with every notice type turned off', t.types(:'alice'), 'content_removed:illegal');
select t.eq('T3 the other reporters are told too', t.types(:'dave') || '|' || t.types(:'carol'), 'report_resolved:removed|report_resolved:removed');
select t.login(:'alice');
select t.eq('T4 the owner can list what was removed', (select title || '/' || reason::text from public.my_removed_books()), 'Pirated Copy/illegal');
select t.login(:'bob');
select t.eq('T4 others cannot', (select count(*) from public.my_removed_books()), 0::bigint);

select t.login(:'alice');
update public.books set access = 'public', read_allowed = true, download_allowed = true where id = :'b1';
select t.admin();
select t.eq('T5 the owner cannot publish it again (the update is overridden)', (select access::text || read_allowed::text || download_allowed::text || (removed_at is not null)::text from public.books where id = :'b1'), 'privatefalsefalsetrue');
select t.login(:'alice');
select t.throws('T5 nor clear the flag', format($$update public.books set removed_at = null where id = %L$$, :'b1'), 'permission denied');
select t.throws('T6 the same file cannot be uploaded again by the owner', $$insert into public.books (owner_id, title, format, file_hash, file_size, access, rights_confirmed_at) values ('11111111-1111-1111-1111-111111111111', 'again', 'epub', repeat('1',64), 10, 'public', now())$$, 'content_removed');
select t.login(:'bob');
select t.throws('T6 ...nor by anyone else', $$insert into public.books (owner_id, title, format, file_hash, file_size, access, rights_confirmed_at) values ('22222222-2222-2222-2222-222222222222', 'again', 'epub', repeat('1',64), 10, 'public', now())$$, 'content_removed');
insert into public.books (owner_id, title, format, file_hash, file_size, access, rights_confirmed_at) values ('22222222-2222-2222-2222-222222222222', 'other', 'epub', repeat('9',64), 10, 'private', now());
select t.eq('T6 a different file is fine', (select count(*) from public.books where owner_id = :'bob'), 1::bigint);

/* ---------- other targets: no automatic takedown ---------- */
select t.login(:'bob');
select public.report_content('shelf', :'s1', 'spam');
select t.admin();
select id as r_profile from public.reports where reporter_id = :'bob' and target_type = 'profile' \gset
select id as r_shelf from public.reports where reporter_id = :'bob' and target_type = 'shelf' \gset
select t.login(:'mia');
select t.throws('O1 takedown applies to books only', format($$select public.resolve_report(%L, 'takedown')$$, :'r_profile'), 'invalid_request');
select public.resolve_report(:'r_profile', 'noted', 'spoke to the user');
select public.resolve_report(:'r_shelf', 'dismiss');
select t.eq('O1 "noted" settles it without touching anything', (select status::text || '/' || resolution || '/' || note from public.moderation_queue('handled', 100, 0) where id = :'r_profile'), 'actioned/noted/spoke to the user');
select t.eq('O1 the reporter hears "noted" and "dismissed"', t.types(:'bob'), 'report_resolved:dismissed,report_resolved:dismissed,report_resolved:noted');
select t.admin();
select t.eq('O2 the shelf is untouched', (select access::text from public.shelves where id = :'s1'), 'public');

/* ---------- restore ---------- */
select t.login(:'bob');
select t.throws('V1 only moderators restore', format($$select public.restore_book(%L)$$, :'b1'), 'forbidden');
select t.login(:'mia');
select t.throws('V1 a book that was not removed cannot be restored', format($$select public.restore_book(%L)$$, :'b3'), 'not_found');
select public.restore_book(:'b1');
select t.admin();
select t.eq('V2 restored: flag cleared but the book stays PRIVATE (the owner decides)', (select (removed_at is null)::text || access::text || read_allowed::text from public.books where id = :'b1'), 'trueprivatefalse');
select t.eq('V2 the owner is told', t.types(:'alice'), 'content_removed:illegal,content_restored');
select t.login(:'alice');
update public.books set access = 'public', read_allowed = true where id = :'b1';
select t.eq('V3 the owner can publish it again', (select access::text from public.books where id = :'b1'), 'public');
select t.login(:'bob');
insert into public.books (owner_id, title, format, file_hash, file_size, access, rights_confirmed_at) values ('22222222-2222-2222-2222-222222222222', 'again', 'epub', repeat('1',64), 10, 'private', now());
select t.eq('V3 and the same file can be uploaded by others again (the blocklist entry is gone)', (select count(*) from public.books where owner_id = :'bob' and title = 'again'), 1::bigint);
select t.login(:'alice');
select t.eq('V3 nothing is listed as removed any more', (select count(*) from public.my_removed_books()), 0::bigint);
select t.admin();
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, coalesce(detail, '') as detail from t.results where not ok order by name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed, count(*) as total from t.results;
rollback;
