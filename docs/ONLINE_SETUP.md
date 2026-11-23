# Margins online library — setup and design (stage 1)

**Status: stage 1 of 5.** Reading, Drive sync and everything that existed before are unchanged and work without an account.

| Stage | Content | State |
|---|---|---|
| 1 | Database schema, privacy rules (RLS), tests, Google sign-in → online account, public profile, account deletion | **done in code — needs your Supabase project (below)** |
| 2a | My online library screen: library settings, shelves (create / edit / delete / reorder), privacy per library and shelf (public / password / friends / private / same as library), password set / change / remove / revoke | **done in code — needs your test** |
| 2b | Add books from the device (metadata record + rights confirmation), books inside shelves (add / remove / reorder), per-book privacy, read / download permissions, per-book password | **done in code — needs your test** |
| 3a | File upload to private storage (owner only): bucket + storage policies (`0004_storage.sql`), size verification by the database, upload button / progress / retry in the app, file cleanup on book and account deletion | **done in code — needs migration 0004 on your project + your test** |
| 3b | Visitors: open a library by `@handle`, unlock password-protected library / shelf / book, read (temporary copy) and download (import to the local library); covers; storage policy extended (`0005_visitors.sql`) | **done in code — needs migration 0005 + your test** |
| 3c | Discovery + search of PUBLIC books and libraries (`0006_discovery.sql`, screen «Discover») | **done in code — needs migration 0006 + your test** |
| 4 | Friends, friend requests, blocks and following (libraries / shelves): screen «Friends», buttons on a visited library (`0007_social.sql`) | **done in code — needs migration 0007 + your test** |
| 5 | In-app notifications + preferences, reports, takedown and a moderator screen (`0008_notifications_reports.sql`); **no push** | **done in code — needs migration 0008 + your test** |

## 1. Backend choice: Supabase

* **Postgres + row-level security** lets the privacy rules live next to the data and be tested with SQL.
* **Storage** with private buckets and short-lived signed URLs (stage 3); **Edge Functions** for the few things SQL cannot do (stage 3/5).
* **Google sign-in is reused**: the app already signs in with Google (for Drive). The Google ID token is exchanged for a Supabase session (`POST /auth/v1/token?grant_type=id_token`). No passwords are stored anywhere, and Google already verifies the e-mail, so there is no verification / recovery flow to build.
* No SDK is added: `src/lib/online.ts` uses `fetch`, which keeps the APK small and the code auditable.

## 2. Manual steps (what only you can do)

Labels: **[code]** = already in the repo, **[you]** = you must do it, **[pending]** = a later stage.

1. **[you] Create a Supabase project** — https://supabase.com/dashboard → New project. Pick the region closest to your readers. Save the database password in a password manager (it is never needed by the app).
2. **[you] Apply the database** — Dashboard → SQL Editor → run, in order, the contents of
   `supabase/migrations/0001_tables.sql`, `0002_access_functions.sql`, `0003_security_and_rpcs.sql`.
   (Or with the CLI: `npx supabase link --project-ref <ref>` then `npx supabase db push`.)
3. **[you] Enable Google sign-in** — Authentication → Providers → Google → enable.
   * *Client IDs*: paste the **Web** client ID the app already uses (it is the `webClientId` in `src/lib/auth.ts`). If you also list an Android client ID, put the Web one first, comma-separated.
   * The *client secret* is only needed for browser (OAuth redirect) logins, which this app does not use; leave it empty or fill it if the form insists.
   * If sign-in fails with a message about **nonce**, turn on **"Skip nonce checks"** on that same screen (native Google sign-in on Android does not always provide a nonce).
4. **[you] Turn off what you do not use** — Authentication → Providers: disable Email sign-ups (so nobody can create password accounts), and keep "Allow new users to sign up" on. Authentication → Rate limits: keep the defaults.
5. **[you] Give the build the public settings** — GitHub repo → Settings → Secrets and variables → Actions → **Variables** tab:
   * `SUPABASE_URL` = Project Settings → API → *Project URL*
   * `SUPABASE_ANON_KEY` = Project Settings → API → *anon public* key
   These are public values (they end up inside the APK). **Never** use the `service_role` key anywhere in this repo. For local development copy `.env.example` to `.env.local`.
6. **[you] Build and install the new APK**, open *Account*, sign in with Google. Because the Google sign-in must happen once more to get an online session, users who were already signed in see a **Reconnect** button.
7. **[you] Verify** (about 5 minutes):
   * Create a profile → the row appears in Table Editor → `profiles` (and an empty private `libraries` row).
   * In the SQL Editor run `select * from pg_policies where schemaname='public';` → every table has policies; `select tablename from pg_tables where schemaname='public' and not rowsecurity;` → must return **no rows**.
   * Delete the online account from the app → both rows disappear.
8. **[you, stage 3a]** Run `supabase/migrations/0004_storage.sql` in the SQL Editor (New query → paste → Run). It creates the private `books` and `covers` buckets and the storage policies. Check Storage → Buckets: both must appear and be **Private**. No Edge Function is needed for 3a (verification is a database function).
   *Limits:* the free plan allows 50 MB per file and 1 GB of storage in total; the app refuses bigger files. Raise `file_size_limit` in the migration on a paid plan.
8b. **[you, stage 3b]** Run `supabase/migrations/0005_visitors.sql` in the SQL Editor (after 0004). It replaces the storage SELECT policy (owner **or** an allowed visitor) and adds `visit_library(handle)`. No Edge Function, no new secret, no dashboard setting.
8c. **[you, stage 3c]** Run `supabase/migrations/0006_discovery.sql` in the SQL Editor (after 0005). It only adds two read-only functions (`discover_books`, `discover_libraries`) and one private helper; no table, bucket, secret or dashboard setting. Then in the app: Online → «Discover» (also reachable from Account): the list shows books/libraries that are public, search by title, author, owner name/handle or library title. A book that is private / friends-only / password-protected / still uploading must NOT appear, even for you when signed in as someone else.
8d. **[you, stage 4]** Run `supabase/migrations/0007_social.sql` in the SQL Editor (after 0006). Two read-only functions (`my_relationships`, `my_subscriptions`); no table, secret or dashboard setting. Test with TWO Google accounts (A and B, both with a profile): A: Online → Friends → find `@b` → Add friend. B: Friends → Requests → Accept. Then A makes a library friends-only: B must see it, a third account must not. Then A blocks B: B must get «not found» when opening `@a`, and A must see B under Blocked and be able to unblock.
8e. **[you, stage 5]** Run `supabase/migrations/0008_notifications_reports.sql` in the SQL Editor (after 0007). It adds tables (notifications, preferences, reports, moderators), triggers and RPCs; no secret and no dashboard setting. **Make yourself a moderator** (there is deliberately no way to do this from the app): in the SQL Editor run `insert into public.moderators (user_id) select id from public.profiles where handle = 'YOUR_HANDLE';` then reopen the app: Account shows «Moderation». Test with two accounts A (owner) and B: B follows A's library; A uploads a public book: B must get a «new book» notification (open Online → Notifications). B reports A's book (flag icon on the book row in A's library). You (moderator) open Moderation, remove the book: A must be notified and see it under «Removed by moderators», it must disappear for everyone else, A must be unable to make it public again, and uploading the same file again must fail. Restore it from the «Handled» tab: it comes back PRIVATE.
9. **[pending]** Android push (Firebase Cloud Messaging credentials). Until then notifications will be in-app only; this will not be presented as push.

**Costs / limits to verify yourself** (they change; I cannot check them from here): Supabase free-tier database size, storage size, egress, monthly active users, and the rule that free projects are paused after a period of inactivity. Check https://supabase.com/pricing before inviting users. Books are up to 150 MB each (enforced by a database constraint), which is the quota most likely to matter.

## 3. Data model

```
profiles(id = auth user)     handle (unique, lowercase), display_name, bio            — public
libraries(owner)             title, description, default_access (never 'inherit')     — one per user, private by default
shelves(library, owner)      name, description, position, access ('inherit' | mode)
books(owner)                 metadata, series, format, file_status, access, read_allowed, download_allowed,
                             license/origin, rights_confirmed_at, file_hash (never selectable)
shelf_books(shelf, book)     many-to-many: one file record, any number of shelves (owner enforced by composite FKs)
series(owner, key)           normalised identity: "Dune  Saga " == "dune saga" for one owner
friend_requests / friendships(user_a < user_b) / blocks
subscriptions(subscriber, target_type = user|library|shelf|series, target_id, muted)
access_secrets / access_grants / access_attempts       — password protection, no client privileges at all
```

* **No storage path is stored.** Files will live at `books/<owner>/<book>.<ext>` and covers at `covers/<owner>/<book>.jpg`; the storage policy derives the book id from the path and calls the same permission function, so there is nothing to leak.
* Local books and online books are different things: nothing is uploaded unless the owner publishes that book (stage 3, with a rights confirmation, which the database requires: `rights_confirmed_at NOT NULL`).

## 4. The privacy rules (implemented once, in `0002_access_functions.sql`)

Modes, from loosest to strictest: **public → password → friends → private**.

1. A library has a default mode (private unless changed). A shelf either has its own mode or inherits the library's.
2. A book with its **own** mode uses it. An explicit choice is never loosened by a parent.
3. A book that **inherits** gets the **most restrictive** mode among all shelves it sits on (or the library default if it is on no shelf). *So a book on a public shelf and a private shelf is private.* This is the multi-shelf rule; it is tested.
4. The owner sees everything of theirs. A **block** hides everything in both directions, even public content, and removes friendships, subscriptions and password grants between the two.
5. Other people never see a book whose file is not `ready` (the backend, not the client, sets that after validating the upload).
6. Metadata visibility and file access are separate: reading / downloading the file additionally requires `read_allowed` / `download_allowed`, both **off** by default. "Public but not downloadable" is therefore possible.
7. A shelf membership row is visible only if **both** the shelf and the book are visible, so a private book never shows up inside a public shelf, nor in counts.
8. **Password mode**: the content is invisible (and unsearchable) until the visitor calls `redeem_access_password`. That function is the only way to get a grant; it checks a bcrypt hash, always answers just true/false (unknown resource, wrong password, no password, blocked and locked-out are indistinguishable), locks out after 5 failures / 15 min per resource or 20 / hour per user, and issues a grant valid 24 h that **dies when the password is changed** or when the owner revokes grants. Visitors must be signed in. Plain passwords are never stored.
9. **Friends-only** uses accepted friendships only. Pending requests, followers and blocked users do not count. Removing a friend or blocking revokes access immediately (decisions are computed live, never cached).

Security design choices:
* All helper functions live in a `private` schema that the API does not expose, so nobody can call e.g. `are_friends(a, b)` to probe relationships. Clients can only call the listed RPCs.
* Tables have least-privilege **column** grants (e.g. `file_status`, `file_hash` cannot be set or read by clients; a user cannot change their own handle by a plain UPDATE, only through `change_handle`, once every 30 days).
* Relationship, secret, grant and attempt tables cannot be written by clients; only RPCs change them, with validation (no self-requests, no duplicates, 7-day cool-down after a rejection, 20 requests / hour, blocked users get the same `not_found` as non-existent ones).
* Quotas by trigger: 200 shelves, 2000 books, 1000 subscriptions per user.
* Account deletion cascades through every table. **Stored files** are removed by a delete-account Edge Function in stage 3 (nothing is stored yet, so nothing is orphaned today).

## 5. Tests

```bash
# database privacy suite — 133 checks + 28 storage + 63 visitor + 58 discovery + 34 social + 47 notification + 55 moderation checks on a throwaway local Postgres (>= 15)
PGHOST=/path/to/socket PGPORT=5432 PGUSER=postgres npm run test:db
# client logic (handle rules, token exchange, refresh, error mapping)
npm test          # needs bun: https://bun.sh
npm run typecheck && npm run build
```

`supabase/tests/00_mock_supabase.sql` fakes the few Supabase pieces (roles, `auth.uid()`) for plain Postgres; never run it on a real project. Covered: strangers and anonymous users cannot see private libraries / shelves / books (by id, listing, full-text, counts), column-level secrecy, shelf and book overrides in both directions, multi-shelf leak, read/download flags, pending uploads, password flow (redeem, wrong, lock-out, rotation, revoke, removal, hash only), friends-only (request → accept → remove → block → unblock, cool-down, duplicates), subscriptions only to visible targets, write isolation between users, and account deletion cascades. I also broke two rules on purpose to confirm the suite fails when it should.

## 6. What is NOT done / known limits (honest list)

* Stages 4–5 above: (old note, kept for the history of 2b) no file upload yet (books added in 2b are metadata records with `file_status = pending`, visible only to you), no upload, no discovery, no friends UI, no notifications, no reports/takedown. The database already contains the tables and RPCs for friends, blocks, subscriptions and password access, but no screen uses them yet.
* Tests that need a real Supabase (storage policies, Edge Functions, real Google sign-in) cannot exist until stages 3 and a project exist. The Google → Supabase token exchange is covered only against a mocked server; **it has not been run against your project** — step 7 above is how you verify it.
* `npm run typecheck` and `npm run build` could not be run where this was written (no package installation). Only the new files were type-checked, against stubs for the third-party packages. Run both before releasing.
* The Supabase session is stored in `localStorage` (like the Google account already is). On a rooted device or in a compromised WebView it is readable; tokens are short-lived (refresh tokens are rotated by Supabase).
* A user who deletes their online account must sign in with Google again to create a new one.

* Stage 2a UI was type-checked only in isolation (react/lucide stubbed) and its data layer tested against a mocked server; the whole app has not been built here (no network). Reorder uses up/down buttons, not drag and drop.

* Stage 2b: the book's hash is the local SHA-256 (recomputed from the file if the stored one is not a valid hash). Adding the same file twice is rejected by the database (`duplicate`). Book records are created with the owner's rights confirmation timestamp; nothing is shared until stage 3 sets `file_status = ready`.

* Stage 3a: tested against a mock of Supabase Storage (the `storage.objects` table and RLS), not against a real Storage server. The one assumption to verify on your project: after an upload, `storage.objects.metadata->>'size'` holds the byte size (it does on current Supabase) — `finalize_book_upload` relies on it. If a book stays «failed» after upload, this is the first thing to check.
* Stage 3a: deleting the stored files is done by the app (best effort) before deleting a book or the account; if the network drops in between, orphan files can remain until stage 5 adds a server-side clean-up. A published file cannot be replaced (delete the book record and add it again).

* Stage 3b design: (1) **No signed links.** The app downloads with the visitor's own session token through `GET /storage/v1/object/authenticated/...`; the storage policy (`private.object_readable`, which calls the same `can_read_book_file` / `can_download_book_file` / `can_view_book` as the table rules) is evaluated on every request, so there is no URL that can be forwarded or that outlives a changed password or privacy setting. (2) **Files need a signed-in visitor** (anonymous visitors can still browse public libraries and see book metadata, not fetch files). (3) `visit_library` is the one entry point: unknown handle and blocked user both answer `not_found`; a locked library / shelf / book shows only its id (never its name, title or count); a shelf that merely inherits a locked library is not listed separately; a password that was never set is shown as unavailable, not as lockable.
* Stage 3b limits you should know: **"read only" is not copy protection.** A visitor allowed to read receives the file bytes, so a technically skilled person could keep them; `read_allowed` without `download_allowed` only removes the in-app save button and keeps the copy temporary. If a book must never leave your device, do not publish it. A book opened with "Read" is deleted from the visitor's device when the reader closes (record, bookmarks and notes included) and any leftover is removed at the next app start; if the visitor already owns the same file, her own copy opens instead. Unlocking a password needs the visitor to have an online profile (the grant table references profiles): without one the app says so. The size of a download is checked against the size the owner declared; the hash cannot be checked (it is never exposed to others). Tested: 63 SQL checks on the mock Storage plus 10 client tests; **not** tested against a real Supabase Storage server, and the new screen was type-checked only against stubs (see above).

* Stage 3c design: **public only.** `discover_books` / `discover_libraries` use `private.can_view_book(book, NULL)` / `can_view_library(library, NULL)`, i.e. exactly what a signed-out stranger can already read, so a friend or a password holder does not see friends-only / password books in Discover (they find them by visiting the library). Blocks hide in both directions for signed-in viewers. Nothing beyond what the tables already show is returned (no hash, no storage path). Search is a case-insensitive substring match on every word (max 6 words, 40 characters each, LIKE wildcards escaped), pages of 30, newest books first, libraries ordered by number of public books. A public library with no public book is not listed; a book that is public by its own setting inside a private library is listed (the same rule the row-level security already applied to anyone browsing by id).
* Stage 3c limits: (1) the search scans with `ILIKE`; fine for thousands of books, for far more add a `pg_trgm` index in a new migration. (2) Anyone, signed out included, can page through everything public: that is what «public» means, but scraping is possible; there is no per-IP rate limit beyond what Supabase applies. (3) The bundled 58 SQL checks run on a plain Postgres 16 with the mock; **not** run against a real Supabase project. Typecheck still reports 11 type errors in `pdf.ts`, `PdfView.tsx`, `EpubView.tsx`, `ReflowView.tsx`, which predate 3c and are unrelated to it (the build and all tests pass).

* Stage 4 design: the write side was already in 0003 (and tested): `send_friend_request`, `respond_friend_request`, `cancel_friend_request`, `remove_friend`, `block_user`, `unblock_user`, and INSERT / UPDATE(muted) / DELETE on `subscriptions` under row-level security (a subscription is accepted only for something the user can see). 0007 only adds what the screens must READ: (1) `my_relationships()`: friends, open requests both ways and the people I blocked. It exists because `profiles_read` hides a blocked person from the blocker too, so the table alone cannot list them. (2) `my_subscriptions()`: names resolved; the title of a library / shelf is returned only while the viewer may still see it (a library that became private shows as «no longer available», never its title). Both answer about the caller only; anonymous callers are refused. Blocking, as before, removes the friendship, cancels open requests, deletes subscriptions and password access in both directions. A blocked person is «not found» when searched by handle.
* Stage 4 limits: (1) **Following does not notify anyone yet**: it only records interest, lets you mute and unfollow, and the screen says so (notifications are stage 5). (2) The screens can follow a library or a shelf; the database also supports following a person or a series, but there is no button for them. (3) There is no friend search other than the exact `@handle`, by design (no people directory). (4) Friend request rules enforced by the server: 7-day wait after a decline, at most 20 requests per hour and 100 open. (5) The lists are cached per session and re-read after every action and whenever the screens open; two devices of the same user see each other's changes after the next refresh, not instantly. (6) 34 SQL checks (3 deliberate rule-breaks confirmed they fail) and 12 client tests; **not** run against a real Supabase project, and the screens were not exercised in a real device or browser, only built and type-checked.

* Stage 5 design: **notifications are rows the app reads when opened; nothing is pushed.** They are written only by database triggers (a client cannot write one): friend request received, request accepted, new book from something you follow, your book removed / restored, your report reviewed. Rules: a blocked pair gets nothing (also hidden at read time if the block came later); your three preferences (requests, accepted, new books) are honoured; a «new book» notice goes only to a follower who can see that book right now and has not muted the follow, once per book however many follows match; a request notice disappears when the request is answered or cancelled; an inbox keeps the newest 200. Removal notices to the owner ignore preferences. The unread badge is refreshed when the app screens open, not in the background.
* Stage 5 reports: a report is accepted only for something the reporter can SEE (so reports cannot probe hidden items), never for your own content, at most 10 per 24 hours, one open report per person per item. Targets: book, library, shelf, profile. **Takedown works only for books**: the book is forced private with read and download off and flagged removed, its file hash goes on a blocklist (the same file cannot be uploaded again by anyone), the owner is notified, and all open reports about the same book are settled. A client update cannot undo it (a trigger overrides it); only a moderator's «Restore» can, and a restored book stays private. For libraries, shelves and profiles a moderator can only dismiss or mark «handled»: there is **no automatic suspension of accounts**.
* Stage 5 limits: (1) **no push** (Firebase is not set up) and no background polling. (2) A report form is not a legal process: there is no counter-notice or appeal flow, no email to the rights holder, no log of who restored what beyond the report row. If you operate this for real users you need a published takedown contact and a policy; I did not write those. (3) Moderators see the TITLES, owners, reasons and details of reported items (including private ones) but never files. (4) A book that becomes visible because a whole library or shelf is made public does not notify followers (only the book's own publish / access change / being added to a followed shelf does). (5) Hash blocklist = exact file only; a re-encoded copy is a different file. (6) The new screens and triggers were verified on a plain Postgres 16 with the mock (47 + 55 checks; 8 deliberate rule-breaks confirmed they fail), 77 client tests, build and type-check, but **not** on a real Supabase project or a real device.
