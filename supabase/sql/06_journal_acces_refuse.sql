-- Note dans le Journal chaque connexion Discord refusée, avec les rôles de la personne,
-- pour savoir quels rôles ajouter dans la fonction discord-auth.
create or replace function public.bos_discord_refused(p_display text, p_discord_id text, p_roles text[])
returns void language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
begin
  perform public.bos__log(left(coalesce(nullif(trim(p_display), ''), 'Inconnu'), 40), 'acct', 'Accès refusé (grade non reconnu)',
    'Discord ' || coalesce(p_discord_id, '?') || ' · rôles : ' || coalesce(nullif(array_to_string(p_roles, ', '), ''), 'aucun'));
end $$;
revoke all on function public.bos_discord_refused(text, text, text[]) from public, anon, authenticated;
grant execute on function public.bos_discord_refused(text, text, text[]) to service_role;
