import { createClient } from "npm:@supabase/supabase-js@2";

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
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

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function paymentMethod(value: unknown): string {
  const method = String(value || "").toLowerCase();
  if (method === "upi") return "upi";
  if (method === "card") return "card";
  if (method === "netbanking") return "bank_transfer";
  return "other";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed." });

  try {
    const webhookSecret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET") || "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("SUPABASE_SECRET_KEY") ||
      keyFromCollection("SUPABASE_SECRET_KEYS");
    if (!webhookSecret || !supabaseUrl || !serviceRoleKey) {
      return json(503, { error: "Razorpay webhook is not configured on the server." });
    }

    const rawBody = await req.text();
    const signature = req.headers.get("x-razorpay-signature") || "";
    if (!/^[a-f0-9]{64}$/i.test(signature)) {
      return json(400, { error: "Missing or invalid Razorpay webhook signature." });
    }
    const expected = await hmacHex(webhookSecret, rawBody);
    if (!safeEqual(expected.toLowerCase(), signature.toLowerCase())) {
      return json(400, { error: "Razorpay webhook signature verification failed." });
    }

    const event = JSON.parse(rawBody);
    if (event?.event !== "payment.captured") {
      return json(200, { ok: true, ignored: true, event: String(event?.event || "unknown") });
    }

    const payment = event?.payload?.payment?.entity;
    const orderId = String(payment?.order_id || "");
    const paymentId = String(payment?.id || "");
    const amount = Number(payment?.amount);
    if (!orderId || !paymentId || !Number.isInteger(amount) || payment?.status !== "captured") {
      return json(400, { error: "Captured payment event is missing required fields." });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await admin.rpc("finalize_paid_appointment", {
      p_razorpay_order_id: orderId,
      p_razorpay_payment_id: paymentId,
      p_payment_method: paymentMethod(payment?.method),
      p_verified_amount_paise: amount,
    });
    if (error) {
      // A non-2xx response asks Razorpay to retry the webhook. The SQL RPC is
      // idempotent, so a duplicate event cannot create a second appointment.
      return json(500, { error: "Payment was captured but could not yet be finalized: " + error.message });
    }
    if (!data?.appointment_id) return json(500, { error: "Payment finalization did not return an appointment ID." });

    return json(200, { ok: true, appointment_id: data.appointment_id });
  } catch (error) {
    return json(500, { error: error instanceof Error ? error.message : "Webhook processing failed." });
  }
});
