-- =============================================================================
-- US-06  Street Radius Verification
-- "As a local resident, I want the system to auto-verify my proximity to a
--  report so that only street residents get local verification badges."
--
-- Acceptance criteria
--   1. System compares report location against the user's registered home
--      street OR live GPS.
--   2. Adds a "Verified Street Resident" badge on upvotes and comments.
--
-- Design
--   * The badge is computed SERVER-SIDE at write time and stored as a snapshot
--     (is_street_resident). Clients can never set it: direct INSERTs on
--     comments / report_verifications are revoked; writes go through the
--     SECURITY DEFINER RPCs add_comment() and verify_report().
--   * Home location is checked first (more trustworthy), live GPS second.
--   * "Same street" is approximated by a radius (street_radius_m(), 150 m).
--   * profiles.home_location is private. Public author names are exposed
--     through views that never include coordinates.
--
-- Dependencies: US-01 (Supabase Auth), US-02 (profiles.home_location),
-- US-03 (reports), US-04 (comments), US-07 (verifications).
-- Minimal versions of those tables are created here with IF NOT EXISTS so this
-- migration runs standalone; merge with your teammates' definitions as needed.
-- =============================================================================

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------------
-- Minimal supporting tables
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text,
  home_location extensions.geography(Point, 4326),
  created_at    timestamptz not null default now()
);

create table if not exists public.reports (
  id                 uuid primary key default gen_random_uuid(),
  author_id          uuid not null references public.profiles (id),
  title              text not null,
  category           text not null,
  description        text,
  photo_url          text,
  location           extensions.geography(Point, 4326) not null,
  status             text not null default 'unverified',
  verification_count integer not null default 0,
  created_at         timestamptz not null default now()
);
create index if not exists reports_location_gix
  on public.reports using gist (location);

create table if not exists public.comments (
  id                 uuid primary key default gen_random_uuid(),
  report_id          uuid not null references public.reports (id) on delete cascade,
  author_id          uuid not null references public.profiles (id),
  body               text not null check (char_length(body) between 1 and 2000),
  created_at         timestamptz not null default now(),
  is_street_resident boolean not null default false,
  resident_basis     text check (resident_basis in ('home', 'gps')),
  check (is_street_resident = (resident_basis is not null))
);
create index if not exists comments_report_idx
  on public.comments (report_id, created_at);

create table if not exists public.report_verifications (
  report_id          uuid not null references public.reports (id) on delete cascade,
  user_id            uuid not null references public.profiles (id),
  created_at         timestamptz not null default now(),
  is_street_resident boolean not null default false,
  resident_basis     text check (resident_basis in ('home', 'gps')),
  primary key (report_id, user_id),
  check (is_street_resident = (resident_basis is not null))
);

-- If teammates already created these tables, make sure the US-06 columns exist.
alter table public.comments
  add column if not exists is_street_resident boolean not null default false,
  add column if not exists resident_basis text;
alter table public.report_verifications
  add column if not exists is_street_resident boolean not null default false,
  add column if not exists resident_basis text;

-- ---------------------------------------------------------------------------
-- Configuration: what counts as "your street"
-- ---------------------------------------------------------------------------
create or replace function public.street_radius_m()
returns integer
language sql
immutable
as $$ select 150 $$;

-- ---------------------------------------------------------------------------
-- Core check. Returns 'home', 'gps', or NULL (not a street resident).
-- Internal only: callable by the RPCs below, not by clients.
-- ---------------------------------------------------------------------------
create or replace function public.check_street_residency(
  p_report_id uuid,
  p_user_id   uuid,
  p_lat       double precision default null,
  p_lng       double precision default null
)
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_report geography;
  v_home   geography;
  v_radius integer := public.street_radius_m();
begin
  select location into v_report from public.reports where id = p_report_id;
  if v_report is null then
    raise exception 'report not found' using errcode = 'P0002';
  end if;

  -- 1) Registered home location
  select home_location into v_home from public.profiles where id = p_user_id;
  if v_home is not null and ST_DWithin(v_report, v_home, v_radius) then
    return 'home';
  end if;

  -- 2) Live GPS (client-reported)
  if p_lat is not null and p_lng is not null then
    if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
      raise exception 'invalid coordinates' using errcode = '22023';
    end if;
    if ST_DWithin(
         v_report,
         ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
         v_radius
       ) then
      return 'gps';
    end if;
  end if;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: post a comment (US-04 write path, now badge-aware)
-- ---------------------------------------------------------------------------
create or replace function public.add_comment(
  p_report_id uuid,
  p_body      text,
  p_lat       double precision default null,
  p_lng       double precision default null
)
returns public.comments
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_basis text;
  v_row   public.comments;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  v_basis := public.check_street_residency(p_report_id, v_uid, p_lat, p_lng);

  insert into public.comments (report_id, author_id, body, is_street_resident, resident_basis)
  values (p_report_id, v_uid, p_body, v_basis is not null, v_basis)
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: verify / upvote a report (US-07 write path, now badge-aware)
-- A second verification by the same user raises unique_violation (23505).
-- ---------------------------------------------------------------------------
create or replace function public.verify_report(
  p_report_id uuid,
  p_lat       double precision default null,
  p_lng       double precision default null
)
returns public.report_verifications
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_basis text;
  v_row   public.report_verifications;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  v_basis := public.check_street_residency(p_report_id, v_uid, p_lat, p_lng);

  insert into public.report_verifications (report_id, user_id, is_street_resident, resident_basis)
  values (p_report_id, v_uid, v_basis is not null, v_basis)
  returning * into v_row;

  update public.reports
     set verification_count = verification_count + 1
   where id = p_report_id;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public read views (author names + badge, never coordinates)
-- ---------------------------------------------------------------------------
create or replace view public.comments_feed as
select c.id,
       c.report_id,
       c.author_id,
       p.display_name as author_name,
       c.body,
       c.created_at,
       c.is_street_resident
from public.comments c
join public.profiles p on p.id = c.author_id;

create or replace view public.verifications_feed as
select v.report_id,
       v.user_id,
       p.display_name as user_name,
       v.created_at,
       v.is_street_resident
from public.report_verifications v
join public.profiles p on p.id = v.user_id;

-- ---------------------------------------------------------------------------
-- Row Level Security + grants
-- ---------------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.reports              enable row level security;
alter table public.comments             enable row level security;
alter table public.report_verifications enable row level security;

drop policy if exists "profiles read own"   on public.profiles;
drop policy if exists "profiles insert own" on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles read own"   on public.profiles for select to authenticated
  using (id = auth.uid());
create policy "profiles insert own" on public.profiles for insert to authenticated
  with check (id = auth.uid());
create policy "profiles update own" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "reports read"       on public.reports;
drop policy if exists "comments read"      on public.comments;
drop policy if exists "verifications read" on public.report_verifications;
create policy "reports read"       on public.reports for select to authenticated using (true);
create policy "comments read"      on public.comments for select to authenticated using (true);
create policy "verifications read" on public.report_verifications for select to authenticated using (true);

-- The badge flag must never be client-writable: all writes go through the RPCs.
revoke insert, update, delete on public.comments             from anon, authenticated;
revoke insert, update, delete on public.report_verifications from anon, authenticated;

revoke all on function public.check_street_residency(uuid, uuid, double precision, double precision)
  from public, anon, authenticated;
revoke all on function public.add_comment(uuid, text, double precision, double precision)
  from public, anon;
revoke all on function public.verify_report(uuid, double precision, double precision)
  from public, anon;
grant execute on function public.add_comment(uuid, text, double precision, double precision)
  to authenticated;
grant execute on function public.verify_report(uuid, double precision, double precision)
  to authenticated;

revoke all on public.comments_feed, public.verifications_feed from anon;
grant select on public.comments_feed, public.verifications_feed to authenticated;
