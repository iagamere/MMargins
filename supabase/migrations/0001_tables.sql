-- Margins online library — tables only (functions, RLS and RPCs live in 0002 / 0003).
-- Design rules:
--   * every table has RLS enabled in 0003; the app never uses the service-role key
--   * no storage paths are stored: files live at  books/<owner_id>/<book_id>.<ext>  and
--     covers at covers/<owner_id>/<book_id>.jpg , so there is nothing to leak
--   * passwords are bcrypt hashes in a table that no client role can read

create extension if not exists pgcrypto with schema extensions;

create type public.access_mode as enum ('inherit', 'public', 'password', 'friends', 'private');
create type public.resource_type as enum ('library', 'shelf', 'book');
create type public.subscription_target as enum ('user', 'library', 'shelf', 'series');
create type public.file_status as enum ('pending', 'ready', 'failed');
create type public.request_status as enum ('pending', 'accepted', 'rejected', 'cancelled');

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

/* ------------------------------------------------------------------ profiles */
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  handle text not null,
  display_name text not null,
  bio text not null default '',
  handle_changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_handle_format check (
    handle ~ '^[a-z0-9][a-z0-9_.]{1,28}[a-z0-9]$' and handle !~ '[_.]{2}'
  ),
  constraint profiles_display_name_len check (char_length(btrim(display_name)) between 1 and 60),
  constraint profiles_bio_len check (char_length(bio) <= 300)
);
create unique index profiles_handle_key on public.profiles (handle);
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

create table public.reserved_handles (handle text primary key);
insert into public.reserved_handles (handle) values
  ('admin'), ('administrator'), ('root'), ('support'), ('help'), ('margins'), ('margin'), ('moderator'),
  ('mod'), ('official'), ('security'), ('staff'), ('system'), ('null'), ('undefined'), ('anonymous'),
  ('me'), ('you'), ('api'), ('www'), ('settings'), ('account'), ('library'), ('shelf'), ('book'), ('discover');

/* ----------------------------------------------------------------- libraries */
create table public.libraries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references public.profiles (id) on delete cascade,
  title text not null default '',
  description text not null default '',
  has_cover boolean not null default false,
  -- library-level DEFAULT policy. Private unless the owner decides otherwise.
  default_access public.access_mode not null default 'private',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  constraint libraries_default_not_inherit check (default_access <> 'inherit'),
  constraint libraries_title_len check (char_length(title) <= 80),
  constraint libraries_description_len check (char_length(description) <= 500)
);
create trigger libraries_touch before update on public.libraries for each row execute function public.touch_updated_at();

/* ------------------------------------------------------------------- shelves */
create table public.shelves (
  id uuid primary key default gen_random_uuid(),
  library_id uuid not null,
  owner_id uuid not null,
  name text not null,
  description text not null default '',
  has_cover boolean not null default false,
  position integer not null default 0,
  access public.access_mode not null default 'inherit',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  foreign key (library_id, owner_id) references public.libraries (id, owner_id) on delete cascade,
  constraint shelves_name_len check (char_length(btrim(name)) between 1 and 80),
  constraint shelves_description_len check (char_length(description) <= 500)
);
create index shelves_owner_position on public.shelves (owner_id, position);
create trigger shelves_touch before update on public.shelves for each row execute function public.touch_updated_at();

/* -------------------------------------------------------------------- series */
create table public.series (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  -- normalised identity: "Harry  Potter " and "harry potter" are the same series of one owner
  key text generated always as (lower(regexp_replace(btrim(title), '\s+', ' ', 'g'))) stored,
  created_at timestamptz not null default now(),
  unique (id, owner_id),
  unique (owner_id, key),
  constraint series_title_len check (char_length(btrim(title)) between 1 and 120)
);

/* --------------------------------------------------------------------- books */
create table public.books (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  author text not null default '',
  description text not null default '',
  language text,
  tags text[] not null default '{}',
  series_id uuid,
  series_position numeric(8, 2),
  format text not null,
  file_hash text not null,               -- sha256 of the file: never shown to other users
  file_size bigint not null,
  file_status public.file_status not null default 'pending',  -- only the backend sets 'ready'
  has_cover boolean not null default false,
  access public.access_mode not null default 'inherit',
  -- visitors may only read / download when the owner switched these on explicitly
  read_allowed boolean not null default false,
  download_allowed boolean not null default false,
  license text,
  origin text,
  rights_confirmed_at timestamptz not null,   -- the owner confirmed they may share this file
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  unique (owner_id, file_hash),
  foreign key (series_id, owner_id) references public.series (id, owner_id) on delete set null (series_id),
  constraint books_format check (format in ('epub', 'pdf')),
  constraint books_hash check (file_hash ~ '^[0-9a-f]{64}$'),
  constraint books_size check (file_size > 0 and file_size <= 157286400),   -- 150 MB
  constraint books_title_len check (char_length(btrim(title)) between 1 and 300),
  constraint books_author_len check (char_length(author) <= 300),
  constraint books_description_len check (char_length(description) <= 4000),
  constraint books_tags check (cardinality(tags) <= 20),
  constraint books_license_len check (char_length(coalesce(license, '')) <= 200 and char_length(coalesce(origin, '')) <= 300)
);
create index books_owner on public.books (owner_id);
create index books_series on public.books (series_id) where series_id is not null;
create index books_title_search on public.books using gin (to_tsvector('simple', title || ' ' || author));
create trigger books_touch before update on public.books for each row execute function public.touch_updated_at();

/* --------------------------------------------------------------- shelf_books */
create table public.shelf_books (
  shelf_id uuid not null,
  book_id uuid not null,
  owner_id uuid not null,
  position integer not null default 0,
  added_at timestamptz not null default now(),
  primary key (shelf_id, book_id),
  foreign key (shelf_id, owner_id) references public.shelves (id, owner_id) on delete cascade,
  foreign key (book_id, owner_id) references public.books (id, owner_id) on delete cascade
);
create index shelf_books_book on public.shelf_books (book_id);

/* ------------------------------------------------------------- relationships */
create table public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  status public.request_status not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_not_self check (requester_id <> recipient_id)
);
-- at most one open request per pair, whichever direction
create unique index friend_requests_one_pending on public.friend_requests
  (least(requester_id, recipient_id), greatest(requester_id, recipient_id)) where status = 'pending';
create index friend_requests_recipient on public.friend_requests (recipient_id, status);
create index friend_requests_requester on public.friend_requests (requester_id, created_at);

create table public.friendships (
  user_a uuid not null references public.profiles (id) on delete cascade,
  user_b uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  constraint friendships_ordered check (user_a < user_b)   -- one row per pair
);
create index friendships_b on public.friendships (user_b);

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_not_self check (blocker_id <> blocked_id)
);
create index blocks_blocked on public.blocks (blocked_id);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  subscriber_id uuid not null references public.profiles (id) on delete cascade,
  target_type public.subscription_target not null,
  target_id uuid not null,
  muted boolean not null default false,
  created_at timestamptz not null default now(),
  unique (subscriber_id, target_type, target_id)
);
create index subscriptions_target on public.subscriptions (target_type, target_id);

/* ------------------------------------------------------ password-protected access */
create table public.access_secrets (
  resource_type public.resource_type not null,
  resource_id uuid not null,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  password_hash text not null,
  version integer not null default 1,      -- bumping it revokes every earlier grant
  updated_at timestamptz not null default now(),
  primary key (resource_type, resource_id)
);

create table public.access_grants (
  user_id uuid not null references public.profiles (id) on delete cascade,
  resource_type public.resource_type not null,
  resource_id uuid not null,
  version integer not null,
  granted_at timestamptz not null default now(),
  expires_at timestamptz not null,
  primary key (user_id, resource_type, resource_id)
);

create table public.access_attempts (   -- failed password attempts, for brute-force protection
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  resource_id uuid not null,
  at timestamptz not null default now()
);
create index access_attempts_user on public.access_attempts (user_id, at);
create index access_attempts_resource on public.access_attempts (user_id, resource_id, at);
