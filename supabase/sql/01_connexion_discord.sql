-- Connexion Discord : lien entre un compte du site et un compte Discord
alter table public.bos_accounts add column if not exists discord_id text unique;

-- Appelée UNIQUEMENT par la fonction serveur discord-auth (clé service_role),
-- après vérification des rôles sur Discord. Crée ou met à jour le compte,
-- recopie les unités et le rôle venant de Discord, et ouvre une session de 24 h.
create or replace function public.bos_discord_login(
  p_discord_id text, p_username text, p_display text, p_role text, p_units text[])
returns json
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare a public.bos_accounts; u text; us text[]; t text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if coalesce(p_discord_id, '') !~ '^\d{15,22}$' then raise exception 'Identifiant Discord invalide.'; end if;
  if p_role not in ('owner', 'admin', 'membre') then raise exception 'Rôle invalide.'; end if;
  us := public.bos__units(p_units);

  select * into a from public.bos_accounts where discord_id = p_discord_id;

  -- Première connexion Discord du propriétaire : on reprend son compte existant
  if a.id is null and p_role = 'owner' then
    select * into a from public.bos_accounts where role = 'owner' and discord_id is null order by created_at limit 1;
  end if;

  if a.id is null then
    u := lower(regexp_replace(coalesce(p_username, ''), '[^a-zA-Z0-9._-]', '', 'g'));
    if length(u) < 2 then u := 'discord-' || right(p_discord_id, 6); end if;
    u := left(u, 30);
    if exists (select 1 from public.bos_accounts where username = u) then u := left(u, 23) || '-' || right(p_discord_id, 6); end if;
    insert into public.bos_accounts(username, display, role, pw_hash, unit, units, discord_id)
    values (u, coalesce(nullif(trim(p_display), ''), u), p_role,
            extensions.crypt(encode(extensions.gen_random_bytes(24), 'hex'), extensions.gen_salt('bf')),
            us[1], us, p_discord_id)
    returning * into a;
    perform public.bos__log(a.display, 'acct', 'Compte créé via Discord', public.bos__units_name(us));
  else
    update public.bos_accounts
       set discord_id = p_discord_id, display = coalesce(nullif(trim(p_display), ''), display),
           role = p_role, unit = us[1], units = us, fails = 0, locked_until = null
     where id = a.id
    returning * into a;
  end if;

  delete from public.bos_sessions where expires_at < now();
  insert into public.bos_sessions(token, account_id, expires_at) values (t, a.id, now() + interval '24 hours');
  perform public.bos__log(a.display, 'acct', 'Connexion Discord', public.bos__units_name(us));
  return json_build_object('token', t, 'id', a.id, 'username', a.username, 'display', a.display, 'role', a.role,
                           'unit', a.unit, 'units', public.bos__units(a.units));
end $$;

revoke all on function public.bos_discord_login(text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.bos_discord_login(text, text, text, text, text[]) to service_role;
