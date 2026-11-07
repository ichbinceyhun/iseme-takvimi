-- İşeme Takvimi veritabanı kurulumu.
-- Supabase SQL Editor'de çalıştırılır. Tekrar çalıştırmak güvenlidir; var olan kayıtlar silinmez.

create extension if not exists pgcrypto with schema extensions;

-- Tablolar ------------------------------------------------------------------

create table if not exists public.players (
  id text primary key check (char_length(id) between 8 and 64),
  nick text not null check (char_length(btrim(nick)) between 1 and 24),
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
create index if not exists pees_player_idx on public.pees (player_id);

-- Değişiklik sırası: site yalnızca son gördüğü numaradan sonrakileri çeker
create sequence if not exists public.sync_seq;
alter table public.pees add column if not exists seq bigint;
alter table public.pees alter column seq set default nextval('public.sync_seq');
update public.pees set seq = nextval('public.sync_seq') where seq is null;
alter table public.pees alter column seq set not null;
create index if not exists pees_seq_idx on public.pees (seq);

create table if not exists public.pee_deletions (
  seq bigint primary key default nextval('public.sync_seq'),
  pee_id uuid not null,
  deleted_at timestamptz not null default now()
);

-- Aynı isimde iki profil olmasın (büyük/küçük harf fark etmez)
create unique index if not exists players_nick_unique on public.players (lower(btrim(nick)));

-- Gizli tablolar: şifre özetleri ve cihaz anahtarları. Siteden okunamaz.
create table if not exists public.player_secrets (
  player_id text primary key references public.players(id) on delete cascade,
  pin_hash text not null,
  failed_attempts int not null default 0,
  locked_until timestamptz
);

create table if not exists public.devices (
  token_hash text primary key,
  player_id text not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Yöneticiler (profil kimliği). Siteden okunamaz; yönetici SQL ile eklenir.
create table if not exists public.admins (
  player_id text primary key references public.players(id) on delete cascade
);

-- Erişim kuralları ------------------------------------------------------------

alter table public.players enable row level security;
alter table public.pees enable row level security;
alter table public.player_secrets enable row level security;
alter table public.devices enable row level security;
alter table public.pee_deletions enable row level security;
alter table public.admins enable row level security;

-- Tablolara doğrudan erişim tamamen kapalı. Okuma ve yazma yalnızca
-- aşağıdaki fonksiyonlarla ve giriş yapmış bir cihazla yapılır.
drop policy if exists players_select on public.players;
drop policy if exists pees_select on public.pees;
drop policy if exists players_insert on public.players;
drop policy if exists players_update on public.players;
drop policy if exists pees_insert on public.pees;
drop policy if exists pees_delete on public.pees;
revoke all on public.players, public.pees from anon, authenticated;
revoke all on public.player_secrets, public.devices, public.pee_deletions, public.admins from anon, authenticated;
revoke all on sequence public.sync_seq from anon, authenticated;

-- Yardımcı fonksiyonlar (siteden çağrılamaz) ----------------------------------

create or replace function public._token_hash(p_token text)
returns text language sql immutable set search_path = ''
as $$ select encode(extensions.digest(p_token, 'sha256'), 'hex') $$;

create or replace function public._player_for(p_token text)
returns text language sql stable security definer set search_path = ''
as $$
  select d.player_id from public.devices d
  where char_length(coalesce(p_token, '')) >= 32 and d.token_hash = public._token_hash(p_token)
$$;

create or replace function public._check_input(p_token text, p_pin text)
returns void language plpgsql immutable set search_path = ''
as $$
begin
  if char_length(coalesce(p_token, '')) < 32 then raise exception 'gecersiz_cihaz'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'gecersiz_sifre'; end if;
end $$;

create or replace function public._admin_for(p_token text)
returns text language sql stable security definer set search_path = ''
as $$ select a.player_id from public.admins a where a.player_id = public._player_for(p_token) $$;

revoke execute on function public._admin_for(text) from public, anon, authenticated;
revoke execute on function public._token_hash(text) from public, anon, authenticated;
revoke execute on function public._player_for(text) from public, anon, authenticated;
revoke execute on function public._check_input(text, text) from public, anon, authenticated;

-- Sitenin çağırdığı fonksiyonlar ---------------------------------------------

-- Bu cihaz kimin?
create or replace function public.whoami(p_token text)
returns text language sql stable security definer set search_path = ''
as $$ select public._player_for(p_token) $$;

-- Yeni profil: ad + avatar + 4 haneli şifre
create or replace function public.register_player(p_token text, p_nick text, p_avatar text, p_pin text)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_id text := gen_random_uuid()::text;
begin
  perform public._check_input(p_token, p_pin);
  if exists (select 1 from public.devices where token_hash = public._token_hash(p_token)) then
    raise exception 'cihaz_kayitli';
  end if;
  insert into public.players (id, nick, avatar) values (v_id, btrim(p_nick), p_avatar);
  insert into public.player_secrets (player_id, pin_hash) values (v_id, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  insert into public.devices (token_hash, player_id) values (public._token_hash(p_token), v_id);
  return v_id;
end $$;

-- Şifre sisteminden önce açılmış profile ilk kez şifre koymak (yalnızca şifresi yoksa)
create or replace function public.secure_existing(p_player_id text, p_token text, p_pin text)
returns boolean language plpgsql security definer set search_path = ''
as $$
begin
  perform public._check_input(p_token, p_pin);
  if not exists (select 1 from public.players where id = p_player_id) then return false; end if;
  if exists (select 1 from public.player_secrets where player_id = p_player_id) then return false; end if;
  insert into public.player_secrets (player_id, pin_hash) values (p_player_id, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  insert into public.devices (token_hash, player_id) values (public._token_hash(p_token), p_player_id)
    on conflict (token_hash) do update set player_id = excluded.player_id;
  return true;
end $$;

-- Başka cihazdan giriş: adına dokun + şifre.
-- 5 yanlışta 15 dakika, 10 yanlışta 24 saat kilit. Doğru şifre sayacı sıfırlar.
create or replace function public.claim_player(p_player_id text, p_token text, p_pin text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare s public.player_secrets%rowtype;
begin
  if char_length(coalesce(p_token, '')) < 32 then raise exception 'gecersiz_cihaz'; end if;
  select * into s from public.player_secrets where player_id = p_player_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'sifresiz'); end if;
  if s.locked_until is not null and s.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'kilitli', 'until', s.locked_until);
  end if;
  if coalesce(p_pin, '') ~ '^[0-9]{4}$' and s.pin_hash = extensions.crypt(p_pin, s.pin_hash) then
    update public.player_secrets set failed_attempts = 0, locked_until = null where player_id = p_player_id;
    insert into public.devices (token_hash, player_id) values (public._token_hash(p_token), p_player_id)
      on conflict (token_hash) do update set player_id = excluded.player_id;
    return jsonb_build_object('ok', true);
  end if;
  s.failed_attempts := s.failed_attempts + 1;
  if s.failed_attempts % 5 = 0 then
    s.locked_until := now() + case when s.failed_attempts >= 10 then interval '24 hours' else interval '15 minutes' end;
  end if;
  update public.player_secrets set failed_attempts = s.failed_attempts, locked_until = s.locked_until where player_id = p_player_id;
  if s.locked_until is not null and s.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'kilitli', 'until', s.locked_until);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'yanlis', 'left', 5 - (s.failed_attempts % 5));
end $$;

-- Ada ve şifreye göre giriş (isim listesi gösterilmeden)
create or replace function public.login(p_nick text, p_token text, p_pin text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_id text; r jsonb;
begin
  select id into v_id from public.players
    where lower(translate(btrim(nick), 'İIı', 'iii')) = lower(translate(btrim(coalesce(p_nick, '')), 'İIı', 'iii'))
    limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'reason', 'yanlis'); end if;
  r := public.claim_player(v_id, p_token, p_pin);
  return r - 'left';
end $$;

-- Şifre sisteminden önce açılmış ve henüz şifresi olmayan profilin adı
create or replace function public.legacy_status(p_player_id text)
returns text language sql stable security definer set search_path = ''
as $$
  select p.nick from public.players p
  where p.id = p_player_id
    and not exists (select 1 from public.player_secrets s where s.player_id = p.id)
$$;

-- Giriş yapmış cihaz için veriler. p_since verilirse yalnızca o numaradan
-- sonraki eklemeler ve silmeler döner; değişiklik yoksa cevap çok küçüktür.
drop function if exists public.fetch_data(text);
create or replace function public.fetch_data(p_token text, p_since bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_since bigint := greatest(coalesce(p_since, 0), 0);
begin
  if public._player_for(p_token) is null then return null; end if;
  return jsonb_build_object(
    'admin', public._admin_for(p_token) is not null,
    'seq', greatest(
      coalesce((select max(seq) from public.pees), 0),
      coalesce((select max(seq) from public.pee_deletions), 0)),
    'total', (select count(*) from public.pees),
    'players', coalesce((select jsonb_agg(jsonb_build_array(id, nick, avatar)) from public.players), '[]'::jsonb),
    'pees', coalesce((select jsonb_agg(jsonb_build_array(id, player_id, day, hour, minute, ts, note))
                      from public.pees where seq > v_since), '[]'::jsonb),
    'deleted', case when v_since = 0 then '[]'::jsonb else
      coalesce((select jsonb_agg(pee_id) from public.pee_deletions where seq > v_since), '[]'::jsonb) end
  );
end $$;

-- Kendi profilini düzenle
create or replace function public.update_profile(p_token text, p_nick text, p_avatar text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token);
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  update public.players set nick = btrim(p_nick), avatar = p_avatar, updated_at = now() where id = v_player;
end $$;

-- İşeme ekle (yalnızca kendi adına)
create or replace function public.add_pee(p_token text, p_day int, p_hour int, p_minute int, p_ts bigint, p_note text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_id uuid;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  if p_ts > (extract(epoch from now()) * 1000)::bigint + 600000 then raise exception 'gelecek_tarih'; end if;
  insert into public.pees (player_id, day, hour, minute, ts, note)
    values (v_player, p_day, p_hour, p_minute, p_ts, nullif(btrim(coalesce(p_note, '')), ''))
    returning id into v_id;
  return v_id;
end $$;

-- İşeme sil (yalnızca kendi kaydını)
create or replace function public.delete_pee(p_token text, p_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token);
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  delete from public.pees where id = p_id and (player_id = v_player or public._admin_for(p_token) is not null);
  if found then
    insert into public.pee_deletions (pee_id) values (p_id);
    return true;
  end if;
  return false;
end $$;

-- Yönetici işlemleri --------------------------------------------------------

create or replace function public.admin_update_pee(p_token text, p_id uuid, p_day int, p_hour int, p_minute int, p_ts bigint, p_note text)
returns boolean language plpgsql security definer set search_path = ''
as $$
begin
  if public._admin_for(p_token) is null then raise exception 'yetkisiz'; end if;
  if p_ts > (extract(epoch from now()) * 1000)::bigint + 600000 then raise exception 'gelecek_tarih'; end if;
  update public.pees
    set day = p_day, hour = p_hour, minute = p_minute, ts = p_ts,
        note = nullif(btrim(coalesce(p_note, '')), ''), seq = nextval('public.sync_seq')
    where id = p_id;
  return found;
end $$;

create or replace function public.admin_update_player(p_token text, p_player_id text, p_nick text, p_avatar text)
returns boolean language plpgsql security definer set search_path = ''
as $$
begin
  if public._admin_for(p_token) is null then raise exception 'yetkisiz'; end if;
  update public.players set nick = btrim(p_nick), avatar = p_avatar, updated_at = now() where id = p_player_id;
  return found;
end $$;

create or replace function public.admin_reset_pin(p_token text, p_player_id text, p_pin text)
returns boolean language plpgsql security definer set search_path = ''
as $$
begin
  if public._admin_for(p_token) is null then raise exception 'yetkisiz'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'gecersiz_sifre'; end if;
  if not exists (select 1 from public.players where id = p_player_id) then return false; end if;
  insert into public.player_secrets (player_id, pin_hash) values (p_player_id, extensions.crypt(p_pin, extensions.gen_salt('bf')))
    on conflict (player_id) do update set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
  return true;
end $$;

create or replace function public.admin_delete_player(p_token text, p_player_id text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_for(p_token);
begin
  if v_admin is null then raise exception 'yetkisiz'; end if;
  if v_admin = p_player_id then raise exception 'kendini_silemezsin'; end if;
  insert into public.pee_deletions (pee_id) select id from public.pees where player_id = p_player_id;
  delete from public.players where id = p_player_id;
  return found;
end $$;

revoke execute on function public.admin_update_pee(text, uuid, int, int, int, bigint, text) from public;
revoke execute on function public.admin_update_player(text, text, text, text) from public;
revoke execute on function public.admin_reset_pin(text, text, text) from public;
revoke execute on function public.admin_delete_player(text, text) from public;
grant execute on function public.admin_update_pee(text, uuid, int, int, int, bigint, text) to anon, authenticated;
grant execute on function public.admin_update_player(text, text, text, text) to anon, authenticated;
grant execute on function public.admin_reset_pin(text, text, text) to anon, authenticated;
grant execute on function public.admin_delete_player(text, text) to anon, authenticated;

revoke execute on function public.login(text, text, text) from public;
revoke execute on function public.legacy_status(text) from public;
revoke execute on function public.fetch_data(text, bigint) from public;
grant execute on function public.login(text, text, text) to anon, authenticated;
grant execute on function public.legacy_status(text) to anon, authenticated;
grant execute on function public.fetch_data(text, bigint) to anon, authenticated;
revoke execute on function public.whoami(text) from public;
revoke execute on function public.register_player(text, text, text, text) from public;
revoke execute on function public.secure_existing(text, text, text) from public;
revoke execute on function public.claim_player(text, text, text) from public;
revoke execute on function public.update_profile(text, text, text) from public;
revoke execute on function public.add_pee(text, int, int, int, bigint, text) from public;
revoke execute on function public.delete_pee(text, uuid) from public;
grant execute on function public.whoami(text) to anon, authenticated;
grant execute on function public.register_player(text, text, text, text) to anon, authenticated;
grant execute on function public.secure_existing(text, text, text) to anon, authenticated;
revoke execute on function public.claim_player(text, text, text) from anon, authenticated;
grant execute on function public.update_profile(text, text, text) to anon, authenticated;
grant execute on function public.add_pee(text, int, int, int, bigint, text) to anon, authenticated;
grant execute on function public.delete_pee(text, uuid) to anon, authenticated;

-- Canlı güncellemeler kapalı (site 30 saniyede bir yeniler)
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'players') then
    alter publication supabase_realtime drop table public.players;
  end if;
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pees') then
    alter publication supabase_realtime drop table public.pees;
  end if;
end $$;
