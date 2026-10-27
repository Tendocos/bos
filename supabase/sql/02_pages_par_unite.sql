-- Chaque unité ne reçoit que ses pages (le filtrage se fait sur le serveur, plus seulement à l'affichage).
-- Voient tout : propriétaire, Direction, Amirauté et B.R.S (voir 03_brs_voit_tout.sql).

create or replace function public.bos__seeall(p_role text, p_units text[])
returns boolean language sql immutable as $$
  select p_role = 'owner' or coalesce(p_units, '{}') && array['direction','amiraute']
$$;

-- Unité à laquelle appartient une page, d'après son nom (même règle que le site)
create or replace function public.bos__page_unit(p_path text)
returns text language sql immutable as $$
  select case when p_path ~ '\(B\.R\.S\)' then 'brs'
              when p_path ~ '\(RC\)' then 'omega'
              when p_path ~ '\(Arc Alpha\)' then 'arc'
              when p_path ~ '\(Bad Batch\)' then 'bb'
              else 'bos' end
$$;

create or replace function public.bos__can_page(p_all boolean, p_units text[], p_path text)
returns boolean language sql immutable as $$
  select p_all or p_path = 'Accueil' or public.bos__page_unit(p_path) = any(coalesce(p_units, '{}'))
$$;

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
  return json_build_object(
    'pages', coalesce((select json_agg(json_build_object('path', path, 'content', content) order by position, path)
                       from public.bos_pages where public.bos__can_page(adm, us, path)), '[]'::json),
    'files', coalesce((select json_agg(f order by f.created_at desc) from public.bos_files f
                       where (f.page like '~%' or public.bos__can_page(adm, us, f.page))
                         and (adm or f.page not like '~data/%'
                              or not exists (select 1 from public.bos_data d where '~data/' || d.id::text = f.page and d.restricted))), '[]'::json),
    'sections', coalesce((select json_agg(json_build_object('id', id, 'name', name) order by position, created_at) from public.bos_data_sections), '[]'::json),
    'data', coalesce((select json_agg(json_build_object(
                'id', d.id, 'section_id', d.section_id, 'restricted', d.restricted, 'locked_until', d.locked_until,
                'title', case when adm or not d.restricted then d.title else null end,
                'body', case when adm or not d.restricted then d.body else null end,
                'created_at', d.created_at, 'created_by', d.created_by, 'updated_at', d.updated_at) order by d.created_at desc)
              from public.bos_data d), '[]'::json),
    'tasks', coalesce((select json_agg(t order by (t.status = 'terminee'), case t.priority when 'critique' then 0 when 'haute' then 1 else 2 end, t.created_desc)
              from (select k.*, -extract(epoch from k.created_at) as created_desc from public.bos_tasks k where dir or k.unit = any(us)) t), '[]'::json),
    'unit_status', case when dir then coalesce((select json_agg(s) from public.bos_unit_status s), '[]'::json) else '[]'::json end);
end $function$;
