-- Laboratorio NFL — migración inicial (PRD v1.0 §6.3, Plan v1.0 §3)
-- Horas: timestamptz (UTC en la base, CST en la presentación).

create schema if not exists ref;
create schema if not exists raw;
create schema if not exists core;
create schema if not exists model;
create schema if not exists book;
create schema if not exists report;

-- ───────────────────────── utilidades ─────────────────────────

create or replace function ref.forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception 'Tabla de solo inserción: % no permitido en %.%', tg_op, tg_table_schema, tg_table_name
    using errcode = 'insufficient_privilege';
end $$;

create or replace function ref.force_now() returns trigger
language plpgsql as $$
begin
  new.emitted_at := now();   -- la hora la pone el servidor, nunca el cliente (ADR-006)
  return new;
end $$;

-- ───────────────────────── ref ─────────────────────────

create table ref.allowed_users (
  email text primary key
);

create table ref.books (
  book_id   text primary key,          -- 'playdoit', 'pinnacle', 'draftkings', 'consensus_vi', ...
  name      text not null,
  is_sharp  boolean not null default false
);

create table ref.teams (
  team_id   text primary key,          -- abreviatura nflverse: 'KC', 'LAR', ...
  name      text not null
);

-- ───────────────────────── raw ─────────────────────────

create table raw.payloads (
  id          bigint generated always as identity primary key,
  source      text not null,
  url         text,
  fetched_at  timestamptz not null default now(),
  sha256      text not null,
  body        jsonb not null
);
create trigger payloads_append_only before update or delete on raw.payloads
  for each row execute function ref.forbid_change();

-- ───────────────────────── core ─────────────────────────

create table core.games (
  game_id      text primary key,       -- id nflverse, ej. '2026_09_NYJ_KC'
  season       smallint not null,
  week         smallint not null,
  game_type    text not null default 'REG',
  away_team    text not null references ref.teams,
  home_team    text not null references ref.teams,
  neutral_site boolean not null default false,
  roof         text,
  kickoff      timestamptz not null,
  away_score   smallint,
  home_score   smallint,
  result_available_at timestamptz,
  check (away_team <> home_team)
);
create index on core.games (season, week);
create index on core.games (kickoff);

create table core.odds_snapshots (
  id             bigint generated always as identity primary key,
  game_id        text not null references core.games,
  book_id        text not null references ref.books,
  market         text not null,        -- 'h2h', 'spread', 'total', 'player_anytime_td', 'player_receptions'
  selection      text not null,        -- equipo, 'over'/'under' o jugador
  line           numeric,
  price_american integer not null check (price_american <= -100 or price_american >= 100),
  is_main_line   boolean not null default true,
  captured_at    timestamptz not null default now(),
  available_at   timestamptz not null,
  is_closing     boolean not null default false,
  source         text not null,
  raw_id         bigint references raw.payloads,
  check (available_at <= captured_at)
);
create index on core.odds_snapshots (game_id, market, book_id, captured_at);

create table core.injuries (
  id           bigint generated always as identity primary key,
  game_id      text not null references core.games,
  team_id      text not null references ref.teams,
  player       text not null,
  position     text,
  game_status  text,                   -- Out, Doubtful, Questionable, null
  practice     text,                   -- DNP, Limited, Full
  available_at timestamptz not null,
  source       text not null,
  raw_id       bigint references raw.payloads
);
create index on core.injuries (game_id, available_at);

-- ───────────────────────── model ─────────────────────────

create table model.model_registry (
  model_version   text primary key,    -- '<motor>@<semver>+<commit>'
  engine          text not null check (engine in ('M0','M1','M2','M3','M4','M5','LLM')),
  code_commit     text,
  training_window text,
  metrics         jsonb,
  status          text not null default 'retador' check (status in ('campeon','retador','retirado')),
  created_at      timestamptz not null default now()
);

create table model.predictions (
  id            bigint generated always as identity primary key,
  game_id       text not null references core.games,
  market        text not null,
  selection     text not null,
  line          numeric,
  p_model       numeric(6,5) not null check (p_model between 0 and 1),
  p_method      text not null check (p_method in ('modelo','llm_con_momio','llm_sin_momio','mercado')),
  p_m0          numeric(6,5) check (p_m0 between 0 and 1),     -- null = NO_ENCONTRADO
  devig_method  text check (devig_method in ('proportional','power','shin')),
  model_version text not null references model.model_registry,
  emitted_at    timestamptz not null default now(),
  note          text
);
create trigger predictions_force_now before insert on model.predictions
  for each row execute function ref.force_now();
create trigger predictions_append_only before update or delete on model.predictions
  for each row execute function ref.forbid_change();

create table model.prediction_inputs (
  prediction_id bigint not null references model.predictions,
  source_table  text not null,
  source_id     bigint not null,
  available_at  timestamptz not null,
  primary key (prediction_id, source_table, source_id)
);
create trigger prediction_inputs_append_only before update or delete on model.prediction_inputs
  for each row execute function ref.forbid_change();

-- Backtests: predicciones históricas con hora "as_of" simulada. Nunca se mezclan con predictions.
create table model.backtest_predictions (
  id            bigint generated always as identity primary key,
  run_id        text not null,
  game_id       text not null references core.games,
  market        text not null,
  selection     text not null,
  line          numeric,
  p_model       numeric(6,5) not null check (p_model between 0 and 1),
  p_m0          numeric(6,5) check (p_m0 between 0 and 1),
  model_version text not null references model.model_registry,
  as_of         timestamptz not null,
  created_at    timestamptz not null default now()
);

create table model.hypotheses (
  hypothesis_id text primary key,      -- 'H-001'
  statement     text not null,
  metric        text not null,
  threshold     text not null,
  registered_at timestamptz not null default now(),
  status        text not null default 'abierta' check (status in ('abierta','confirmada','rechazada','retirada')),
  result        text
);

-- ───────────────────────── book ─────────────────────────

create table book.tickets (
  ticket_id        bigint generated always as identity primary key,
  block            text not null check (block in ('mesa','risk','fuera_de_plan')),
  mode             text not null default 'papel' check (mode in ('papel','real')),
  stake_mxn        numeric(12,2) not null check (stake_mxn > 0),
  playdoit_folio   text unique,
  price_total_american integer,
  bonus_shown_mxn  numeric(12,2),
  potential_payout_mxn numeric(12,2),
  placed_at        timestamptz,
  recorded_at      timestamptz not null default now(),
  note             text,
  check (mode = 'papel' or playdoit_folio is not null)
);

create table book.ticket_legs (
  ticket_id        bigint not null references book.tickets,
  leg              smallint not null,
  game_id          text not null references core.games,
  prediction_id    bigint references model.predictions,
  market           text not null,
  market_literal   text,               -- texto exacto de Playdoit, ej. 'Hándicap (incl. prórroga)'
  selection        text not null,
  line             numeric,
  price_american_taken integer not null check (price_american_taken <= -100 or price_american_taken >= 100),
  result           text check (result in ('1','0','P','nula')),
  primary key (ticket_id, leg)
);

create table book.cashout_offers (
  id               bigint generated always as identity primary key,
  ticket_id        bigint not null references book.tickets,
  captured_at      timestamptz not null,
  offer_mxn        numeric(12,2) not null check (offer_mxn >= 0),
  fair_value_mxn   numeric(12,2),
  accepted         boolean not null default false,
  recorded_at      timestamptz not null default now()
);
create trigger cashout_append_only before update or delete on book.cashout_offers
  for each row execute function ref.forbid_change();

create table book.bankroll_ledger (
  id          bigint generated always as identity primary key,
  occurred_at timestamptz not null,
  kind        text not null check (kind in ('deposito','stake','pago','retiro','ajuste')),
  amount_mxn  numeric(12,2) not null,
  ticket_id   bigint references book.tickets,
  in_plan     boolean not null,
  note        text,
  recorded_at timestamptz not null default now()
);
create trigger ledger_append_only before update or delete on book.bankroll_ledger
  for each row execute function ref.forbid_change();

create table book.rules (
  rule_id    text not null,
  version    smallint not null,
  profile    text not null check (profile in ('mesa','risk','global')),
  statement  text not null,
  params     jsonb not null default '{}'::jsonb,
  active     boolean not null default true,
  primary key (rule_id, version)
);

create table book.rule_checks (
  ticket_id    bigint not null references book.tickets,
  rule_id      text not null,
  rule_version smallint not null,
  passed       boolean not null,
  detail       text,
  checked_at   timestamptz not null default now(),
  primary key (ticket_id, rule_id, rule_version),
  foreign key (rule_id, rule_version) references book.rules
);

-- ───────────────────────── report ─────────────────────────

create view report.v_pit_violations with (security_invoker = true) as
select p.id as prediction_id, i.source_table, i.source_id, i.available_at, p.emitted_at
from model.predictions p
join model.prediction_inputs i on i.prediction_id = p.id
where i.available_at >= p.emitted_at;

-- ───────────────────────── seguridad (RLS) ─────────────────────────
-- anon: nada. authenticated: lee todo si su correo está en ref.allowed_users;
-- inserta solo en book.*. service_role: omite RLS (GitHub Actions y Edge Functions).

create or replace function ref.is_allowed() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from ref.allowed_users
    where email = coalesce(auth.jwt() ->> 'email', '')
  );
$$;

grant usage on schema ref, raw, core, model, book, report to authenticated, service_role;
grant select on all tables in schema ref, raw, core, model, book, report to authenticated;
grant all on all tables in schema ref, raw, core, model, book to service_role;
grant select on all tables in schema report to service_role;
grant usage, select on all sequences in schema raw, core, model, book to service_role;
grant insert on book.tickets, book.ticket_legs, book.cashout_offers, book.bankroll_ledger to authenticated;
grant usage, select on all sequences in schema book to authenticated;
revoke all on all tables in schema ref, raw, core, model, book, report from anon;
grant execute on function ref.is_allowed() to authenticated;

do $$
declare t record;
begin
  for t in
    select schemaname, tablename from pg_tables
    where schemaname in ('ref','raw','core','model','book')
  loop
    execute format('alter table %I.%I enable row level security', t.schemaname, t.tablename);
    execute format(
      'create policy allowed_read on %I.%I for select to authenticated using (ref.is_allowed())',
      t.schemaname, t.tablename);
  end loop;
end $$;

create policy allowed_insert on book.tickets         for insert to authenticated with check (ref.is_allowed());
create policy allowed_insert on book.ticket_legs     for insert to authenticated with check (ref.is_allowed());
create policy allowed_insert on book.cashout_offers  for insert to authenticated with check (ref.is_allowed());
create policy allowed_insert on book.bankroll_ledger for insert to authenticated with check (ref.is_allowed());
