-- PulseApp · Comunidad (equipos, chat y clasificaciones entre amigos)
-- Pegar entero en Supabase → SQL Editor → New query → Run. Se puede ejecutar más de una vez sin romper nada.

-- ---------- Tablas ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  username text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  invite_code text not null unique,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

-- Un resumen por persona y día (fecha local): lo que se ve en Esfuerzo, Recuperación y Sueño
create table if not exists public.day_stats (
  user_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  strain real,
  kcal integer,
  activities jsonb not null default '[]'::jsonb,
  recovery integer,
  hrv integer,
  rhr integer,
  sleep_minutes integer,
  sleep_score integer,
  updated_at timestamptz not null default now(),
  primary key (user_id, date)
);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists messages_team_time on public.messages(team_id, id);

-- ---------- Ayudas para los permisos ----------
create or replace function public.is_member(t uuid) returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from team_members where team_id = t and user_id = auth.uid());
$$;

create or replace function public.shares_team(u uuid) returns boolean
language sql security definer set search_path = public stable as $$
  select u = auth.uid() or exists (
    select 1 from team_members a join team_members b on a.team_id = b.team_id
    where a.user_id = auth.uid() and b.user_id = u);
$$;

-- ---------- Permisos (cada uno solo ve a la gente de sus equipos) ----------
alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.day_stats enable row level security;
alter table public.messages enable row level security;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (public.shares_team(id));
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists teams_select on public.teams;
drop policy if exists teams_update on public.teams;
create policy teams_select on public.teams for select to authenticated using (public.is_member(id));
create policy teams_update on public.teams for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());

drop policy if exists members_select on public.team_members;
drop policy if exists members_delete on public.team_members;
create policy members_select on public.team_members for select to authenticated using (public.is_member(team_id));
-- Salir del equipo (uno mismo) o echar a alguien (quien creó el equipo)
create policy members_delete on public.team_members for delete to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.teams t where t.id = team_id and t.created_by = auth.uid()));

drop policy if exists stats_select on public.day_stats;
drop policy if exists stats_insert on public.day_stats;
drop policy if exists stats_update on public.day_stats;
create policy stats_select on public.day_stats for select to authenticated using (public.shares_team(user_id));
create policy stats_insert on public.day_stats for insert to authenticated with check (user_id = auth.uid());
create policy stats_update on public.day_stats for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists messages_select on public.messages;
drop policy if exists messages_insert on public.messages;
create policy messages_select on public.messages for select to authenticated using (public.is_member(team_id));
create policy messages_insert on public.messages for insert to authenticated with check (user_id = auth.uid() and public.is_member(team_id));

-- ---------- Crear equipo y unirse con el código ----------
create or replace function public.create_team(p_name text) returns public.teams
language plpgsql security definer set search_path = public as $$
declare
  code text;
  t public.teams;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  loop
    code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from teams where invite_code = code);
  end loop;
  insert into teams(name, invite_code, created_by) values (trim(p_name), code, auth.uid()) returning * into t;
  insert into team_members(team_id, user_id, role) values (t.id, auth.uid(), 'admin');
  return t;
end;
$$;

create or replace function public.join_team(p_code text) returns public.teams
language plpgsql security definer set search_path = public as $$
declare
  t public.teams;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  select * into t from teams where invite_code = upper(trim(p_code));
  if not found then raise exception 'Código no válido'; end if;
  insert into team_members(team_id, user_id) values (t.id, auth.uid()) on conflict do nothing;
  return t;
end;
$$;

revoke all on function public.create_team(text) from public, anon;
revoke all on function public.join_team(text) from public, anon;
grant execute on function public.create_team(text) to authenticated;
grant execute on function public.join_team(text) to authenticated;
grant execute on function public.is_member(uuid) to authenticated;
grant execute on function public.shares_team(uuid) to authenticated;
