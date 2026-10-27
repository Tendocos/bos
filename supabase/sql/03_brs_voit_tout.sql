-- La B.R.S (espions) voit tout et peut verrouiller/déverrouiller les Données BOS, comme Amirauté et Direction.
create or replace function public.bos__seeall(p_role text, p_units text[])
returns boolean language sql immutable as $$
  select p_role = 'owner' or coalesce(p_units, '{}') && array['direction','amiraute','brs']
$$;
