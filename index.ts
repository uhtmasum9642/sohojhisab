// Supabase Edge Function: reset-pin
// অ্যাডমিন একটা ইউজারের জন্য নতুন র‍্যান্ডম ৬-সংখ্যার পিন বানায়।
// ইউজার ঢুকলে অ্যাপ জোর করে নিজের পিন বদলাতে বলে (must_change_pin = true)।
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // ১) কে ডাকছে? লগইন-করা ইউজার চিনি
    const caller = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);

    // ২) সে অ্যাডমিন কিনা
    const admin = createClient(url, service);
    const { data: me } = await admin.from("profiles").select("is_admin").eq("id", user.id).maybeSingle();
    if (!me?.is_admin) return json({ error: "forbidden" }, 403);

    // ৩) টার্গেট: শুধু ফোন-নাম্বার (…@khata.app) অ্যাকাউন্ট
    const { user_id, request_id } = await req.json();
    if (!user_id) return json({ error: "user_id_required" }, 400);
    const { data: target } = await admin.from("profiles").select("id,email").eq("id", user_id).maybeSingle();
    if (!target || !String(target.email ?? "").endsWith("@khata.app")) return json({ error: "not_phone_account" }, 400);

    // ৪) নতুন র‍্যান্ডম পিন বসানো; আগের metadata (যেমন full_name) ঠিক রাখা
    const pin = String(100000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 900000));
    const { data: existing } = await admin.auth.admin.getUserById(user_id);
    const meta = { ...(existing?.user?.user_metadata ?? {}), must_change_pin: true };
    const { error } = await admin.auth.admin.updateUserById(user_id, { password: pin, user_metadata: meta });
    if (error) return json({ error: error.message }, 500);

    // ৫) অনুরোধ "সম্পন্ন" চিহ্নিত
    if (request_id) {
      await admin.from("pin_reset_requests").update({ status: "done", handled_at: new Date().toISOString() }).eq("id", request_id);
    }
    return json({ pin, phone: String(target.email).split("@")[0] });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
