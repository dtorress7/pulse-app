-- PulseApp · Datos de los amigos para calibrar (23/11)
-- Cada móvil sube sus archivos (pulso, movimiento, pasos de la pulsera, ediciones de sueño) a una carpeta privada con su ID.
-- Solo el ADMINISTRADOR (tú) puede descargar las carpetas de los demás. Cada persona solo puede escribir en la suya.
-- Pegar entero en Supabase → SQL Editor → New query → Run. Se puede ejecutar más de una vez sin romper nada.

-- Almacén privado (no público)
insert into storage.buckets (id, name, public, file_size_limit)
values ('pulse-data', 'pulse-data', false, 52428800)
on conflict (id) do nothing;

-- Quién es el administrador (el primero que lo pide desde la app, y solo si aún no hay ninguno)
create table if not exists public.data_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.data_admins enable row level security;
drop policy if exists "admin se ve a sí mismo" on public.data_admins;
create policy "admin se ve a sí mismo" on public.data_admins for select to authenticated using (user_id = auth.uid());

create or replace function public.claim_data_admin() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.data_admins where user_id = auth.uid()) then return true; end if;
  if exists (select 1 from public.data_admins) then return false; end if;
  insert into public.data_admins(user_id) values (auth.uid());
  return true;
end $$;
grant execute on function public.claim_data_admin() to authenticated;

create or replace function public.is_data_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.data_admins where user_id = auth.uid());
$$;
grant execute on function public.is_data_admin() to authenticated;

-- Reglas del almacén: cada uno sube y actualiza solo en su carpeta; ver: lo suyo, o todo si es administrador
drop policy if exists "pulse-data subir lo mío" on storage.objects;
create policy "pulse-data subir lo mío" on storage.objects for insert to authenticated
  with check (bucket_id = 'pulse-data' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "pulse-data actualizar lo mío" on storage.objects;
create policy "pulse-data actualizar lo mío" on storage.objects for update to authenticated
  using (bucket_id = 'pulse-data' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "pulse-data ver lo mío o admin" on storage.objects;
create policy "pulse-data ver lo mío o admin" on storage.objects for select to authenticated
  using (bucket_id = 'pulse-data' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_data_admin()));
