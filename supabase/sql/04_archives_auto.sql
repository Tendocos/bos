-- Données BOS : archivage automatique un mois après leur création.
-- Elles passent dans la section « Archives » (créée ici, impossible à supprimer).

alter table public.bos_data_sections add column if not exists is_archive boolean not null default false;
alter table public.bos_data add column if not exists archived_at timestamptz;
alter table public.bos_data add column if not exists archived_from uuid;

insert into public.bos_data_sections(name, position, is_archive)
select 'Archives', 999, true
where not exists (select 1 from public.bos_data_sections where is_archive);

create unique index if not exists bos_data_sections_one_archive on public.bos_data_sections (is_archive) where is_archive;

create or replace function public.bos__archive_old()
returns integer
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare arch uuid; n int;
begin
  select id into arch from public.bos_data_sections where is_archive;
  if arch is null then return 0; end if;
  update public.bos_data
     set archived_from = section_id, section_id = arch, archived_at = now()
   where section_id <> arch and created_at < now() - interval '1 month';
  get diagnostics n = row_count;
  if n > 0 then perform public.bos__log('Système', 'page', 'Données archivées automatiquement', n || ' donnée(s) de plus d''un mois'); end if;
  return n;
end $$;
revoke all on function public.bos__archive_old() from public, anon, authenticated;

-- La section Archives ne peut pas être supprimée
create or replace function public.bos_section_delete(p_token text, p_id uuid)
returns void
language plpgsql security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare a public.bos_accounts; s public.bos_data_sections;
begin
  a := public.bos__need(p_token, 'admin');
  if exists (select 1 from public.bos_data_sections where id = p_id and is_archive) then
    raise exception 'La section Archives ne peut pas être supprimée.';
  end if;
  delete from public.bos_files where page in (select '~data/' || id::text from public.bos_data where section_id = p_id);
  delete from public.bos_data_sections where id = p_id returning * into s;
  if s.id is not null then perform public.bos__log(a.display, 'page', 'Section de données supprimée', s.name); end if;
end $function$;

-- Le rangement se fait à chaque chargement du site (comme le déverrouillage automatique)
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
                'archived_at', d.archived_at) order by d.created_at desc)
              from public.bos_data d), '[]'::json),
    'tasks', coalesce((select json_agg(t order by (t.status = 'terminee'), case t.priority when 'critique' then 0 when 'haute' then 1 else 2 end, t.created_desc)
              from (select k.*, -extract(epoch from k.created_at) as created_desc from public.bos_tasks k where dir or k.unit = any(us)) t), '[]'::json),
    'unit_status', case when dir then coalesce((select json_agg(s) from public.bos_unit_status s), '[]'::json) else '[]'::json end);
end $function$;
