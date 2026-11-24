/* =====================================================================================
   0009 — RESET.  DESTRUCTIVE: removes everything that 0001–0008 created (tables, data, functions, policies).
   Why: the app was simplified (no passwords, friends, blocks or privacy modes; shelf = novel, chapters = files),
   so the old schema is replaced by the one in 0010 instead of being patched piece by piece.
   Run it ONCE, then 0010. Your auth users (Google sign-ins) are NOT touched; only the online profiles/books are lost.
   Files already in the storage buckets are NOT deleted by SQL (Supabase forbids it): empty the buckets
   "books" and "covers" from the dashboard (Storage) if you want the space back.
   ===================================================================================== */

drop policy if exists margins_objects_select on storage.objects;
drop policy if exists margins_objects_insert on storage.objects;
drop policy if exists margins_objects_update on storage.objects;
drop policy if exists margins_objects_delete on storage.objects;

drop table if exists
  public.reports, public.moderators, public.notifications, public.notification_prefs,
  public.access_attempts, public.access_grants, public.access_secrets,
  public.subscriptions, public.blocks, public.friendships, public.friend_requests,
  public.shelf_books, public.books, public.series, public.shelves, public.libraries,
  public.reserved_handles, public.profiles
  cascade;

drop schema if exists private cascade;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'am_i_moderator','block_user','cancel_friend_request','change_handle','create_profile','delete_my_account',
        'delete_notifications','discover_books','discover_libraries','finalize_book_upload','handle_available',
        'handle_is_valid','has_access_password','mark_notifications_read','moderation_queue','my_book_hashes',
        'my_notification_prefs','my_notifications','my_relationships','my_removed_books','my_subscriptions',
        'redeem_access_password','remove_access_password','remove_friend','reorder_shelves','report_content',
        'resolve_report','respond_friend_request','restore_book','revoke_access_grants','send_friend_request',
        'set_access_password','set_notification_prefs','touch_updated_at','unblock_user','unread_notification_count',
        'visit_library')
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

drop type if exists
  public.access_mode, public.resource_type, public.subscription_target, public.file_status,
  public.request_status, public.notification_type, public.report_target, public.report_reason, public.report_status
  cascade;
