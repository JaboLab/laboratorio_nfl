-- Pruebas de la migración inicial. Cada bloque lanza excepción si falla.
\set ON_ERROR_STOP on

insert into ref.teams values ('KC','Kansas City Chiefs'), ('NYJ','New York Jets');
insert into ref.books values ('consensus_vi','VegasInsider consenso', false), ('playdoit','Playdoit', false);
insert into ref.allowed_users values ('jabo@example.com');
insert into core.games (game_id, season, week, away_team, home_team, kickoff)
  values ('2026_09_NYJ_KC', 2026, 9, 'NYJ', 'KC', '2026-11-08 12:00-06');
insert into model.model_registry (model_version, engine) values ('M0@0.1.0+test', 'M0');

-- 1. emitted_at lo fija el servidor aunque el cliente mande una hora pasada
insert into model.predictions (game_id, market, selection, p_model, p_method, model_version, emitted_at)
  values ('2026_09_NYJ_KC', 'h2h', 'KC', 0.808, 'mercado', 'M0@0.1.0+test', '2020-01-01');
do $$ begin
  if (select emitted_at from model.predictions order by id desc limit 1) < now() - interval '1 minute' then
    raise exception 'FALLA 1: se aceptó una hora de emisión del cliente';
  end if;
end $$;

-- 2. predictions es de solo inserción
do $$ begin
  begin
    update model.predictions set p_model = 0.9;
    raise exception 'FALLA 2: se permitió UPDATE';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from model.predictions;
    raise exception 'FALLA 2b: se permitió DELETE';
  exception when insufficient_privilege then null;
  end;
end $$;

-- 3. v_pit_violations detecta un insumo posterior a la emisión
insert into model.prediction_inputs
  select id, 'core.odds_snapshots', 1, now() + interval '1 hour' from model.predictions limit 1;
do $$ begin
  if (select count(*) from report.v_pit_violations) <> 1 then
    raise exception 'FALLA 3: la vista point-in-time no detectó la violación';
  end if;
end $$;

-- 4. momios inválidos rechazados
do $$ begin
  begin
    insert into core.odds_snapshots (game_id, book_id, market, selection, price_american, available_at, source)
      values ('2026_09_NYJ_KC', 'playdoit', 'h2h', 'KC', 50, now(), 'test');
    raise exception 'FALLA 4: se aceptó un momio de +50';
  exception when check_violation then null;
  end;
end $$;

-- 5. modo real exige folio
do $$ begin
  begin
    insert into book.tickets (block, mode, stake_mxn) values ('mesa', 'real', 500);
    raise exception 'FALLA 5: boleto real sin folio';
  exception when check_violation then null;
  end;
end $$;

-- 6. RLS: anon no ve nada; usuario no permitido no ve nada; Jabo lee e inserta en book
set role anon;
do $$ begin
  begin
    perform 1 from core.games;
    raise exception 'FALLA 6a: anon pudo leer';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claims', '{"email":"otro@example.com"}', false);
do $$ begin
  if (select count(*) from core.games) <> 0 then raise exception 'FALLA 6b: usuario no permitido leyó datos'; end if;
end $$;
select set_config('request.jwt.claims', '{"email":"jabo@example.com"}', false);
do $$ begin
  if (select count(*) from core.games) <> 1 then raise exception 'FALLA 6c: Jabo no puede leer'; end if;
end $$;
insert into book.tickets (block, mode, stake_mxn, note) values ('mesa', 'papel', 100, 'prueba RLS');
do $$ begin
  begin
    insert into core.games (game_id, season, week, away_team, home_team, kickoff)
      values ('x', 2026, 9, 'KC', 'NYJ', now());
    raise exception 'FALLA 6d: Jabo pudo escribir en core';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

select 'OK: todas las pruebas de la migración pasaron' as resultado;
