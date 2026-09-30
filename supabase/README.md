# Supabase database setup

The project now uses one database script:

```text
supabase/schema.sql
```

If the app reports `PGRST204` and says that `employment_status` or `position`
cannot be found, run `repair_staff_employment_fields.sql` once, wait a few
seconds, then reload the app.

Run it in the Supabase SQL Editor. It contains the tables, columns, indexes,
triggers, policies, realtime setup, starter departments, and the staff
presence function used by the app.

## Important

This script is idempotent for normal setup changes. It does not drop tables or
delete staff, attendance, leave, or authentication data. Do not delete the
database tables just to remove old SQL Editor query tabs; saved query files and
live database data are separate things.

Before running it on an existing project, export a database backup. The script
adds the new staff employment fields:

| Form field | Database column |
|---|---|
| Nombor Gaji | `staff_number` |
| Jawatan | `position` |
| Gred Gaji | `staff_grade` |
| Status | `employment_status` (`TETAP` or `KONTRAK`) |
| Account Status | `is_active` |

`is_active` is deliberately separate from employment status. Add Staff creates
an active account by default; Edit Staff can change Account Status later.

To promote an account to admin, run this separately after replacing the email:

```sql
update public.staff
set role = 'admin'
where email = 'admin@example.com';
```
