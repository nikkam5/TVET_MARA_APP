import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed" });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!token) return reply(401, { error: "Please sign in as an administrator." });
    const { data: caller, error: authError } = await admin.auth.getUser(token);
    if (authError || !caller.user) return reply(401, { error: "Your session has expired. Please sign in again." });
    const { data: profile, error: profileError } = await admin.from("staff")
      .select("role, is_active").eq("id", caller.user.id).maybeSingle();
    if (profileError || profile?.role !== "admin" || profile.is_active === false) {
      return reply(403, { error: "Only active administrators can add staff. Sign in with your admin account." });
    }
    const body = await req.json();
    for (const field of ["full_name", "email", "password", "staff_number"]) {
      if (typeof body[field] !== "string" || !body[field].trim()) {
        return reply(400, { error: `${field} is required.` });
      }
    }
    for (const field of ["ic_number", "department_id", "position", "staff_grade", "employment_status"]) {
      if (body[field] != null && typeof body[field] !== "string") {
        return reply(400, { error: `${field} must be text.` });
      }
    }
    const { count, error: countError } = await admin.from("staff").select("id", { count: "exact", head: true });
    if (countError) throw countError;
    if ((count ?? 0) >= 255) return reply(409, { error: "Staff account limit reached." });
    const { data, error } = await admin.auth.admin.createUser({
      email: body.email.trim(), password: body.password, email_confirm: true,
      user_metadata: { full_name: body.full_name.trim() },
    });
    if (error || !data.user) return reply(400, { error: error?.message ?? "Account creation failed." });
    const { data: saved, error: saveError } = await admin.from("staff").update({
      full_name: body.full_name.trim(), email: body.email.trim(),
      staff_number: body.staff_number.trim(), role: "staff", is_active: true,
      ic_number: body.ic_number || null, department_id: body.department_id || null,
      position: body.position || null, staff_grade: body.staff_grade || null,
      employment_status: body.employment_status || "TETAP",
    }).eq("id", data.user.id).select("id").single();
    if (saveError || !saved) {
      const { error: rollbackError } = await admin.auth.admin.deleteUser(data.user.id);
      return reply(500, { error: rollbackError
        ? `Profile setup failed: ${saveError?.message ?? "unknown error"}. Contact your administrator.`
        : `Profile setup failed: ${saveError?.message ?? "unknown error"}. The new account was removed.` });
    }
    // Return only the ID, never a new user's session or tokens.
    return reply(200, { user_id: data.user.id });
  } catch (error) {
    return reply(500, {
      error: error instanceof Error ? error.message : "Unable to create staff.",
    });
  }
});
