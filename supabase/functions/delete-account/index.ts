import { withSupabase } from "npm:@supabase/server";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const authenticatedHandler = withSupabase(
  { auth: "user" },
  async (req, ctx) => {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const userId = ctx.userClaims?.id ?? ctx.userClaims?.sub;
    if (typeof userId !== "string" || !userId) {
      return json({ error: "Authentication required" }, 401);
    }

    // The admin client is server-only and deletes only the caller identified by
    // the verified user JWT. User-owned rows reference auth.users with ON DELETE CASCADE.
    const { error } = await ctx.supabaseAdmin.auth.admin.deleteUser(userId);
    if (error) {
      console.error("Account deletion failed:", error.message);
      return json({ error: "Account deletion could not be completed" }, 500);
    }

    return json({ success: true });
  },
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const response = await authenticatedHandler(req);
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders)) headers.set(key, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
});
