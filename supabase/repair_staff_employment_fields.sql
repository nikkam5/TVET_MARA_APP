-- Run this once if PostgREST reports that employment_status or position is missing.

alter table public.staff
  add column if not exists position text,
  add column if not exists staff_grade text,
  add column if not exists employment_status text;

update public.staff
set employment_status = case lower(trim(coalesce(employment_status, '')))
  when 'permanent' then 'TETAP'
  when 'contract' then 'KONTRAK'
  when 'kontrak' then 'KONTRAK'
  else 'TETAP'
end
where employment_status is null
   or lower(trim(employment_status)) in ('permanent', 'contract', 'tetap', 'kontrak');

alter table public.staff
  alter column employment_status set default 'TETAP';

notify pgrst, 'reload schema';

-- Check the result:
-- select column_name, data_type
-- from information_schema.columns
-- where table_schema = 'public'
--   and table_name = 'staff'
--   and column_name in ('position', 'staff_grade', 'employment_status');
