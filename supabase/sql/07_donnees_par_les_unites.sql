-- ARC Alpha, Bad Batch, B.R.S et Omega peuvent créer des Données BOS et y joindre des captures.
-- Ils peuvent modifier / supprimer leurs propres données ; les admins (Direction) gardent la main sur tout.

alter table public.bos_data add column if not exists author_id uuid;

create or replace function public.bos__data_writer(p_role text, p_units text[])
returns boolean language sql immutable as $$
  select public.bos__lvl(p_role) >= 2 or coalesce(p_units, '{}') && array['arc','bb','brs','omega']
$$;

create or replace function public.bos_data_save(p_token text, p_id uuid, p_section uuid, p_title text, p_body text, p_restricted boolean)
returns uuid
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare a public.bos_accounts; nid uuid; t text := left(trim(coalesce(p_title, '')), 120); d public.bos_data; adm boolean;
begin
  a := public.bos__need(p_token, 'membre');
  adm := public.bos__lvl(a.role) >= 2;
  if not public.bos__data_writer(a.role, a.units) then raise exception 'Ton unité ne peut pas ajouter de données.'; end if;
  if t = '' then raise exception 'Donne un titre à la donnée.'; end if;
  if not exists (select 1 from public.bos_data_sections where id = p_section) then raise exception 'Section introuvable.'; end if;
  if p_id is null then
    if exists (select 1 from public.bos_data_sections where id = p_section and is_archive) then
      raise exception 'On ne peut pas ajouter une donnée directement dans les Archives.';
    end if;
    insert into public.bos_data(section_id, title, body, restricted, created_by, author_id)
    values (p_section, t, left(coalesce(p_body, ''), 20000), false, a.display, a.id) returning id into nid;
    perform public.bos__log(a.display, 'page', 'Donnée ajoutée', t);
  else
    select * into d from public.bos_data where id = p_id;
    if d.id is null then raise exception 'Donnée introuvable.'; end if;
    if not adm and d.author_id is distinct from a.id then raise exception 'Tu ne peux modifier que tes propres données.'; end if;
    if d.restricted and not public.bos__seeall(a.role, a.units) then
      raise exception 'Donnée verrouillée : seules la Direction, l''Amirauté et la B.R.S peuvent la modifier.';
    end if;
    update public.bos_data set section_id = p_section, title = t, body = left(coalesce(p_body, ''), 20000), updated_at = now()
    where id = p_id returning id into nid;
    perform public.bos__log(a.display, 'page', 'Donnée modifiée', t);
  end if;
  return nid;
end $function$;

create or replace function public.bos_data_delete(p_token text, p_id uuid)
returns void
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare a public.bos_accounts; d public.bos_data;
begin
  a := public.bos__need(p_token, 'membre');
  select * into d from public.bos_data where id = p_id;
  if d.id is null then return; end if;
  if public.bos__lvl(a.role) < 2 and not (public.bos__data_writer(a.role, a.units) and d.author_id = a.id) then
    raise exception 'Tu ne peux supprimer que tes propres données.';
  end if;
  delete from public.bos_data where id = p_id;
  delete from public.bos_files where page = '~data/' || d.id::text;
  perform public.bos__log(a.display, 'page', 'Donnée supprimée', d.title);
end $function$;

create or replace function public.bos_upload_ticket(p_token text)
returns text
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare a public.bos_accounts; t text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  a := public.bos__need(p_token, 'membre');
  if not public.bos__data_writer(a.role, a.units) then raise exception 'Action réservée aux admins.'; end if;
  delete from public.bos_tickets where expires_at < now();
  insert into public.bos_tickets(ticket, account_id, expires_at) values (t, a.id, now() + interval '15 minutes');
  return t;
end $function$;

create or replace function public.bos_add_file(p_token text, p_page text, p_name text, p_type text, p_size bigint, p_object_path text)
returns uuid
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare a public.bos_accounts; fid uuid;
begin
  a := public.bos__need(p_token, 'membre');
  if public.bos__lvl(a.role) < 2 and not (
       public.bos__data_writer(a.role, a.units)
       and exists (select 1 from public.bos_data d where '~data/' || d.id::text = p_page and d.author_id = a.id)) then
    raise exception 'Tu ne peux joindre des fichiers qu''à tes propres données.';
  end if;
  if not exists(select 1 from public.bos_tickets where ticket = split_part(p_object_path, '/', 1) and account_id = a.id) then
    raise exception 'Dépôt refusé : ticket invalide.';
  end if;
  insert into public.bos_files(page, name, type, size, object_path, created_by)
  values (p_page, p_name, p_type, p_size, p_object_path, a.display) returning id into fid;
  perform public.bos__log(a.display, 'file', 'Fichier ajouté', p_name || ' → ' || p_page);
  return fid;
end $function$;

-- On renvoie aussi l'auteur de chaque donnée, pour afficher « Modifier » à son auteur
create or replace function public.bos_get_data(p_token text)
returns json
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare a public.bos_accounts; adm boolean; dir boolean; us text[];
begin
  a := public.bos__need(p_token, 'membre');
  adm := public.bos__seeall(a.role, a.units);
  dir := public.bos__isdir(a.role, a.units);
  us := public.bos__units(a.units);
  update public.bos_data set restricted = false, locked_until = null where restricted and locked_until is not null and locked_until <= now();
  perform public.bos__archive_old();
  return json_build_object(
    'pages', coalesce((select json_agg(json_build_object('path', path, 'content', content) order by position, path)
                       from public.bos_pages where public.bos__can_page(adm, us, path)), '[]'::json),
    'files', coalesce((select json_agg(f order by f.created_at desc) from public.bos_files f
                       where (f.page like '~%' or public.bos__can_page(adm, us, f.page))
                         and (adm or f.page not like '~data/%'
                              or not exists (select 1 from public.bos_data d where '~data/' || d.id::text = f.page and d.restricted))), '[]'::json),
    'sections', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'is_archive', is_archive) order by position, created_at) from public.bos_data_sections), '[]'::json),
    'data', coalesce((select json_agg(json_build_object(
                'id', d.id, 'section_id', d.section_id, 'restricted', d.restricted, 'locked_until', d.locked_until,
                'title', case when adm or not d.restricted then d.title else null end,
                'body', case when adm or not d.restricted then d.body else null end,
                'created_at', d.created_at, 'created_by', d.created_by, 'updated_at', d.updated_at,
                'archived_at', d.archived_at, 'author_id', d.author_id) order by d.created_at desc)
              from public.bos_data d), '[]'::json),
    'tasks', coalesce((select json_agg(t order by (t.status = 'terminee'), case t.priority when 'critique' then 0 when 'haute' then 1 else 2 end, t.created_desc)
              from (select k.*, -extract(epoch from k.created_at) as created_desc from public.bos_tasks k where dir or k.unit = any(us)) t), '[]'::json),
    'unit_status', case when dir then coalesce((select json_agg(s) from public.bos_unit_status s), '[]'::json) else '[]'::json end);
end $function$;
