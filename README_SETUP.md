# Clinic appointment system (Supabase + admin approval + SMS + WhatsApp)

This package updates the existing single-file clinic website and adds a separate admin dashboard. It is **not connected to a live Supabase project yet**; configure your own project and provider credentials before publishing.

## Files
- `index.html` — existing clinic website with appointment requests saved to Supabase.
- `config.js` — browser-safe Supabase project URL and anon key placeholders only.
- `admin.html` — password login, pending/approved/rejected lists, approval/rejection actions.
- `supabase/schema.sql` — table, indexes and row-level security policies.
- `supabase/functions/appointment-decision/index.ts` — protected Edge Function; admin-only decisions and notification dispatch.
- `.env.example` — server-side secrets checklist.

## 1) Create Supabase project
1. Create a project at https://supabase.com/.
2. In Project Settings → API, copy the Project URL and anon/public key.
3. Edit `config.js` and replace `YOUR_PROJECT_ID` and `YOUR_SUPABASE_ANON_KEY`.
4. Open SQL Editor and run `supabase/schema.sql`.
5. In Authentication settings, enable Email/Password. Create the clinic admin user in Authentication → Users.
6. Grant admin role to that user using SQL Editor (replace the email):

```sql
UPDATE auth.users
SET raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
WHERE email = 'admin@example.com';
```

Sign out and sign in again after granting the role so the new JWT contains `app_metadata.role = admin`. Do not grant this role to patient accounts.

## 2) Configure and deploy the Edge Function
Install the Supabase CLI and log in, then from this package directory:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase secrets set SUPABASE_URL=https://YOUR_PROJECT_ID.supabase.co
supabase secrets set SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
supabase secrets set ALLOWED_ORIGIN=https://YOUR_PUBLIC_SITE_DOMAIN
supabase functions deploy appointment-decision
```

Set secrets through the CLI or Supabase dashboard only. **Never put the service-role key or messaging provider tokens in `config.js`, HTML, Git, or any public folder.** Keep the Edge Function JWT verification enabled; it additionally checks the signed user's server-managed app metadata role.

## 3) SMS setup (MSG91)
1. Configure MSG91 account, sender/route, and DLT registration/templates as required for Indian messaging.
2. Create approved confirmation and rejection Flow templates. Templates should accept the variables `VAR1` patient name, `VAR2` date, `VAR3` slot, `VAR4` clinic, `VAR5` status.
3. Set server-side secrets:

```bash
supabase secrets set MSG91_AUTH_KEY=YOUR_MSG91_AUTH_KEY
supabase secrets set MSG91_TEMPLATE_APPROVED=YOUR_APPROVED_FLOW_TEMPLATE_ID
supabase secrets set MSG91_TEMPLATE_REJECTED=YOUR_REJECTED_FLOW_TEMPLATE_ID
```

Check the MSG91 response/logs and adjust the payload variable names if your particular Flow template uses a different schema. A `sent` response means the provider accepted the request, not guaranteed handset delivery.

## 4) WhatsApp setup (Meta WhatsApp Cloud API)
1. Configure a Meta Business app, WhatsApp Business phone number, and approved message templates.
2. Templates configured below must have four body variables in this order: patient name, date, slot, clinic. Use separate approved template names for approval and rejection. Ensure the patient has opted in.
3. Set secrets:

```bash
supabase secrets set WHATSAPP_ACCESS_TOKEN=YOUR_LONG_LIVED_TOKEN
supabase secrets set WHATSAPP_PHONE_NUMBER_ID=YOUR_PHONE_NUMBER_ID
supabase secrets set WHATSAPP_TEMPLATE_APPROVED=appointment_confirmation
supabase secrets set WHATSAPP_TEMPLATE_REJECTED=appointment_request_update
supabase secrets set WHATSAPP_TEMPLATE_LANGUAGE=en
supabase secrets set WHATSAPP_API_VERSION=v22.0
```

Use a supported Graph API version for your Meta app. WhatsApp business-initiated notifications generally require an approved template and valid opt-in. Provider policy/template approvals are your responsibility.

## 5) Publish the site
Upload `index.html`, `config.js`, and `admin.html` together to a static host (Netlify, Vercel, etc.). The admin URL will be `https://YOUR_DOMAIN/admin.html`. Keep all files in the same site root so the relative `config.js` path works. HTTPS is required for production.

## How it behaves
- A patient request is inserted with `status = pending` and can only be inserted as pending through the public browser key.
- Patients cannot read existing records. Admin reads are protected by RLS and the `app_metadata.role = admin` claim.
- The admin decision Edge Function verifies the signed-in user and admin role on the server. It changes the status once, then attempts SMS and WhatsApp messages.
- If a provider is unconfigured or fails, the appointment status still changes but the dashboard shows notification status so staff can follow up manually.
- The form does not save free-text medical history. It stores the selected concern category; avoid collecting unnecessary sensitive health data.

## Before going live
- Verify doctor identity, clinic details, actual schedules, helpline numbers, and permission to publish this website.
- Test a dummy request, admin login, approval, rejection, SMS and WhatsApp with your own test number first.
- Add CAPTCHA/rate limiting before broad public launch; the public insert policy is intentionally limited by RLS but is not an anti-spam system.
- Review applicable Indian privacy/data-protection requirements and provider terms. Do not describe this as HIPAA compliant.
- The UI says `Pending` after submission; it must not promise an appointment is confirmed until a staff member approves it.
