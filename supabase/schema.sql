-- TVET MARA Staff App
-- Complete Supabase setup
-- Run this file in the Supabase SQL Editor.
-- It is safe to run again on an existing project.

create extension if not exists "pgcrypto";
create extension if not exists "postgis";

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------

do $$ begin
  create type staff_role as enum ('staff', 'admin');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type attendance_status as enum ('present', 'late', 'absent', 'leave');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type leave_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type leave_type as enum ('annual', 'sick', 'emergency', 'unpaid', 'maternity');
exception when duplicate_object then null;
end $$;

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

create table if not exists public.departments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  code       text unique,
  created_at timestamptz not null default now()
);

create table if not exists public.staff (
  id                uuid primary key references auth.users(id) on delete cascade,
  full_name         text not null,
  staff_number      text unique not null,
  email             text unique not null,
  ic_number         text not null default '000000-00-0000',
  role              staff_role not null default 'staff',
  department_id     uuid references public.departments(id) on delete set null,
  position          text,
  staff_grade       text not null default 'DG9',
  employment_status text not null default 'TETAP',
  teaching_course   text not null default 'General',
  campus            text,
  base_salary       numeric(10, 2),
  hire_date         date,
  is_active         boolean not null default true,
  last_seen         timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint staff_employment_status_check
    check (employment_status in ('TETAP', 'KONTRAK'))
);

create table if not exists public.geofence_zones (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  center_lat double precision not null,
  center_lng double precision not null,
  radius_m   integer not null default 200,
  polygon    geography(polygon, 4326),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.attendance (
  id              uuid primary key default gen_random_uuid(),
  staff_id        uuid not null references public.staff(id) on delete cascade,
  punch_in        timestamptz not null default now(),
  punch_out       timestamptz,
  punch_in_lat    double precision,
  punch_in_lng    double precision,
  punch_out_lat   double precision,
  punch_out_lng   double precision,
  geofence_zone_id uuid references public.geofence_zones(id) on delete set null,
  status          attendance_status not null default 'present',
  late_reason     text,
  late_approved   boolean not null default false,
  punch_in_remark text,
  appeal_status   text,
  appeal_reason   text,
  reviewed_by     uuid references public.staff(id) on delete set null,
  reviewed_at     timestamptz,
  notes           text,
  created_at      timestamptz not null default now()
);

create table if not exists public.leaves (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references public.staff(id) on delete cascade,
  leave_type    leave_type not null,
  start_date    date not null,
  end_date      date not null,
  reason        text,
  status        leave_status not null default 'pending',
  reviewed_by   uuid references public.staff(id) on delete set null,
  reviewed_at   timestamptz,
  reviewer_note text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.programs (
  id            uuid primary key default gen_random_uuid(),
  department_id uuid not null references public.departments(id) on delete cascade,
  name          text not null,
  code          text,
  created_at    timestamptz not null default now(),
  unique (department_id, name)
);

create table if not exists public.announcements (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  body         text,
  published_by uuid references public.staff(id) on delete set null,
  published_at timestamptz not null default now(),
  is_pinned    boolean not null default false
);

create table if not exists public.holidays (
  id   uuid primary key default gen_random_uuid(),
  name text not null,
  date date not null unique
);

create table if not exists public.attachments (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.staff(id) on delete cascade,
  related_to   text not null,
  related_id   uuid,
  file_url     text not null,
  file_name    text,
  content_type text,
  uploaded_at  timestamptz not null default now()
);

-- Bring older installations up to the same shape. CREATE TABLE above only
-- affects new databases, so these statements are needed for existing ones.
alter table public.staff
  add column if not exists ic_number text,
  add column if not exists position text,
  add column if not exists staff_grade text,
  add column if not exists employment_status text,
  add column if not exists teaching_course text,
  add column if not exists campus text,
  add column if not exists base_salary numeric(10, 2),
  add column if not exists hire_date date,
  add column if not exists last_seen timestamptz;

alter table public.attendance
  add column if not exists late_reason text,
  add column if not exists late_approved boolean default false,
  add column if not exists punch_in_remark text,
  add column if not exists appeal_status text,
  add column if not exists appeal_reason text,
  add column if not exists reviewed_by uuid references public.staff(id) on delete set null,
  add column if not exists reviewed_at timestamptz;

alter table public.attachments
  add column if not exists owner_id uuid references public.staff(id) on delete cascade,
  add column if not exists related_to text,
  add column if not exists related_id uuid,
  add column if not exists file_url text,
  add column if not exists file_name text,
  add column if not exists content_type text,
  add column if not exists uploaded_at timestamptz default now();

do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'attachments'
       and column_name = 'staff_id'
  ) then
    execute 'update public.attachments set owner_id = staff_id where owner_id is null';
  end if;
end
$$;

update public.staff
   set ic_number = coalesce(nullif(ic_number, ''), '000000-00-0000'),
       staff_grade = coalesce(nullif(staff_grade, ''), 'DG9'),
       employment_status = case lower(trim(coalesce(employment_status, '')))
         when 'permanent' then 'TETAP'
         when 'contract' then 'KONTRAK'
         when 'tetap' then 'TETAP'
         when 'kontrak' then 'KONTRAK'
         else 'TETAP'
       end,
       teaching_course = coalesce(nullif(teaching_course, ''), 'General');

update public.attendance
   set late_approved = false
 where late_approved is null;

alter table public.staff
  alter column ic_number set default '000000-00-0000',
  alter column staff_grade set default 'DG9',
  alter column employment_status set default 'TETAP',
  alter column teaching_course set default 'General';

alter table public.attendance
  alter column late_approved set default false,
  alter column late_approved set not null;

alter table public.staff
  drop constraint if exists staff_employment_status_check;

alter table public.staff
  add constraint staff_employment_status_check
  check (employment_status in ('TETAP', 'KONTRAK'));

-- -----------------------------------------------------------------------------
-- Indexes and date helpers
-- -----------------------------------------------------------------------------

create index if not exists idx_attendance_staff
  on public.attendance (staff_id, punch_in desc);

create index if not exists idx_attendance_appeal_pending
  on public.attendance (appeal_status)
  where appeal_status = 'pending';

create index if not exists idx_leaves_staff
  on public.leaves (staff_id, created_at desc);

create index if not exists idx_leaves_status
  on public.leaves (status);

create index if not exists idx_staff_last_seen
  on public.staff (last_seen desc nulls last);

create or replace function public.malaysia_date(ts timestamptz)
returns date
language sql
immutable
as $$
  select (ts at time zone 'Asia/Kuala_Lumpur')::date
$$;

drop index if exists idx_attendance_one_punch_per_day;
create unique index idx_attendance_one_punch_per_day
  on public.attendance (staff_id, public.malaysia_date(punch_in));

-- -----------------------------------------------------------------------------
-- Triggers and helper functions
-- -----------------------------------------------------------------------------

create or replace function public.handle_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_staff_updated on public.staff;
create trigger trg_staff_updated
before update on public.staff
for each row execute function public.handle_updated_at();

drop trigger if exists trg_leaves_updated on public.leaves;
create trigger trg_leaves_updated
before update on public.leaves
for each row execute function public.handle_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  default_department uuid;
begin
  select id
    into default_department
    from public.departments
   order by created_at
   limit 1;

  insert into public.staff (
    id,
    full_name,
    email,
    role,
    staff_number,
    department_id,
    ic_number,
    staff_grade,
    employment_status,
    teaching_course
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    'staff',
    'TMP-' || upper(left(replace(new.id::text, '-', ''), 8)),
    default_department,
    '000000-00-0000',
    'DG9',
    'TETAP',
    'General'
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.staff
     where id = auth.uid()
       and role = 'admin'
  )
$$;

create or replace function public.update_last_seen()
returns void
language sql
security definer
set search_path = public
as $$
  update public.staff
     set last_seen = now()
   where id = auth.uid();
$$;

revoke all on function public.update_last_seen() from public;
grant execute on function public.update_last_seen() to authenticated;

-- -----------------------------------------------------------------------------
-- Row-level security
-- -----------------------------------------------------------------------------

alter table public.staff enable row level security;
alter table public.departments enable row level security;
alter table public.geofence_zones enable row level security;
alter table public.attendance enable row level security;
alter table public.leaves enable row level security;
alter table public.programs enable row level security;
alter table public.announcements enable row level security;
alter table public.holidays enable row level security;
alter table public.attachments enable row level security;

-- Staff
drop policy if exists staff_select_self on public.staff;
drop policy if exists staff_select_admin on public.staff;
drop policy if exists staff_update_self on public.staff;
drop policy if exists staff_update_admin on public.staff;
drop policy if exists staff_insert_admin on public.staff;
drop policy if exists staff_delete_admin on public.staff;

create policy staff_select_self on public.staff
  for select using (id = auth.uid());

create policy staff_select_admin on public.staff
  for select using (public.is_admin());

create policy staff_update_self on public.staff
  for update using (id = auth.uid());

create policy staff_update_admin on public.staff
  for update using (public.is_admin()) with check (public.is_admin());

create policy staff_insert_admin on public.staff
  for insert with check (public.is_admin());

create policy staff_delete_admin on public.staff
  for delete using (public.is_admin());

-- Departments
drop policy if exists dept_read on public.departments;
drop policy if exists dept_write on public.departments;

create policy dept_read on public.departments
  for select using (auth.uid() is not null);

create policy dept_write on public.departments
  for all using (public.is_admin()) with check (public.is_admin());

-- Geofence zones
drop policy if exists geo_read on public.geofence_zones;
drop policy if exists geo_write on public.geofence_zones;

create policy geo_read on public.geofence_zones
  for select using (auth.uid() is not null);

create policy geo_write on public.geofence_zones
  for all using (public.is_admin()) with check (public.is_admin());

-- Attendance
drop policy if exists att_select_self on public.attendance;
drop policy if exists att_select_admin on public.attendance;
drop policy if exists att_insert_self on public.attendance;
drop policy if exists att_update_self on public.attendance;
drop policy if exists att_update_admin on public.attendance;
drop policy if exists att_delete_admin on public.attendance;

create policy att_select_self on public.attendance
  for select using (staff_id = auth.uid());

create policy att_select_admin on public.attendance
  for select using (public.is_admin());

create policy att_insert_self on public.attendance
  for insert with check (staff_id = auth.uid());

create policy att_update_self on public.attendance
  for update using (staff_id = auth.uid());

create policy att_update_admin on public.attendance
  for update using (public.is_admin()) with check (public.is_admin());

create policy att_delete_admin on public.attendance
  for delete using (public.is_admin());

-- Leave requests
drop policy if exists leave_select_self on public.leaves;
drop policy if exists leave_select_admin on public.leaves;
drop policy if exists leave_insert_self on public.leaves;
drop policy if exists leave_update_admin on public.leaves;

create policy leave_select_self on public.leaves
  for select using (staff_id = auth.uid());

create policy leave_select_admin on public.leaves
  for select using (public.is_admin());

create policy leave_insert_self on public.leaves
  for insert with check (staff_id = auth.uid());

create policy leave_update_admin on public.leaves
  for update using (public.is_admin()) with check (public.is_admin());

-- Programs
drop policy if exists prog_read on public.programs;
drop policy if exists prog_write on public.programs;

create policy prog_read on public.programs
  for select using (auth.uid() is not null);

create policy prog_write on public.programs
  for all using (public.is_admin()) with check (public.is_admin());

-- Announcements and holidays
drop policy if exists ann_read on public.announcements;
drop policy if exists ann_write on public.announcements;
drop policy if exists hol_read on public.holidays;
drop policy if exists hol_write on public.holidays;

create policy ann_read on public.announcements
  for select using (auth.uid() is not null);
create policy ann_write on public.announcements
  for all using (public.is_admin()) with check (public.is_admin());
create policy hol_read on public.holidays
  for select using (auth.uid() is not null);
create policy hol_write on public.holidays
  for all using (public.is_admin()) with check (public.is_admin());

-- Attachments
drop policy if exists att_own_read on public.attachments;
drop policy if exists att_own_write on public.attachments;
drop policy if exists att_admin_all on public.attachments;

create policy att_own_read on public.attachments
  for select using (owner_id = auth.uid());
create policy att_own_write on public.attachments
  for insert with check (owner_id = auth.uid());
create policy att_admin_all on public.attachments
  for all using (public.is_admin()) with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- Realtime and starter data
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    alter publication supabase_realtime add table public.attendance;
  exception when duplicate_object then null;
  end;

  begin
    alter publication supabase_realtime add table public.staff;
  exception when duplicate_object then null;
  end;
end
$$;

insert into public.departments (name, code)
values
  ('IT / Network Engineering', 'IT'),
  ('Electrical Engineering', 'EE'),
  ('Mechanical Engineering', 'ME'),
  ('Civil Engineering', 'CE'),
  ('Business Management', 'BM')
on conflict (name) do nothing;

insert into public.programs (department_id, name)
select id, name
  from public.departments
on conflict (department_id, name) do nothing;

notify pgrst, 'reload schema';

-- To promote an existing account to admin, run separately and replace the email:
-- update public.staff set role = 'admin' where email = 'admin@example.com';
