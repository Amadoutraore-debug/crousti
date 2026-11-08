-- DORÉ Chicken : commandes en ligne (sur place, livraison, à emporter)
-- À exécuter une fois dans Supabase > SQL Editor.

-- 1. Carte des produits (les prix font foi côté serveur)
create table if not exists public.dore_products (
  id text primary key,
  name text not null,
  price int not null check (price >= 0),
  active boolean not null default true
);

insert into public.dore_products (id, name, price) values
  ('seau8','Seau 8 pièces',12000),
  ('burger-piquant','Menu Burger Piquant',4500),
  ('hot5','5 pièces Hot & Crispy',8000),
  ('ailes','Box Ailes Croustillantes',6500),
  ('seau-famille','Seau Famille',18000),
  ('double-cheese','Double Cheese Burger',4000),
  ('burger-classique','Burger Classique',3000),
  ('tenders','Tenders Poulet',3500),
  ('grande-frite','Grande Frite',1500),
  ('frites-ketchup','Frites & Ketchup',1200),
  ('soda','Soda Glacé',800),
  ('sundae','Sundae Chocolat',2000)
on conflict (id) do update set name = excluded.name, price = excluded.price;

-- 2. Commandes : chaque commande reçoit un numéro unique DC-00001, DC-00002…
create sequence if not exists public.dore_num_seq;

create table if not exists public.dore_orders (
  id bigint generated always as identity primary key,
  numero text not null unique default ('DC-' || lpad(nextval('public.dore_num_seq')::text, 5, '0')),
  created_at timestamptz not null default now(),
  mode text not null check (mode in ('sur_place','livraison','emporter')),
  table_no text,
  client_name text not null,
  phone text,
  address text,
  note text,
  items jsonb not null,
  subtotal int not null,
  delivery int not null default 0,
  total int not null,
  status text not null default 'nouvelle'
    check (status in ('nouvelle','preparation','prete','terminee','annulee')),
  updated_at timestamptz not null default now()
);

-- 3. Personnel autorisé à voir les commandes (page cuisine)
create table if not exists public.dore_staff (email text primary key);
insert into public.dore_staff (email) values ('voiceoftraore@gmail.com') on conflict do nothing;

create or replace function public.dore_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dore_staff where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- 4. Sécurité (RLS) : le public ne lit rien, seul le personnel voit et modifie
alter table public.dore_orders enable row level security;
alter table public.dore_staff enable row level security;
alter table public.dore_products enable row level security;

drop policy if exists "staff lit commandes" on public.dore_orders;
create policy "staff lit commandes" on public.dore_orders for select to authenticated using (public.dore_is_staff());
drop policy if exists "staff modifie commandes" on public.dore_orders;
create policy "staff modifie commandes" on public.dore_orders for update to authenticated using (public.dore_is_staff()) with check (public.dore_is_staff());
drop policy if exists "carte publique" on public.dore_products;
create policy "carte publique" on public.dore_products for select to anon, authenticated using (active);

-- 5. Passer une commande (appelé par le site, sans compte)
create or replace function public.dore_place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_mode text := p ->> 'mode';
  v_items jsonb := '[]'::jsonb;
  v_sub int := 0;
  v_del int := 0;
  it jsonb; pr record; q int;
  v_num text;
begin
  if v_mode not in ('sur_place','livraison','emporter') then raise exception 'Mode invalide'; end if;
  if coalesce(trim(p ->> 'name'), '') = '' then raise exception 'Nom obligatoire'; end if;
  if v_mode = 'sur_place' and coalesce(trim(p ->> 'table'), '') = '' then raise exception 'Numéro de table obligatoire'; end if;
  if v_mode <> 'sur_place' and coalesce(trim(p ->> 'phone'), '') = '' then raise exception 'Téléphone obligatoire'; end if;
  if v_mode = 'livraison' and coalesce(trim(p ->> 'address'), '') = '' then raise exception 'Adresse obligatoire'; end if;
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') = 0 then raise exception 'Panier vide'; end if;
  if jsonb_array_length(p -> 'items') > 40 then raise exception 'Trop d''articles'; end if;

  for it in select * from jsonb_array_elements(p -> 'items') loop
    q := least(greatest(coalesce((it ->> 'qty')::int, 0), 0), 50);
    select * into pr from dore_products where id = it ->> 'id' and active;
    if not found or q = 0 then raise exception 'Article invalide'; end if;
    v_sub := v_sub + pr.price * q;
    v_items := v_items || jsonb_build_object('id', pr.id, 'name', pr.name, 'price', pr.price, 'qty', q);
  end loop;

  if v_mode = 'livraison' then v_del := 1000; end if;

  insert into dore_orders (mode, table_no, client_name, phone, address, note, items, subtotal, delivery, total)
  values (v_mode, nullif(left(trim(p ->> 'table'), 10), ''), left(trim(p ->> 'name'), 80),
          nullif(left(trim(p ->> 'phone'), 30), ''), nullif(left(trim(p ->> 'address'), 200), ''),
          nullif(left(trim(p ->> 'note'), 300), ''), v_items, v_sub, v_del, v_sub + v_del)
  returning numero into v_num;

  return jsonb_build_object('numero', v_num, 'total', v_sub + v_del);
end $$;

-- 6. Suivre sa commande avec son numéro (ne renvoie que l'état, aucune donnée personnelle)
create or replace function public.dore_track(p_numero text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('numero', numero, 'status', status, 'mode', mode, 'table_no', table_no, 'created_at', created_at)
  from dore_orders where numero = upper(trim(p_numero));
$$;

-- 7. Mise à jour automatique de updated_at
create or replace function public.dore_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists dore_touch on public.dore_orders;
create trigger dore_touch before update on public.dore_orders for each row execute function public.dore_touch();

grant execute on function public.dore_place_order(jsonb) to anon, authenticated;
grant execute on function public.dore_track(text) to anon, authenticated;
grant execute on function public.dore_is_staff() to authenticated;
revoke insert, delete on public.dore_orders from anon, authenticated;

-- 8. Temps réel : la page cuisine reçoit les nouvelles commandes instantanément
do $$ begin
  alter publication supabase_realtime add table public.dore_orders;
exception when duplicate_object then null; end $$;
