-- İşeme Takvimi veritabanı kurulumu (Supabase SQL Editor'de bir kez çalıştırılır)

create table if not exists public.players (
  id text primary key check (char_length(id) between 8 and 64),
  nick text not null check (char_length(nick) between 1 and 24),
  avatar text check (avatar is null or char_length(avatar) <= 32),
  updated_at timestamptz not null default now()
);

create table if not exists public.pees (
  id uuid primary key default gen_random_uuid(),
  player_id text not null references public.players(id) on delete cascade,
  day smallint not null check (day between 0 and 6),
  hour smallint not null check (hour between 0 and 23),
  minute smallint not null check (minute between 0 and 59),
  ts bigint not null,
  note text check (note is null or char_length(note) <= 200),
  created_at timestamptz not null default now()
);

create index if not exists pees_ts_idx on public.pees (ts);

alter table public.players enable row level security;
alter table public.pees enable row level security;

-- Hesapsız kullanım: linki bilen herkes okur ve yazar.
drop policy if exists players_select on public.players;
drop policy if exists players_insert on public.players;
drop policy if exists players_update on public.players;
create policy players_select on public.players for select to anon using (true);
create policy players_insert on public.players for insert to anon with check (true);
create policy players_update on public.players for update to anon using (true) with check (true);

drop policy if exists pees_select on public.pees;
drop policy if exists pees_insert on public.pees;
drop policy if exists pees_delete on public.pees;
create policy pees_select on public.pees for select to anon using (true);
create policy pees_insert on public.pees for insert to anon with check (ts <= (extract(epoch from now()) * 1000)::bigint + 600000);
create policy pees_delete on public.pees for delete to anon using (true);

grant select, insert, update on public.players to anon;
grant select, insert, delete on public.pees to anon;

-- Canlı güncellemeler
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'players') then
    alter publication supabase_realtime add table public.players;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pees') then
    alter publication supabase_realtime add table public.pees;
  end if;
end $$;
