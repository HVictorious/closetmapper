-- Closet Mapper v4 — database update
-- Paste this whole file into Supabase ▸ SQL Editor ▸ New query, and click Run. Safe to run more than once.
-- Adds: people's names, names on "updated by", and private live channels for "who is in which closet".

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
