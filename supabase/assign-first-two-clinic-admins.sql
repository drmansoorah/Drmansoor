-- Assign the first two invited accounts to clinic-specific admin access.
-- Run after both invited users appear in Supabase Authentication > Users.
-- Mapping: injsameer@gmail.com -> Mansoor Private; injsameer+1@gmail.com -> GMC Anantnag.
-- The existing Master Admin account is intentionally not modified.

do $assign$
declare
  v_rows integer;
begin
  update auth.users
  set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
    || '{"role":"admin","clinic_key":"mansoor-private"}'::jsonb
  where lower(email) = lower('injsameer@gmail.com');
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'Expected exactly one Supabase Auth user for injsameer@gmail.com; found %', v_rows;
  end if;

  update auth.users
  set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
    || '{"role":"admin","clinic_key":"gmc-anantnag"}'::jsonb
  where lower(email) = lower('injsameer+1@gmail.com');
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'Expected exactly one Supabase Auth user for injsameer+1@gmail.com; found %', v_rows;
  end if;
end;
$assign$;

select email, raw_app_meta_data
from auth.users
where lower(email) in (lower('injsameer@gmail.com'), lower('injsameer+1@gmail.com'))
order by email;
