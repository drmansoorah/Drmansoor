import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") || "*";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
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

function isAllowedOrigin(req: Request): boolean {
  const origin = req.headers.get("Origin");
  return allowedOrigin === "*" || !origin || origin === allowedOrigin;
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
  if (!isAllowedOrigin(req)) return respond(403, { error: "This website origin is not allowed." });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      keyFromCollection("SUPABASE_SECRET_KEYS");
    const razorpayKeyId = Deno.env.get("RAZORPAY_KEY_ID") || "";
    const razorpayKeySecret = Deno.env.get("RAZORPAY_KEY_SECRET") || "";

    if (!supabaseUrl || !serviceRoleKey) {
      return respond(500, { error: "Supabase server credentials are unavailable." });
    }
    if (!razorpayKeyId || !razorpayKeySecret) {
      return respond(503, { error: "Online payment is not configured yet. The clinic must add its Razorpay server keys." });
    }

    const body = await req.json().catch(() => ({}));
    const patientName = String(body.patient_name || "").trim();
    const phone = String(body.phone || "").trim();
    const clinicKey = String(body.clinic_key || "").trim();
    const appointmentDate = String(body.appointment_date || "").trim();

    if (patientName.length < 2 || patientName.length > 100) {
      return respond(400, { error: "Enter a valid patient name." });
    }
    const phoneDigits = phone.replace(/\D/g, "");
    if (phone.length > 25 || phoneDigits.length < 10 || phoneDigits.length > 15) {
      return respond(400, { error: "Enter a valid WhatsApp/contact number with country code." });
    }
    if (!clinics[clinicKey]) return respond(400, { error: "Select a valid clinic." });
    if (!/^\d{4}-\d{2}-\d{2}$/.test(appointmentDate) || appointmentDate < indiaToday()) {
      return respond(400, { error: "Select today or a future appointment date." });
    }
    if (body.communication_consent !== true) {
      return respond(400, { error: "Appointment communication consent is required before payment." });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: feeRow, error: feeError } = await admin
      .from("clinic_settings")
      .select("consultation_fee,currency")
      .eq("clinic_key", clinicKey)
      .maybeSingle();

    if (feeError) {
      return respond(500, { error: "Could not read the clinic's consultation fee. Check that clinic-frontdesk-workspace.sql is applied." });
    }
    const fee = Number(feeRow?.consultation_fee || 0);
    const currency = String(feeRow?.currency || "INR");
    const amountPaise = Math.round(fee * 100);
    if (!Number.isFinite(fee) || fee < 1 || amountPaise < 100) {
      return respond(409, { error: "Online booking is not available for this clinic until its consultation fee is set to at least ₹1 in the Admin panel." });
    }
    if (currency !== "INR" || amountPaise > 100000000) {
      return respond(409, { error: "The clinic fee must be between ₹1 and ₹10,00,000 in INR." });
    }

    const receipt = "APPT" + crypto.randomUUID().replace(/-/g, "").slice(0, 28);
    const orderResponse = await fetch("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: {
        Authorization: "Basic " + btoa(razorpayKeyId + ":" + razorpayKeySecret),
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        amount: amountPaise,
        currency: "INR",
        receipt,
        notes: { clinic_key: clinicKey, booking_type: "clinic_appointment" },
      }),
    });
    const orderData = await orderResponse.json().catch(() => ({}));
    if (!orderResponse.ok || !orderData.id) {
      const detail = orderData?.error?.description || orderData?.error?.reason || "Razorpay could not create the payment order.";
      return respond(502, { error: String(detail).slice(0, 500) });
    }

    const { error: saveError } = await admin.from("appointment_payment_orders").insert({
      razorpay_order_id: orderData.id,
      clinic_key: clinicKey,
      clinic_name: clinics[clinicKey],
      patient_name: patientName,
      phone,
      appointment_date: appointmentDate,
      communication_consent: true,
      amount_paise: amountPaise,
      currency: "INR",
      status: "pending",
    });
    if (saveError) {
      return respond(500, { error: "The payment order was created, but could not be linked to a booking record. Do not pay this order; contact the clinic desk." });
    }

    return respond(200, {
      key_id: razorpayKeyId,
      order_id: orderData.id,
      amount: amountPaise,
      currency: "INR",
      clinic_key: clinicKey,
      clinic_name: clinics[clinicKey],
      consultation_fee: fee,
    });
  } catch (error) {
    return respond(500, { error: error instanceof Error ? error.message : "Could not create payment order." });
  }
});
