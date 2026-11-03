-- Repair clinic-to-doctor remittance authorization.
-- Run this once in Supabase SQL Editor after clinic-handoff-day-end.sql.
-- Reads only protected auth.users.raw_app_meta_data as fallback for stale JWT claims.

create or replace function public.clinic_record_doctor_remittance(
  p_date date,
  p_amount numeric,
  p_method text,
  p_narration text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_app_meta jsonb := '{}'::jsonb;
  v_role text;
  v_scope text;
  v_collected numeric(12,2);
  v_remitted numeric(12,2);
begin
  if v_user_id is null then
    raise exception 'Your login session is missing. Sign out and sign in again.';
  end if;

  -- Prefer the signed JWT claims, with a fallback to Supabase's protected
  -- app_metadata row when the browser holds an older access token.
  select coalesce(u.raw_app_meta_data,'{}'::jsonb)
    into v_app_meta
  from auth.users u
  where u.id = v_user_id;

  v_role := coalesce(nullif(auth.jwt()->'app_metadata'->>'role',''),v_app_meta->>'role','');
  v_scope := coalesce(
    nullif(auth.jwt()->'app_metadata'->>'clinic_key',''),
    nullif(v_app_meta->>'clinic_key',''),
    '*'
  );

  if v_role <> 'admin' then
    raise exception 'Clinic admin access required. Verify role=admin in Supabase Auth app_metadata.';
  end if;
  if p_amount is null or p_amount<=0 then raise exception 'Enter a transfer amount greater than zero'; end if;
  if p_method not in ('cash','bank_transfer','other') then raise exception 'Select cash, bank transfer or other'; end if;
  if length(trim(coalesce(p_narration,'')))<3 then raise exception 'Enter a transfer narration'; end if;
  if v_scope='*' then raise exception 'Select one clinic to transfer that clinic collection'; end if;

  perform pg_advisory_xact_lock(hashtext(v_scope),hashtext(p_date::text));

  select coalesce(sum(amount),0) into v_collected
  from public.clinic_appointment_payments
  where clinic_key=v_scope and (collected_at at time zone 'Asia/Kolkata')::date=p_date;

  select coalesce(sum(amount),0) into v_remitted
  from public.clinic_doctor_remittances
  where clinic_key=v_scope and remittance_date=p_date;

  if p_amount > greatest(v_collected-v_remitted,0) then
    raise exception 'Transfer exceeds available unremitted collection';
  end if;

  insert into public.clinic_doctor_remittances(
    clinic_key,remittance_date,amount,transfer_method,narration,transferred_by
  ) values(v_scope,p_date,p_amount,p_method,left(trim(p_narration),1000),auth.uid());

  return jsonb_build_object('clinic_key',v_scope,'date',p_date,'amount',p_amount,
    'method',p_method,'transferred_to_doctor',v_remitted+p_amount,
    'available_to_transfer',v_collected-v_remitted-p_amount);
end;
$fn$;

revoke all on function public.clinic_record_doctor_remittance(date,numeric,text,text) from public, anon;
grant execute on function public.clinic_record_doctor_remittance(date,numeric,text,text) to authenticated;
