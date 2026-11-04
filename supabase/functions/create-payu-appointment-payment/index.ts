const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") || "";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin || "https://drmansoor.vercel.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Vary": "Origin",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function keyFromCollection(name: string): string {
  const raw = Deno.env.get(name) || "";
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw);
    return typeof parsed?.default === "string" ? parsed.default : "";
  } catch {
    return "";
  }
}

async function sha512(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function indiaToday(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Kolkata",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

const clinics: Record<string, string> = {
  "mansoor-private": "Mansoor Psychiatry & MindCare Clinic",
  "gmc-anantnag": "GMC Anantnag Associated Hospital",
  "south-kashmir": "South Kashmir Mental Wellness Centre",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "Method not allowed." });

  const origin = req.headers.get("Origin") || "";
  if (!allowedOrigin || origin !== allowedOrigin) {
    return respond(403, { error: "This website origin is not allowed to start a payment." });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      keyFromCollection("SUPABASE_SECRET_KEYS");
    const merchantKey = Deno.env.get("PAYU_MERCHANT_KEY") || "";
    const merchantSalt = Deno.env.get("PAYU_MERCHANT_SALT") || "";
    const environment = (Deno.env.get("PAYU_ENV") || "test").toLowerCase();

    if (!supabaseUrl || !serviceRoleKey) {
      return respond(500, { error: "Supabase server credentials are unavailable." });
    }
    if (!merchantKey || !merchantSalt) {
      return respond(503, { error: "PayU is not configured. Add the PayU Merchant Key and Salt in Supabase Edge Function Secrets." });
    }
    if (environment !== "test" && environment !== "production") {
      return respond(500, { error: "PAYU_ENV must be test or production." });
    }

    const body = await req.json().catch(() => ({}));
    const patientName = String(body.patient_name || "").trim().replace(/\s+/g, " ");
    const rawPhone = String(body.phone || "").trim();
    const phoneDigits = rawPhone.replace(/\D/g, "");
    const phone = phoneDigits.startsWith("91") && phoneDigits.length === 12
      ? phoneDigits.slice(2)
      : phoneDigits;
    const email = String(body.email || "").trim().toLowerCase();
    const clinicKey = String(body.clinic_key || "").trim();
    const appointmentDate = String(body.appointment_date || "").trim();

    if (patientName.length < 2 || patientName.length > 100) {
      return respond(400, { error: "Enter a valid patient name." });
    }
    if (!/^\d{10}$/.test(phone)) {
      return respond(400, { error: "Enter a valid 10-digit Indian mobile number." });
    }
    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return respond(400, { error: "Enter a valid email address. PayU Hosted Checkout requires an email." });
    }
    if (!clinics[clinicKey]) return respond(400, { error: "Select a valid clinic." });
    if (!/^\d{4}-\d{2}-\d{2}$/.test(appointmentDate) || appointmentDate < indiaToday()) {
      return respond(400, { error: "Select today or a future appointment date." });
    }
    if (body.communication_consent !== true) {
      return respond(400, { error: "Appointment communication consent is required before payment." });
    }

    const admin = (await import("npm:@supabase/supabase-js@2")).createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const { data: recent, error: recentError } = await admin
      .from("appointment_payment_orders")
      .select("id")
      .eq("phone", phone)
      .gte("created_at", since)
      .limit(8);
    if (recentError) {
      return respond(500, { error: "Payment booking service is not ready. Apply the PayU booking SQL migration first." });
    }
    if ((recent || []).length >= 8) {
      return respond(429, { error: "Too many payment attempts for this mobile number. Please contact the clinic desk." });
    }

    const { data: feeRow, error: feeError } = await admin
      .from("clinic_settings")
      .select("consultation_fee,currency")
      .eq("clinic_key", clinicKey)
      .maybeSingle();
    if (feeError) {
      return respond(500, { error: "Could not read the clinic consultation fee. Check the clinic workspace migration." });
    }

    const fee = Number(feeRow?.consultation_fee || 0);
    const amountPaise = Math.round(fee * 100);
    if (!Number.isFinite(fee) || fee < 1 || amountPaise < 100) {
      return respond(409, { error: "Online booking is not available until this clinic's consultation fee is set to at least ₹1 in Admin → Clinic Finance." });
    }
    if (String(feeRow?.currency || "INR") !== "INR" || amountPaise > 100000000) {
      return respond(409, { error: "The clinic fee must be between ₹1 and ₹10,00,000 in INR." });
    }

    const amount = (amountPaise / 100).toFixed(2);
    const txnid = "DRM" + crypto.randomUUID().replace(/-/g, "").slice(0, 20);
    const productinfo = "Clinic Appointment";
    const firstname = patientName;
    const udf1 = clinicKey;
    const udf2 = appointmentDate;
    const udf3 = "paid_clinic_booking";
    const udf4 = "";
    const udf5 = "";
    const hashString = [
      merchantKey, txnid, amount, productinfo, firstname, email,
      udf1, udf2, udf3, udf4, udf5,
    ].join("|") + "||||||" + merchantSalt;
    const hash = await sha512(hashString);

    const callbackUrl = supabaseUrl.replace(/\/$/, "") +
      "/functions/v1/payu-appointment-callback";
    const fields: Record<string, string> = {
      key: merchantKey,
      txnid,
      amount,
      productinfo,
      firstname,
      email,
      phone,
      surl: callbackUrl + "?source=return",
      furl: callbackUrl + "?source=return",
      udf1,
      udf2,
      udf3,
      udf4,
      udf5,
      hash,
    };

    const { error: saveError } = await admin.from("appointment_payment_orders").insert({
      gateway: "payu",
      gateway_txn_id: txnid,
      clinic_key: clinicKey,
      clinic_name: clinics[clinicKey],
      patient_name: patientName,
      phone,
      email,
      appointment_date: appointmentDate,
      communication_consent: true,
      amount_paise: amountPaise,
      currency: "INR",
      status: "pending",
    });
    if (saveError) {
      return respond(500, { error: "Could not save the secure payment reference. No payment was started." });
    }

    return respond(200, {
      gateway_url: environment === "production"
        ? "https://secure.payu.in/_payment"
        : "https://test.payu.in/_payment",
      fields,
      amount,
      currency: "INR",
      clinic_name: clinics[clinicKey],
    });
  } catch (error) {
    return respond(500, { error: error instanceof Error ? error.message : "Could not start PayU payment." });
  }
});
