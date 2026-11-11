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
alter table public.devices add column if not exists last_seen timestamptz;
alter table public.devices add column if not exists last_ip text;
alter table public.devices add column if not exists last_ua text;

-- Yöneticiler. Siteden okunamaz; yönetici SQL ile eklenir.
-- Kumanda paneli için ayrıca en az 10 karakterli bir yönetici şifresi gerekir.
create table if not exists public.admins (
  player_id text primary key references public.players(id) on delete cascade
);
alter table public.admins add column if not exists pass_hash text;
alter table public.admins add column if not exists failed_attempts int not null default 0;
alter table public.admins add column if not exists locked_until timestamptz;

-- Kumanda paneli oturumları (30 dakika işlem yapılmazsa biter)
create table if not exists public.admin_sessions (
  token_hash text primary key,
  player_id text not null references public.admins(player_id) on delete cascade,
  device_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

-- Olay kayıtları: kim, ne zaman, ne yaptı, hangi IP ve cihazdan
create table if not exists public.audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  player_id text,
  nick text,
  event text not null,
  detail jsonb,
  ip text,
  user_agent text,
  device text
);
create index if not exists audit_log_at_idx on public.audit_log (at);
create index if not exists audit_log_event_ip_idx on public.audit_log (event, ip, at);
create index if not exists audit_log_event_player_idx on public.audit_log (event, player_id, at);

-- Görünen ad: yöneticinin koyduğu ad. Boşsa kişinin kendi adı (giriş adı) görünür.
alter table public.players add column if not exists display_nick text
  check (display_nick is null or char_length(btrim(display_nick)) between 1 and 24);

-- Tek seferlik düzeltme: yönetici değişikliğiyle kayan giriş adını eski haline getir
update public.players set nick = 'işeyicipromax', display_nick = 'işeyicipromax dbe'
  where id = 'bc74063c-bd20-40e8-87f9-4fa628afb18f' and nick = 'işeyicipromax dbe' and display_nick is null;

-- Kişisel davet kodları ve kimin kimi davet ettiği
alter table public.players add column if not exists invited_by text references public.players(id) on delete set null;
create table if not exists public.invites (
  player_id text primary key references public.players(id) on delete cascade,
  code text not null unique,
  created_at timestamptz not null default now()
);

-- Tepkiler ve yorumlar
create table if not exists public.reactions (
  pee_id uuid not null references public.pees(id) on delete cascade,
  player_id text not null references public.players(id) on delete cascade,
  emoji text not null check (emoji in ('su', 'gul', 'tac', 'ates', 'igrenc')),
  created_at timestamptz not null default now(),
  primary key (pee_id, player_id, emoji)
);
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  pee_id uuid not null references public.pees(id) on delete cascade,
  player_id text not null references public.players(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 200),
  created_at timestamptz not null default now()
);
create index if not exists comments_pee_idx on public.comments (pee_id, created_at);

-- Site ayarları (yöneticinin genel davet kodu). Siteden okunamaz.
create table if not exists public.settings (
  key text primary key,
  value text not null
);
insert into public.settings (key, value)
  values ('invite_code', upper(encode(extensions.gen_random_bytes(5), 'hex')))
  on conflict (key) do nothing;
create index if not exists audit_log_player_idx on public.audit_log (player_id, id);

-- Erişim kuralları ------------------------------------------------------------

alter table public.players enable row level security;
alter table public.pees enable row level security;
alter table public.player_secrets enable row level security;
alter table public.devices enable row level security;
alter table public.pee_deletions enable row level security;
alter table public.admins enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.audit_log enable row level security;
alter table public.settings enable row level security;
alter table public.invites enable row level security;
alter table public.reactions enable row level security;
alter table public.comments enable row level security;

-- Tablolara doğrudan erişim tamamen kapalı. Okuma ve yazma yalnızca
-- aşağıdaki fonksiyonlarla ve giriş yapmış bir cihazla yapılır.
drop policy if exists players_select on public.players;
drop policy if exists pees_select on public.pees;
drop policy if exists players_insert on public.players;
drop policy if exists players_update on public.players;
drop policy if exists pees_insert on public.pees;
drop policy if exists pees_delete on public.pees;
revoke all on public.players, public.pees from anon, authenticated;
revoke all on public.player_secrets, public.devices, public.pee_deletions, public.admins,
  public.admin_sessions, public.audit_log, public.settings, public.invites, public.reactions, public.comments from anon, authenticated;
revoke all on sequence public.sync_seq from anon, authenticated;
revoke all on sequence public.audit_log_id_seq from anon, authenticated;

-- Eski sürümlerden kalan, yönetici oturumu istemeyen fonksiyonları kaldır
drop function if exists public.admin_update_pee(text, uuid, int, int, int, bigint, text);
drop function if exists public.admin_update_player(text, text, text, text);
drop function if exists public.admin_reset_pin(text, text, text);
drop function if exists public.admin_delete_player(text, text);
drop function if exists public.register_player(text, text, text, text);

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

-- İsteği yapanın IP adresi ve tarayıcı bilgisi (Supabase'in ilettiği başlıklardan)
create or replace function public._req(p_key text)
returns text language plpgsql stable set search_path = ''
as $$
declare h jsonb; v text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then h := null;
  end;
  if h is null then return null; end if;
  if p_key = 'ip' then
    v := coalesce(h->>'cf-connecting-ip', btrim(split_part(h->>'x-forwarded-for', ',', 1)), h->>'x-real-ip');
  else
    v := h->>'user-agent';
  end if;
  return left(nullif(v, ''), 400);
end $$;

-- Olay kaydı yaz. Arada bir 180 günden eski kayıtları temizler.
create or replace function public._log(p_event text, p_player text, p_token text, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.audit_log (player_id, nick, event, detail, ip, user_agent, device)
  values (
    p_player,
    (select coalesce(display_nick, nick) from public.players where id = p_player),
    p_event,
    p_detail,
    public._req('ip'),
    public._req('ua'),
    case when char_length(coalesce(p_token, '')) >= 32 then left(public._token_hash(p_token), 8) end
  );
  if random() < 0.01 then
    delete from public.audit_log where at < now() - interval '180 days';
  end if;
end $$;

-- Kumanda paneli oturumu geçerli mi? Geçerliyse süresini uzatır, yönetici kimliğini döner.
create or replace function public._admin_ok(p_token text, p_session text)
returns text language plpgsql security definer set search_path = ''
as $$
declare v text;
begin
  select s.player_id into v
  from public.admin_sessions s
  where s.token_hash = public._token_hash(coalesce(p_session, ''))
    and s.device_hash = public._token_hash(coalesce(p_token, ''))
    and s.expires_at > now()
    and s.player_id = public._admin_for(p_token);
  if v is null then raise exception 'yonetici_oturumu'; end if;
  update public.admin_sessions set expires_at = now() + interval '30 minutes'
    where token_hash = public._token_hash(p_session);
  return v;
end $$;

-- Bu IP'den son p_window içinde p_events olaylarından kaç tane yazıldı?
create or replace function public._ip_count(p_events text[], p_window interval)
returns int language sql stable security definer set search_path = ''
as $$
  select count(*)::int from public.audit_log
  where event = any(p_events) and ip = public._req('ip') and at > now() - p_window
$$;

-- Bu kişi için son p_window içinde p_event olayından kaç tane yazıldı?
create or replace function public._player_count(p_event text, p_player text, p_window interval)
returns int language sql stable security definer set search_path = ''
as $$
  select count(*)::int from public.audit_log
  where event = p_event and player_id = p_player and at > now() - p_window
$$;

-- Ad kuralı: Türkçe harfler, rakamlar, boşluk ve . ' _ - (taklit ve görünmez karakterlere karşı)
create or replace function public._nick_ok(p_nick text)
returns boolean language sql immutable set search_path = ''
as $$ select coalesce(btrim(p_nick), '') ~ '^[A-Za-z0-9ÇĞİÖŞÜçğıöşüÂâÎîÛûÊêÔô .''''_-]{1,24}$' and btrim(p_nick) !~ '  ' $$;

-- Kayıt zamanından İstanbul saatine göre gün (Pzt=0), saat ve dakika
create or replace function public._slot(p_ts bigint, out day int, out hour int, out minute int)
language sql immutable set search_path = ''
as $$
  select (extract(isodow from l)::int - 1), extract(hour from l)::int, extract(minute from l)::int
  from (select (to_timestamp(p_ts / 1000.0) at time zone 'Europe/Istanbul') as l) x
$$;

revoke execute on function public._ip_count(text[], interval) from public, anon, authenticated;
revoke execute on function public._player_count(text, text, interval) from public, anon, authenticated;
revoke execute on function public._nick_ok(text) from public, anon, authenticated;
revoke execute on function public._slot(bigint) from public, anon, authenticated;
revoke execute on function public._admin_for(text) from public, anon, authenticated;
revoke execute on function public._token_hash(text) from public, anon, authenticated;
revoke execute on function public._player_for(text) from public, anon, authenticated;
revoke execute on function public._check_input(text, text) from public, anon, authenticated;
revoke execute on function public._req(text) from public, anon, authenticated;
revoke execute on function public._log(text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public._admin_ok(text, text) from public, anon, authenticated;

-- Sitenin çağırdığı fonksiyonlar ---------------------------------------------

-- Bu cihaz kimin? Cihazın son görülme bilgisini günceller, 10 dakikada bir "siteyi açtı" kaydı düşer.
create or replace function public.whoami(p_token text)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_player text; v_seen timestamptz;
begin
  select d.player_id, d.last_seen into v_player, v_seen
  from public.devices d
  where char_length(coalesce(p_token, '')) >= 32 and d.token_hash = public._token_hash(p_token);
  if v_player is null then return null; end if;
  if v_seen is null or v_seen < now() - interval '10 minutes' then
    update public.devices set last_seen = now(), last_ip = public._req('ip'), last_ua = public._req('ua')
      where token_hash = public._token_hash(p_token);
    perform public._log('visit', v_player, p_token);
  end if;
  return v_player;
end $$;

-- Yeni profil: ad + avatar + 4 haneli şifre + davet kodu.
-- Sonuç: {ok:true,id} ya da {ok:false,reason}. Reddedilen denemeler de kaydedilir.
create or replace function public.register_player(p_token text, p_nick text, p_avatar text, p_pin text, p_invite text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_id text := gen_random_uuid()::text; v_code text; v_inviter text; v_given text := upper(btrim(coalesce(p_invite, '')));
begin
  perform public._check_input(p_token, p_pin);
  if public._ip_count(array['register', 'register_fail'], interval '1 hour') >= 5
     or (select count(*) from public.audit_log where event = 'register' and at > now() - interval '1 hour') >= 30 then
    return jsonb_build_object('ok', false, 'reason', 'cok_fazla_istek');
  end if;
  select value into v_code from public.settings where key = 'invite_code';
  if v_given = '' or v_code is null or v_given <> v_code then
    select player_id into v_inviter from public.invites where code = v_given and v_given <> '';
    if v_inviter is null then
      perform public._log('register_fail', null, p_token, jsonb_build_object('reason', 'davet', 'nick', left(coalesce(p_nick, ''), 40)));
      return jsonb_build_object('ok', false, 'reason', 'davet_gecersiz');
    end if;
    -- Bir kişinin linkiyle günde en fazla 10 kayıt (link yayılırsa diye)
    if (select count(*) from public.audit_log
        where event = 'register' and detail->>'davet_eden' = v_inviter and at > now() - interval '1 day') >= 10 then
      return jsonb_build_object('ok', false, 'reason', 'davet_limit');
    end if;
  end if;
  if not public._nick_ok(p_nick) then
    return jsonb_build_object('ok', false, 'reason', 'gecersiz_ad');
  end if;
  if exists (select 1 from public.devices where token_hash = public._token_hash(p_token)) then
    return jsonb_build_object('ok', false, 'reason', 'cihaz_kayitli');
  end if;
  begin
    insert into public.players (id, nick, avatar, invited_by) values (v_id, btrim(p_nick), p_avatar, v_inviter);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'isim_alinmis');
  end;
  insert into public.player_secrets (player_id, pin_hash) values (v_id, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  insert into public.devices (token_hash, player_id, last_seen, last_ip, last_ua)
    values (public._token_hash(p_token), v_id, now(), public._req('ip'), public._req('ua'));
  perform public._log('register', v_id, p_token, jsonb_build_object('avatar', p_avatar, 'davet_eden', v_inviter,
    'davet_eden_ad', (select coalesce(display_nick, nick) from public.players where id = v_inviter)));
  return jsonb_build_object('ok', true, 'id', v_id);
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
  insert into public.devices (token_hash, player_id, last_seen, last_ip, last_ua)
    values (public._token_hash(p_token), p_player_id, now(), public._req('ip'), public._req('ua'))
    on conflict (token_hash) do update set player_id = excluded.player_id;
  perform public._log('secure', p_player_id, p_token);
  return true;
end $$;

-- Başka cihazdan giriş (yalnızca login() içinden çağrılır).
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
    insert into public.devices (token_hash, player_id, last_seen, last_ip, last_ua)
      values (public._token_hash(p_token), p_player_id, now(), public._req('ip'), public._req('ua'))
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
  if public._ip_count(array['login_fail', 'login_locked'], interval '15 minutes') >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'yavas');
  end if;
  select id into v_id from public.players
    where lower(translate(btrim(nick), 'İIı', 'iii')) = lower(translate(btrim(coalesce(p_nick, '')), 'İIı', 'iii'))
    limit 1;
  if v_id is null then
    perform public._log('login_fail', null, p_token, jsonb_build_object('nick', left(coalesce(p_nick, ''), 40), 'reason', 'isim_yok'));
    return jsonb_build_object('ok', false, 'reason', 'yanlis');
  end if;
  r := public.claim_player(v_id, p_token, p_pin);
  if (r->>'ok')::boolean then
    perform public._log('login_ok', v_id, p_token);
  else
    perform public._log(case when r->>'reason' = 'kilitli' then 'login_locked' else 'login_fail' end, v_id, p_token,
      jsonb_build_object('reason', r->>'reason'));
  end if;
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
    'players', coalesce((select jsonb_agg(jsonb_build_array(
        id, coalesce(display_nick, nick), avatar, invited_by,
        case when id = public._player_for(p_token) or public._admin_for(p_token) is not null then nick end))
      from public.players), '[]'::jsonb),
    'pees', coalesce((select jsonb_agg(jsonb_build_array(id, player_id, day, hour, minute, ts, note))
                      from public.pees where seq > v_since), '[]'::jsonb),
    'deleted', case when v_since = 0 then '[]'::jsonb else
      coalesce((select jsonb_agg(pee_id) from public.pee_deletions where seq > v_since), '[]'::jsonb) end
  );
end $$;

-- Giriş ekranındaki canlı sayaç: yalnızca toplamlar, kimin ne zaman işediği görünmez
create or replace function public.public_stats()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'pees', (select count(*) from public.pees),
    'players', (select count(*) from public.players),
    'points', (select coalesce(sum(least(c, 4)), 0) from (select count(*) as c from public.pees group by day, hour) t)
  )
$$;

-- Çıkış: bu cihazın profille bağlantısını ve panel oturumlarını sil
create or replace function public.logout(p_token text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token);
begin
  if v_player is not null then perform public._log('logout', v_player, p_token); end if;
  delete from public.admin_sessions where device_hash = public._token_hash(coalesce(p_token, ''));
  delete from public.devices where token_hash = public._token_hash(coalesce(p_token, ''));
end $$;

-- Kendi profilini düzenle
create or replace function public.update_profile(p_token text, p_nick text, p_avatar text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_old text;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  if not public._nick_ok(p_nick) then raise exception 'gecersiz_ad'; end if;
  select nick into v_old from public.players where id = v_player;
  update public.players set nick = btrim(p_nick), avatar = p_avatar, updated_at = now() where id = v_player;
  perform public._log('profile_update', v_player, p_token,
    jsonb_build_object('eski_ad', v_old, 'yeni_ad', btrim(p_nick), 'avatar', p_avatar));
end $$;

-- İşeme ekle (yalnızca kendi adına). Gün/saat/dakika kayıt zamanından sunucuda hesaplanır;
-- sitenin gönderdiği değerler yok sayılır. En fazla 7 gün geriye; kişi başına dakikada 2, saatte 12.
create or replace function public.add_pee(p_token text, p_day int, p_hour int, p_minute int, p_ts bigint, p_note text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_id uuid; v record; v_now bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  if p_ts is null or p_ts > v_now + 600000 then raise exception 'gelecek_tarih'; end if;
  if p_ts < v_now - 7 * 86400000 then raise exception 'eski_tarih'; end if;
  if public._player_count('pee_add', v_player, interval '1 minute') >= 2
     or public._player_count('pee_add', v_player, interval '1 hour') >= 12 then
    raise exception 'cok_hizli';
  end if;
  select * into v from public._slot(p_ts);
  insert into public.pees (player_id, day, hour, minute, ts, note)
    values (v_player, v.day, v.hour, v.minute, p_ts, nullif(btrim(left(coalesce(p_note, ''), 200)), ''))
    returning id into v_id;
  perform public._log('pee_add', v_player, p_token,
    jsonb_build_object('kayit', v_id, 'gun', v.day, 'saat', v.hour, 'dakika', v.minute, 'ts', p_ts,
                       'not', nullif(btrim(left(coalesce(p_note, ''), 200)), '')));
  return v_id;
end $$;

-- İşeme sil (yalnızca kendi kaydını)
create or replace function public.delete_pee(p_token text, p_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); r public.pees%rowtype;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  delete from public.pees where id = p_id and player_id = v_player returning * into r;
  if found then
    insert into public.pee_deletions (pee_id) values (p_id);
    perform public._log('pee_delete', v_player, p_token,
      jsonb_build_object('kayit', p_id, 'gun', r.day, 'saat', r.hour, 'dakika', r.minute, 'ts', r.ts, 'not', r.note));
    return true;
  end if;
  return false;
end $$;

-- Kendi davet kodun. Yoksa oluşturulur; p_rotate ise yenilenir (eski link çalışmaz olur).
create or replace function public.my_invite(p_token text, p_rotate boolean default false)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_code text;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  if p_rotate then
    if public._player_count('invite_rotate', v_player, interval '1 hour') >= 5 then raise exception 'cok_hizli'; end if;
    v_code := upper(encode(extensions.gen_random_bytes(5), 'hex'));
    insert into public.invites (player_id, code) values (v_player, v_code)
      on conflict (player_id) do update set code = excluded.code, created_at = now();
    perform public._log('invite_rotate', v_player, p_token);
    return v_code;
  end if;
  select code into v_code from public.invites where player_id = v_player;
  if v_code is null then
    v_code := upper(encode(extensions.gen_random_bytes(5), 'hex'));
    insert into public.invites (player_id, code) values (v_player, v_code);
  end if;
  return v_code;
end $$;

-- Ekranda görünen kayıtların tepki ve yorumları (en fazla 100 kayıt)
create or replace function public.get_social(p_token text, p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_ids uuid[];
begin
  if v_player is null then return null; end if;
  v_ids := (select array_agg(x) from (select unnest(p_ids) as x limit 100) t);
  return jsonb_build_object(
    'reactions', coalesce((
      select jsonb_agg(jsonb_build_array(pee_id, emoji, n, mine))
      from (select pee_id, emoji, count(*) as n, bool_or(player_id = v_player) as mine
            from public.reactions where pee_id = any(v_ids) group by pee_id, emoji) r
    ), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_array(id, pee_id, player_id, body, created_at) order by created_at)
      from public.comments where pee_id = any(v_ids)
    ), '[]'::jsonb)
  );
end $$;

-- Tepki ver / geri al. Sonuç: tepki şimdi açık mı?
create or replace function public.toggle_reaction(p_token text, p_pee uuid, p_emoji text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token);
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  if p_emoji not in ('su', 'gul', 'tac', 'ates', 'igrenc') then raise exception 'gecersiz_tepki'; end if;
  if not exists (select 1 from public.pees where id = p_pee) then raise exception 'kayit_yok'; end if;
  delete from public.reactions where pee_id = p_pee and player_id = v_player and emoji = p_emoji;
  if found then return false; end if;
  if (select count(*) from public.reactions where player_id = v_player and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'cok_hizli';
  end if;
  insert into public.reactions (pee_id, player_id, emoji) values (p_pee, v_player, p_emoji);
  return true;
end $$;

-- Yorum yaz (en fazla 200 karakter; dakikada 5, saatte 60)
create or replace function public.add_comment(p_token text, p_pee uuid, p_body text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_body text := btrim(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]]', ' ', 'g')); v_id uuid; v_owner text;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  if char_length(v_body) < 1 then raise exception 'bos_yorum'; end if;
  if char_length(v_body) > 200 then raise exception 'uzun_yorum'; end if;
  select player_id into v_owner from public.pees where id = p_pee;
  if v_owner is null then raise exception 'kayit_yok'; end if;
  if (select count(*) from public.comments where player_id = v_player and created_at > now() - interval '1 minute') >= 5
     or (select count(*) from public.comments where player_id = v_player and created_at > now() - interval '1 hour') >= 60 then
    raise exception 'cok_hizli';
  end if;
  insert into public.comments (pee_id, player_id, body) values (p_pee, v_player, v_body) returning id into v_id;
  perform public._log('comment_add', v_player, p_token, jsonb_build_object(
    'yorum', v_id, 'kayit', p_pee, 'metin', v_body, 'sahibi_ad', (select coalesce(display_nick, nick) from public.players where id = v_owner)));
  return v_id;
end $$;

-- Kendi yorumunu sil
create or replace function public.delete_comment(p_token text, p_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_player text := public._player_for(p_token); v_body text;
begin
  if v_player is null then raise exception 'yetkisiz'; end if;
  delete from public.comments where id = p_id and player_id = v_player returning body into v_body;
  if not found then return false; end if;
  perform public._log('comment_delete', v_player, p_token, jsonb_build_object('yorum', p_id, 'metin', v_body));
  return true;
end $$;

-- Kumanda paneli: giriş ------------------------------------------------------

-- Bu cihaz yönetici mi, yönetici şifresi belirlenmiş mi?
create or replace function public.admin_status(p_token text)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'admin', a.player_id is not null,
    'has_password', a.pass_hash is not null)
  from (select 1) x
  left join public.admins a on a.player_id = public._admin_for(p_token)
$$;

-- Yönetici şifresi belirle/değiştir. İlk kez belirlerken yalnızca yönetici cihazı yeter,
-- sonradan değiştirmek için açık bir panel oturumu gerekir.
create or replace function public.admin_set_password(p_token text, p_session text, p_new text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_for(p_token); v_has boolean;
begin
  if v_admin is null then raise exception 'yetkisiz'; end if;
  select pass_hash is not null into v_has from public.admins where player_id = v_admin;
  if v_has then perform public._admin_ok(p_token, p_session); end if;
  if char_length(coalesce(p_new, '')) < 10 then raise exception 'kisa_sifre'; end if;
  update public.admins set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)),
    failed_attempts = 0, locked_until = null where player_id = v_admin;
  perform public._log('admin_password_set', v_admin, p_token);
  return true;
end $$;

-- Panele giriş: yönetici cihazı + yönetici şifresi. 5 yanlışta 30 dakika, 10 yanlışta 24 saat kilit.
create or replace function public.admin_login(p_token text, p_password text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_for(p_token); a public.admins%rowtype; v_session text;
begin
  if public._ip_count(array['admin_login_fail'], interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'yavas');
  end if;
  if v_admin is null then
    perform public._log('admin_login_fail', public._player_for(p_token), p_token, jsonb_build_object('reason', 'yonetici_degil'));
    return jsonb_build_object('ok', false, 'reason', 'yetkisiz');
  end if;
  select * into a from public.admins where player_id = v_admin for update;
  if a.pass_hash is null then return jsonb_build_object('ok', false, 'reason', 'sifre_yok'); end if;
  if a.locked_until is not null and a.locked_until > now() then
    perform public._log('admin_login_fail', v_admin, p_token, jsonb_build_object('reason', 'kilitli'));
    return jsonb_build_object('ok', false, 'reason', 'kilitli', 'until', a.locked_until);
  end if;
  if a.pass_hash = extensions.crypt(coalesce(p_password, ''), a.pass_hash) then
    update public.admins set failed_attempts = 0, locked_until = null where player_id = v_admin;
    v_session := encode(extensions.gen_random_bytes(32), 'hex');
    delete from public.admin_sessions where expires_at < now();
    insert into public.admin_sessions (token_hash, player_id, device_hash, expires_at)
      values (public._token_hash(v_session), v_admin, public._token_hash(p_token), now() + interval '30 minutes');
    perform public._log('admin_login_ok', v_admin, p_token);
    return jsonb_build_object('ok', true, 'session', v_session);
  end if;
  a.failed_attempts := a.failed_attempts + 1;
  if a.failed_attempts % 5 = 0 then
    a.locked_until := now() + case when a.failed_attempts >= 10 then interval '24 hours' else interval '30 minutes' end;
  end if;
  update public.admins set failed_attempts = a.failed_attempts, locked_until = a.locked_until where player_id = v_admin;
  perform public._log('admin_login_fail', v_admin, p_token, jsonb_build_object('reason', 'yanlis_sifre'));
  if a.locked_until is not null and a.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'kilitli', 'until', a.locked_until);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'yanlis');
end $$;

create or replace function public.admin_logout(p_token text, p_session text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.admin_sessions
    where token_hash = public._token_hash(coalesce(p_session, ''))
      and device_hash = public._token_hash(coalesce(p_token, ''));
end $$;

-- Kumanda paneli: veriler ----------------------------------------------------

create or replace function public.admin_overview(p_token text, p_session text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_today timestamptz := date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul';
begin
  perform public._admin_ok(p_token, p_session);
  return jsonb_build_object(
    'stats', jsonb_build_object(
      'players', (select count(*) from public.players),
      'pees', (select count(*) from public.pees),
      'pees_today', (select count(*) from public.pees where created_at >= v_today),
      'devices', (select count(*) from public.devices),
      'active_24h', (select count(distinct player_id) from public.devices where last_seen > now() - interval '24 hours'),
      'failed_24h', (select count(*) from public.audit_log where event in ('login_fail', 'login_locked', 'admin_login_fail') and at > now() - interval '24 hours'),
      'locked', (select count(*) from public.player_secrets where locked_until > now())
    ),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'nick', coalesce(p.display_nick, p.nick), 'login_nick', p.nick, 'avatar', p.avatar,
        'pees', (select count(*) from public.pees e where e.player_id = p.id),
        'devices', (select count(*) from public.devices d where d.player_id = p.id),
        'last_seen', (select max(d.last_seen) from public.devices d where d.player_id = p.id),
        'has_pin', s.player_id is not null,
        'failed', coalesce(s.failed_attempts, 0),
        'locked_until', case when s.locked_until > now() then s.locked_until end,
        'is_admin', exists (select 1 from public.admins a where a.player_id = p.id),
        'invited_by', (select coalesce(i.display_nick, i.nick) from public.players i where i.id = p.invited_by),
        'invited_count', (select count(*) from public.players c where c.invited_by = p.id)
      ) order by coalesce(p.display_nick, p.nick))
      from public.players p left join public.player_secrets s on s.player_id = p.id
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.admin_devices(p_token text, p_session text, p_player_id text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform public._admin_ok(p_token, p_session);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'device', left(d.token_hash, 8), 'created_at', d.created_at, 'last_seen', d.last_seen,
      'ip', d.last_ip, 'ua', d.last_ua, 'current', d.token_hash = public._token_hash(p_token)
    ) order by d.last_seen desc nulls last)
    from public.devices d where d.player_id = p_player_id
  ), '[]'::jsonb);
end $$;

create or replace function public.admin_logs(p_token text, p_session text, p_before bigint default null,
  p_player_id text default null, p_event text default null, p_limit int default 100)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform public._admin_ok(p_token, p_session);
  return coalesce((
    select jsonb_agg(jsonb_build_array(l.id, l.at, l.player_id, coalesce(p.display_nick, p.nick, l.nick), l.event, l.detail, l.ip, l.user_agent, l.device)
                     order by l.id desc)
    from (
      select * from public.audit_log
      where (p_before is null or id < p_before)
        and (p_player_id is null or player_id = p_player_id)
        and (p_event is null or event = p_event or (p_event = 'login_any' and event like 'login%')
             or (p_event = 'admin_any' and event like 'admin%') or (p_event = 'pee_any' and event like 'pee%'))
      order by id desc
      limit least(greatest(coalesce(p_limit, 100), 1), 300)
    ) l left join public.players p on p.id = l.player_id
  ), '[]'::jsonb);
end $$;

-- Kumanda paneli: işlemler ---------------------------------------------------

create or replace function public.admin_update_pee(p_token text, p_session text, p_id uuid, p_day int, p_hour int, p_minute int, p_ts bigint, p_note text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); r public.pees%rowtype; v record;
begin
  if p_ts is null or p_ts > (extract(epoch from now()) * 1000)::bigint + 600000 then raise exception 'gelecek_tarih'; end if;
  if p_ts < (extract(epoch from now()) * 1000)::bigint - 365 * 86400000::bigint then raise exception 'eski_tarih'; end if;
  select * into r from public.pees where id = p_id;
  if not found then return false; end if;
  select * into v from public._slot(p_ts);
  p_day := v.day; p_hour := v.hour; p_minute := v.minute;
  update public.pees
    set day = p_day, hour = p_hour, minute = p_minute, ts = p_ts,
        note = nullif(btrim(coalesce(p_note, '')), ''), seq = nextval('public.sync_seq')
    where id = p_id;
  perform public._log('admin_pee_update', v_admin, p_token, jsonb_build_object(
    'kayit', p_id, 'sahibi', r.player_id, 'sahibi_ad', (select coalesce(display_nick, nick) from public.players where id = r.player_id),
    'eski', jsonb_build_object('gun', r.day, 'saat', r.hour, 'dakika', r.minute, 'not', r.note),
    'yeni', jsonb_build_object('gun', p_day, 'saat', p_hour, 'dakika', p_minute, 'not', nullif(btrim(coalesce(p_note, '')), ''))));
  return true;
end $$;

create or replace function public.admin_delete_pee(p_token text, p_session text, p_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); r public.pees%rowtype;
begin
  delete from public.pees where id = p_id returning * into r;
  if not found then return false; end if;
  insert into public.pee_deletions (pee_id) values (p_id);
  perform public._log('admin_pee_delete', v_admin, p_token, jsonb_build_object(
    'kayit', p_id, 'sahibi', r.player_id, 'sahibi_ad', (select coalesce(display_nick, nick) from public.players where id = r.player_id),
    'gun', r.day, 'saat', r.hour, 'dakika', r.minute, 'not', r.note));
  return true;
end $$;

create or replace function public.admin_update_player(p_token text, p_session text, p_player_id text, p_nick text, p_avatar text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); v_login text; v_old text; v_new text := nullif(btrim(coalesce(p_nick, '')), '');
begin
  select nick, coalesce(display_nick, nick) into v_login, v_old from public.players where id = p_player_id;
  if not found then return false; end if;
  if v_new is not null and not public._nick_ok(v_new) then raise exception 'gecersiz_ad'; end if;
  -- Giriş adıyla aynıysa ya da boşsa görünen ad kaldırılır
  if v_new is not null and v_new = v_login then v_new := null; end if;
  update public.players set display_nick = v_new, avatar = p_avatar, updated_at = now() where id = p_player_id;
  perform public._log('admin_player_update', v_admin, p_token, jsonb_build_object(
    'kisi', p_player_id, 'eski_ad', v_old, 'yeni_ad', coalesce(v_new, v_login), 'giris_adi', v_login, 'avatar', p_avatar));
  return true;
end $$;

create or replace function public.admin_reset_pin(p_token text, p_session text, p_player_id text, p_pin text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session);
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then raise exception 'gecersiz_sifre'; end if;
  if not exists (select 1 from public.players where id = p_player_id) then return false; end if;
  insert into public.player_secrets (player_id, pin_hash) values (p_player_id, extensions.crypt(p_pin, extensions.gen_salt('bf')))
    on conflict (player_id) do update set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
  perform public._log('admin_pin_reset', v_admin, p_token, jsonb_build_object(
    'kisi', p_player_id, 'kisi_ad', (select coalesce(display_nick, nick) from public.players where id = p_player_id)));
  return true;
end $$;

create or replace function public.admin_revoke_devices(p_token text, p_session text, p_player_id text)
returns int language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); n int;
begin
  delete from public.devices
    where player_id = p_player_id and token_hash <> public._token_hash(p_token);
  get diagnostics n = row_count;
  perform public._log('admin_devices_revoke', v_admin, p_token, jsonb_build_object(
    'kisi', p_player_id, 'kisi_ad', (select coalesce(display_nick, nick) from public.players where id = p_player_id), 'cihaz_sayisi', n));
  return n;
end $$;

create or replace function public.admin_delete_player(p_token text, p_session text, p_player_id text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); v_nick text; n int;
begin
  if v_admin = p_player_id then raise exception 'kendini_silemezsin'; end if;
  select coalesce(display_nick, nick) into v_nick from public.players where id = p_player_id;
  if not found then return false; end if;
  insert into public.pee_deletions (pee_id) select id from public.pees where player_id = p_player_id;
  get diagnostics n = row_count;
  delete from public.players where id = p_player_id;
  perform public._log('admin_player_delete', v_admin, p_token, jsonb_build_object(
    'kisi', p_player_id, 'kisi_ad', v_nick, 'silinen_isemeler', n));
  return true;
end $$;

-- Davet kodunu göster; p_rotate ise yenisini üret (eski bağlantı çalışmaz olur)
create or replace function public.admin_invite(p_token text, p_session text, p_rotate boolean default false)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); v_code text;
begin
  if p_rotate then
    v_code := upper(encode(extensions.gen_random_bytes(5), 'hex'));
    insert into public.settings (key, value) values ('invite_code', v_code)
      on conflict (key) do update set value = excluded.value;
    perform public._log('admin_invite_rotate', v_admin, p_token);
  end if;
  select value into v_code from public.settings where key = 'invite_code';
  return v_code;
end $$;

-- Bir kişinin davet linkini sıfırla (linki yabancılara yayıldıysa)
create or replace function public.admin_rotate_player_invite(p_token text, p_session text, p_player_id text)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session);
begin
  if not exists (select 1 from public.players where id = p_player_id) then return false; end if;
  insert into public.invites (player_id, code) values (p_player_id, upper(encode(extensions.gen_random_bytes(5), 'hex')))
    on conflict (player_id) do update set code = excluded.code, created_at = now();
  perform public._log('admin_player_invite_rotate', v_admin, p_token, jsonb_build_object(
    'kisi', p_player_id, 'kisi_ad', (select coalesce(display_nick, nick) from public.players where id = p_player_id)));
  return true;
end $$;

-- Yönetici: herhangi bir yorumu sil
create or replace function public.admin_delete_comment(p_token text, p_session text, p_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare v_admin text := public._admin_ok(p_token, p_session); c public.comments%rowtype;
begin
  delete from public.comments where id = p_id returning * into c;
  if not found then return false; end if;
  perform public._log('admin_comment_delete', v_admin, p_token, jsonb_build_object(
    'yorum', p_id, 'metin', c.body, 'yazan', c.player_id, 'yazan_ad', (select coalesce(display_nick, nick) from public.players where id = c.player_id)));
  return true;
end $$;

-- Yetkiler -------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'whoami(text)',
    'register_player(text, text, text, text, text)',
    'admin_invite(text, text, boolean)',
    'my_invite(text, boolean)',
    'get_social(text, uuid[])',
    'toggle_reaction(text, uuid, text)',
    'add_comment(text, uuid, text)',
    'delete_comment(text, uuid)',
    'admin_delete_comment(text, text, uuid)',
    'admin_rotate_player_invite(text, text, text)',
    'secure_existing(text, text, text)',
    'login(text, text, text)',
    'legacy_status(text)',
    'fetch_data(text, bigint)',
    'public_stats()',
    'logout(text)',
    'update_profile(text, text, text)',
    'add_pee(text, int, int, int, bigint, text)',
    'delete_pee(text, uuid)',
    'admin_status(text)',
    'admin_set_password(text, text, text)',
    'admin_login(text, text)',
    'admin_logout(text, text)',
    'admin_overview(text, text)',
    'admin_devices(text, text, text)',
    'admin_logs(text, text, bigint, text, text, int)',
    'admin_update_pee(text, text, uuid, int, int, int, bigint, text)',
    'admin_delete_pee(text, text, uuid)',
    'admin_update_player(text, text, text, text, text)',
    'admin_reset_pin(text, text, text, text)',
    'admin_revoke_devices(text, text, text)',
    'admin_delete_player(text, text, text)'
  ] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- claim_player yalnızca login() içinden çağrılır
revoke execute on function public.claim_player(text, text, text) from public, anon, authenticated;

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
