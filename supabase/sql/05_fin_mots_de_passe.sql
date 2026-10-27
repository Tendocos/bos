-- Fin de la connexion par mot de passe : seul Discord ouvre une session.
-- (Pour revenir en arrière : grant execute ... to anon, authenticated.)
revoke execute on function public.bos_login(text, text) from public, anon, authenticated;
revoke execute on function public.bos_setup_owner(text, text, text) from public, anon, authenticated;
do $$ declare f regprocedure; begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'bos_create_account' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- Déconnecte les sessions ouvertes avec un ancien mot de passe
delete from public.bos_sessions s using public.bos_accounts a where a.id = s.account_id and a.discord_id is null;
