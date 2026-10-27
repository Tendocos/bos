// Connexion Discord pour le site B.O.S
// ------------------------------------------------------------
// Reçoit le "code" renvoyé par Discord après la connexion, vérifie
// que la personne est bien sur le serveur CloneWarsRP, lit ses rôles,
// les traduit en unités du site, puis ouvre une session sur le site.
//
// Tous les secrets restent ici, côté serveur (jamais dans le site) :
//   DISCORD_CLIENT_ID      ID de l'application Discord
//   DISCORD_CLIENT_SECRET  secret de l'application Discord
//   DISCORD_GUILD_ID       ID du serveur Discord CloneWarsRP
//   DISCORD_ROLE_MAP       JSON  {"<id du rôle Discord>": "<unité du site>", ...}
//                          unités possibles : direction, amiraute, brs, arc, omega, bb, bos
//   DISCORD_ADMIN_ROLES    IDs de rôles Discord qui peuvent MODIFIER le site (séparés par des virgules)
//   DISCORD_OWNER_IDS      ID(s) de compte Discord du propriétaire du site
//   SITE_URLS              adresses autorisées du site (par défaut https://tendocos.github.io/bos/)
// SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis automatiquement par Supabase.

import { createClient } from "npm:@supabase/supabase-js@2";

const env = (k: string, d = "") => (Deno.env.get(k) ?? d).trim();
const list = (k: string) => env(k).split(",").map((s) => s.trim()).filter(Boolean);

const CLIENT_ID = env("DISCORD_CLIENT_ID");
const CLIENT_SECRET = env("DISCORD_CLIENT_SECRET");
const GUILD_ID = env("DISCORD_GUILD_ID");
const ADMIN_ROLES = list("DISCORD_ADMIN_ROLES");
const OWNER_IDS = list("DISCORD_OWNER_IDS");
const SITE_URLS = list("SITE_URLS").length ? list("SITE_URLS") : ["https://tendocos.github.io/bos/"];
const UNIT_KEYS = ["direction", "amiraute", "brs", "arc", "omega", "bb", "bos"];

let ROLE_MAP: Record<string, string> = {};
try { ROLE_MAP = JSON.parse(env("DISCORD_ROLE_MAP", "{}")); } catch { ROLE_MAP = {}; }

const origins = [...new Set(SITE_URLS.map((u) => new URL(u).origin))];
function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": origins.includes(o) ? o : origins[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const reply = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors(req) });
  if (req.method !== "POST") return reply(req, { error: "Méthode non autorisée" }, 405);
  if (!CLIENT_ID || !CLIENT_SECRET || !GUILD_ID) return reply(req, { error: "Connexion Discord pas encore configurée sur le serveur." }, 500);

  let code = "", redirect = "";
  try { ({ code = "", redirect_uri: redirect = "" } = await req.json()); } catch { /* corps vide */ }
  if (!code || !SITE_URLS.includes(redirect)) return reply(req, { error: "Demande de connexion invalide." }, 400);

  // 1. Échanger le code contre un jeton Discord (valable seulement pour cette personne)
  const tk = await fetch("https://discord.com/api/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: CLIENT_ID, client_secret: CLIENT_SECRET,
      grant_type: "authorization_code", code, redirect_uri: redirect,
    }),
  });
  if (!tk.ok) return reply(req, { error: "Discord a refusé la connexion. Réessaie." }, 401);
  const { access_token } = await tk.json();

  // 2. Lire le profil de la personne SUR le serveur CloneWarsRP (pseudo + rôles)
  const mr = await fetch(`https://discord.com/api/users/@me/guilds/${GUILD_ID}/member`, {
    headers: { Authorization: `Bearer ${access_token}` },
  });
  // On n'a plus besoin du jeton : on le révoque tout de suite
  fetch("https://discord.com/api/oauth2/token/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, token: access_token }),
  }).catch(() => {});

  if (mr.status === 404) return reply(req, { error: "Tu n'es pas membre du serveur Discord CloneWarsRP.", code: "not_member" }, 403);
  if (!mr.ok) return reply(req, { error: "Impossible de lire tes rôles Discord pour l'instant. Réessaie dans un moment." }, 502);
  const member = await mr.json();
  const user = member.user ?? {};
  const roles: string[] = member.roles ?? [];

  // 3. Rôles Discord → unités du site
  const units = UNIT_KEYS.filter((k) => roles.some((r) => ROLE_MAP[r] === k));
  const owner = OWNER_IDS.includes(user.id);
  if (!units.length && !owner) {
    return reply(req, { error: "Ton grade sur le serveur ne donne pas accès aux archives B.O.S.", code: "no_role" }, 403);
  }
  const role = owner ? "owner" : roles.some((r) => ADMIN_ROLES.includes(r)) ? "admin" : "membre";
  const display = String(member.nick || user.global_name || user.username || "Inconnu").slice(0, 40);

  // 4. Créer / mettre à jour le compte et ouvrir une session sur le site
  const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
  const { data, error } = await db.rpc("bos_discord_login", {
    p_discord_id: user.id,
    p_username: String(user.username || user.id).toLowerCase().slice(0, 30),
    p_display: display,
    p_role: role,
    p_units: units.length ? units : ["direction"],
  });
  if (error || !data) return reply(req, { error: "Erreur du serveur du site : " + (error?.message ?? "réponse vide") }, 500);
  return reply(req, data);
});
