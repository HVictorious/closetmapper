-- Closet Mapper — Supabase schema
-- Paste this whole file into Supabase ▸ SQL Editor ▸ New query, and click Run. Safe to run again.

-- ---------- tables ----------
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create table if not exists public.members (
  team_id uuid not null references public.teams on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  email text,
  role text not null default 'editor' check (role in ('owner','editor','viewer')),
  created_at timestamptz not null default now(),
  primary key (team_id, user_id)
);
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams on delete cascade,
  email text not null,
  role text not null default 'editor' check (role in ('editor','viewer')),
  invited_by uuid references auth.users on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (team_id, email)
);
-- the whole map of a team is one JSON document; version stops two saves from overwriting each other
create table if not exists public.maps (
  team_id uuid primary key references public.teams on delete cascade,
  data jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users on delete set null
);
-- tiny row per team that changes on every save; the app listens to it for live updates
create table if not exists public.map_heads (
  team_id uuid primary key references public.teams on delete cascade,
  version integer not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  updated_by_email text
);

-- ---------- helpers ----------
create or replace function public.my_role(t uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where team_id = t and user_id = auth.uid()
$$;
create or replace function public.my_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email','')) $$;

-- create a team: you become its owner and it gets an empty map
create or replace function public.create_team(team_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into teams(name, created_by) values (coalesce(nullif(trim(team_name),''),'My team'), auth.uid()) returning id into t;
  insert into members(team_id, user_id, email, role) values (t, auth.uid(), my_email(), 'owner');
  insert into maps(team_id, data, updated_by) values (t, '{}'::jsonb, auth.uid());
  insert into map_heads(team_id, updated_by, updated_by_email) values (t, auth.uid(), my_email());
  return t;
end $$;

-- join every team that invited your email address
create or replace function public.accept_invites() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer := 0; r record;
begin
  if auth.uid() is null then return 0; end if;
  for r in select * from invites where lower(email) = my_email() loop
    insert into members(team_id, user_id, email, role) values (r.team_id, auth.uid(), my_email(), r.role)
      on conflict (team_id, user_id) do nothing;
    delete from invites where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- save the map only if nobody saved since you loaded it; returns the new version, or -1 when someone else got there first
create or replace function public.save_map(t uuid, d jsonb, expected integer) returns integer
language plpgsql security definer set search_path = public as $$
declare v integer;
begin
  if coalesce(my_role(t),'') not in ('owner','editor') then raise exception 'You do not have edit access to this team'; end if;
  update maps set data = d, version = version + 1, updated_at = now(), updated_by = auth.uid()
    where team_id = t and version = expected returning version into v;
  if v is null then return -1; end if;
  insert into map_heads(team_id, version, updated_at, updated_by, updated_by_email) values (t, v, now(), auth.uid(), my_email())
    on conflict (team_id) do update set version = excluded.version, updated_at = excluded.updated_at, updated_by = excluded.updated_by, updated_by_email = excluded.updated_by_email;
  return v;
end $$;

-- leave a team (the last owner cannot leave)
create or replace function public.leave_team(t uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role(t) = 'owner' and (select count(*) from members where team_id = t and role = 'owner') = 1 then
    raise exception 'You are the only owner. Make someone else an owner first, or delete the team.';
  end if;
  delete from members where team_id = t and user_id = auth.uid();
end $$;

-- ---------- row level security ----------
alter table public.teams enable row level security;
alter table public.members enable row level security;
alter table public.invites enable row level security;
alter table public.maps enable row level security;
alter table public.map_heads enable row level security;

drop policy if exists teams_read on public.teams;
create policy teams_read on public.teams for select using (my_role(id) is not null);
drop policy if exists teams_owner_update on public.teams;
create policy teams_owner_update on public.teams for update using (my_role(id) = 'owner');
drop policy if exists teams_owner_delete on public.teams;
create policy teams_owner_delete on public.teams for delete using (my_role(id) = 'owner');

drop policy if exists members_read on public.members;
create policy members_read on public.members for select using (my_role(team_id) is not null);
drop policy if exists members_owner_update on public.members;
create policy members_owner_update on public.members for update using (my_role(team_id) = 'owner');
drop policy if exists members_owner_delete on public.members;
create policy members_owner_delete on public.members for delete using (my_role(team_id) = 'owner');

drop policy if exists invites_read on public.invites;
create policy invites_read on public.invites for select using (my_role(team_id) = 'owner' or lower(email) = my_email());
drop policy if exists invites_owner_insert on public.invites;
create policy invites_owner_insert on public.invites for insert with check (my_role(team_id) = 'owner');
drop policy if exists invites_owner_delete on public.invites;
create policy invites_owner_delete on public.invites for delete using (my_role(team_id) = 'owner');

drop policy if exists maps_read on public.maps;
create policy maps_read on public.maps for select using (my_role(team_id) is not null);
drop policy if exists heads_read on public.map_heads;
create policy heads_read on public.map_heads for select using (my_role(team_id) is not null);

-- ---------- live updates ----------
do $$ begin
  begin alter publication supabase_realtime add table public.map_heads; exception when duplicate_object then null; end;
end $$;

-- ---------- photo storage ----------
insert into storage.buckets (id, name, public) values ('photos','photos', false) on conflict (id) do nothing;
drop policy if exists photos_read on storage.objects;
create policy photos_read on storage.objects for select
  using (bucket_id = 'photos' and public.my_role(((storage.foldername(name))[1])::uuid) is not null);
drop policy if exists photos_write on storage.objects;
create policy photos_write on storage.objects for insert
  with check (bucket_id = 'photos' and public.my_role(((storage.foldername(name))[1])::uuid) in ('owner','editor'));
drop policy if exists photos_update on storage.objects;
create policy photos_update on storage.objects for update
  using (bucket_id = 'photos' and public.my_role(((storage.foldername(name))[1])::uuid) in ('owner','editor'));
drop policy if exists photos_delete on storage.objects;
create policy photos_delete on storage.objects for delete
  using (bucket_id = 'photos' and public.my_role(((storage.foldername(name))[1])::uuid) in ('owner','editor'));

grant execute on function public.create_team(text), public.accept_invites(), public.save_map(uuid, jsonb, integer), public.leave_team(uuid), public.my_role(uuid) to authenticated;

-- ---------- v4 additions (names, private presence channels) ----------

-- ---------- names ----------
alter table public.members add column if not exists name text;
alter table public.map_heads add column if not exists updated_by_name text;

create or replace function public.my_name() returns text
language sql stable as $$
  select nullif(trim(coalesce(auth.jwt() -> 'user_metadata' ->> 'name', auth.jwt() -> 'user_metadata' ->> 'full_name', '')), '')
$$;

-- the app calls this after you sign in or change your name; it updates you in every team you belong to
create or replace function public.set_my_name(n text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update members set name = nullif(left(trim(n), 60), '') where user_id = auth.uid();
end $$;

create or replace function public.create_team(team_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into teams(name, created_by) values (coalesce(nullif(trim(team_name),''),'My team'), auth.uid()) returning id into t;
  insert into members(team_id, user_id, email, role, name) values (t, auth.uid(), my_email(), 'owner', my_name());
  insert into maps(team_id, data, updated_by) values (t, '{}'::jsonb, auth.uid());
  insert into map_heads(team_id, updated_by, updated_by_email, updated_by_name) values (t, auth.uid(), my_email(), my_name());
  return t;
end $$;

create or replace function public.accept_invites() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer := 0; r record;
begin
  if auth.uid() is null then return 0; end if;
  for r in select * from invites where lower(email) = my_email() loop
    insert into members(team_id, user_id, email, role, name) values (r.team_id, auth.uid(), my_email(), r.role, my_name())
      on conflict (team_id, user_id) do nothing;
    delete from invites where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.save_map(t uuid, d jsonb, expected integer) returns integer
language plpgsql security definer set search_path = public as $$
declare v integer; nm text;
begin
  if coalesce(my_role(t),'') not in ('owner','editor') then raise exception 'You do not have edit access to this team'; end if;
  update maps set data = d, version = version + 1, updated_at = now(), updated_by = auth.uid()
    where team_id = t and version = expected returning version into v;
  if v is null then return -1; end if;
  select coalesce(name, my_name()) into nm from members where team_id = t and user_id = auth.uid();
  insert into map_heads(team_id, version, updated_at, updated_by, updated_by_email, updated_by_name) values (t, v, now(), auth.uid(), my_email(), nm)
    on conflict (team_id) do update set version = excluded.version, updated_at = excluded.updated_at, updated_by = excluded.updated_by,
      updated_by_email = excluded.updated_by_email, updated_by_name = excluded.updated_by_name;
  return v;
end $$;

grant execute on function public.set_my_name(text), public.my_name() to authenticated;

-- ---------- private live channels: only members of a team can see who is in its closets ----------
-- the app joins the channel "team:<team id>"
drop policy if exists cm_presence_read on realtime.messages;
create policy cm_presence_read on realtime.messages for select to authenticated
  using (realtime.topic() like 'team:%' and public.my_role(nullif(split_part(realtime.topic(), ':', 2), '')::uuid) is not null);
drop policy if exists cm_presence_write on realtime.messages;
create policy cm_presence_write on realtime.messages for insert to authenticated
  with check (realtime.topic() like 'team:%' and public.my_role(nullif(split_part(realtime.topic(), ':', 2), '')::uuid) is not null);
