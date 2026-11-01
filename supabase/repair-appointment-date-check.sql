-- One-time safe repair for the historical appointment-date CHECK constraint.
-- Run this by itself in Supabase SQL Editor BEFORE rerunning clinic-routing.sql.
-- It does not update, delete, or change any existing appointment rows.

alter table public.appointments
  drop constraint if exists appointments_appointment_date_check;

create or replace function public.enforce_appointment_date_not_past()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $date_guard$
begin
  if new.appointment_date is null or new.appointment_date < current_date then
    raise exception 'Appointment date must be today or a future date';
  end if;
  return new;
end;
$date_guard$;

drop trigger if exists trg_enforce_appointment_date_not_past on public.appointments;
create trigger trg_enforce_appointment_date_not_past
before insert or update of appointment_date on public.appointments
for each row execute function public.enforce_appointment_date_not_past();
