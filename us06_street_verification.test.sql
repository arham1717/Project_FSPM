-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- Fixtures (as superuser) --------------------------------------------------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'ayesha@test.dev'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'bilal@test.dev');

insert into public.profiles (id, display_name, home_location) values
  -- Ayesha lives ~60 m from the report
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Ayesha',
   extensions.ST_SetSRID(extensions.ST_MakePoint(74.3591, 31.5208), 4326)::extensions.geography),
  -- Bilal lives ~2 km away
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Bilal',
   extensions.ST_SetSRID(extensions.ST_MakePoint(74.3787, 31.5204), 4326)::extensions.geography);

insert into public.reports (id, author_id, title, category, location) values
  ('cccccccc-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Pothole', 'roads',
   extensions.ST_SetSRID(extensions.ST_MakePoint(74.3587, 31.5204), 4326)::extensions.geography);

set local role authenticated;

-- Ayesha (home within radius) ---------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);

select is(
  (select is_street_resident from public.add_comment(
     'cccccccc-0000-0000-0000-000000000003', 'Been here for weeks')),
  true, 'home within radius => badge on comment');

select is(
  (select is_street_resident from public.verify_report(
     'cccccccc-0000-0000-0000-000000000003')),
  true, 'home within radius => badge on verification');

select is(
  (select verification_count from public.reports
    where id = 'cccccccc-0000-0000-0000-000000000003'),
  1, 'verification_count incremented');

select throws_ok(
  $$select public.verify_report('cccccccc-0000-0000-0000-000000000003')$$,
  '23505', null, 'cannot verify the same report twice');

-- Bilal (home far away) -----------------------------------------------------
select set_config('request.jwt.claims',
  '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}', true);

select is(
  (select is_street_resident from public.add_comment(
     'cccccccc-0000-0000-0000-000000000003', 'Looks bad from afar')),
  false, 'home far away, no GPS => no badge');

select is(
  (select is_street_resident from public.add_comment(
     'cccccccc-0000-0000-0000-000000000003', 'I am actually here now',
     31.5205, 74.3588)),
  true, 'live GPS within radius => badge');

select throws_ok(
  $$select public.add_comment('cccccccc-0000-0000-0000-000000000003', 'x', 123.0, 74.0)$$,
  '22023', null, 'invalid coordinates rejected');

-- Clients cannot forge the badge by writing directly ------------------------
select throws_ok(
  $$insert into public.comments (report_id, author_id, body, is_street_resident, resident_basis)
    values ('cccccccc-0000-0000-0000-000000000003',
            'bbbbbbbb-0000-0000-0000-000000000002', 'forged', true, 'home')$$,
  '42501', null, 'direct insert is denied');

select * from finish();
rollback;
