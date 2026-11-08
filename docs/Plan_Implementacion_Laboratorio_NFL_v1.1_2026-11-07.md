# Plan de implementación y desarrollo — Laboratorio NFL

| Campo | Valor |
| --- | --- |
| Versión | v1.1 |
| Fecha | 2026-11-07 (CST) |
| Documento rector | PRD v1.1 (privado, fuera de este repositorio). Este plan lo ejecuta; si algo aquí lo contradice, manda el PRD |
| Stack | Supabase (Postgres, pg_cron, Edge Functions, Auth, Storage) · Lovable (construcción del front React) · Netlify (despliegue del front) · Python (ingesta y motores) · GitHub (código, CI y tareas batch) · Claude (backend, motores, revisión) |
| Supuestos | D2 y D5 del PRD se aceptan como se propusieron (papel desde la Semana 10; lectura con sesión solo asistida). D1 (fondo y límites) sigue abierta y solo bloquea la configuración del libro de fondo. Capacidad estimada: ~8 h/semana de Jabo (ajustar) |

---

## 1. Arquitectura de despliegue

Cada pieza corre donde mejor encaja su exigencia de tiempo y de lenguaje.

| Pieza | Dónde corre | Por qué |
| --- | --- | --- |
| Base de datos, autenticación, archivos | **Supabase** (Postgres) | Requisito del proyecto; RLS para separar lectura y escritura |
| Capturas de momios con hora crítica (cierres 5–15 min antes del kickoff) | **Supabase pg_cron + Edge Function** (TypeScript) | pg_cron dispara al minuto dentro de la propia base. Las tareas programadas de GitHub Actions pueden retrasarse varios minutos y las de Netlify tienen un límite de 30 s por ejecución |
| Ingesta histórica, features, entrenamiento, backtests, reporte semanal | **Python en GitHub Actions** (y en local para desarrollo) | Python nativo, sin límite práctico de 30 s; la hora exacta no es crítica |
| Front | **Lovable** construye; **Netlify** despliega desde el repositorio de Lovable | Pantallas mucho más rápidas; Lovable sincroniza con GitHub y Netlify publica cada cambio |
| Tutor LLM (F2) | Supabase Edge Function | La llave del LLM queda en el servidor; el tutor solo lee la base |

```
 Fuentes ──► Edge Function capture-odds ◄── pg_cron (cada 5 min)
 (Odds API,          │
  nflverse,          ▼
  NFL.com)      Supabase Postgres ◄── GitHub Actions (Python: ingesta, modelos, reporte)
                     │
                     ▼
              Front React en Netlify (Jabo, con sesión de Supabase Auth)
                     │
                     ▼
              Boleto exportado ──► Jabo coloca a mano en Playdoit
```

### 1.1 Decisiones de arquitectura (ADR)

| ADR | Decisión |
| --- | --- |
| ADR-001 | Las capturas con hora crítica viven en pg_cron + Edge Function, nunca en GitHub Actions ni en funciones programadas de Netlify |
| ADR-002 | Todo cálculo de probabilidades es Python versionado en el repositorio; la base solo almacena y valida |
| ADR-003 | El front habla directo con Supabase usando la llave pública (`anon`) y RLS. La llave `service_role` nunca llega a Netlify: solo vive en los secretos de GitHub y de Supabase |
| ADR-004 | Cada respuesta cruda de una fuente se guarda (`raw.payloads`, JSON + hora + hash) antes de normalizarse. Así cualquier número se puede reconstruir |
| ADR-005 | Dos proyectos de Supabase: `labnfl-dev` y `labnfl-prod` (el plan gratuito permite dos) |
| ADR-006 | `predictions` es de solo inserción: `emitted_at` lo pone el servidor (`now()`), no el cliente, y ni UPDATE ni DELETE están permitidos. Es la garantía técnica del principio point-in-time |
| ADR-007 | Todas las horas se guardan como `timestamptz` en UTC y se muestran en America/Mexico_City. pg_cron se programa en UTC |
| ADR-008 | Dos repositorios: `JaboLab/laboratorio_nfl` (backend, dueño único del esquema) y `laboratorio-nfl-web` (front, creado por Lovable; Lovable no permite conectar un repositorio existente). Lovable no crea tablas, migraciones, políticas, Edge Functions ni secretos: reglas en `docs/lovable_instrucciones.md` |

## 2. Repositorio

Repositorio privado `JaboLab/laboratorio_nfl` (backend). El front vive en `laboratorio-nfl-web`, creado por Lovable.

```
laboratorio_nfl/
├─ README.md
├─ docs/                 este plan, instrucciones de Lovable (el PRD es privado)
├─ supabase/
│  ├─ config.toml
│  ├─ migrations/        0001_schemas.sql, 0002_core.sql, ...
│  ├─ functions/
│  │  ├─ capture-odds/   Edge Function (TS)
│  │  └─ tutor/          (F2)
│  └─ tests/             pruebas SQL (pgTAP): point-in-time, RLS
├─ labnfl/               paquete Python
│  ├─ db.py
│  ├─ ingest/            nflverse.py, odds_api.py, injuries.py, playdoit_manual.py
│  ├─ market/            implied.py, devig.py, clv.py, fair_value.py   (M0)
│  ├─ models/            m1_elo.py, m3_margin.py, m5_ensemble.py, m2_epa.py, m4_props.py
│  ├─ portfolio/         bonus.py, rules.py, simulate.py, optimize.py, export.py
│  └─ reports/           weekly.py
├─ tests/                pytest
└─ .github/workflows/
   ├─ ci.yml             lint + pytest + pruebas SQL en cada PR
   ├─ migrate.yml        supabase db push (dev al hacer merge, prod con aprobación)
   ├─ ingest-daily.yml   nflverse, resultados y lesiones
   ├─ report-monday.yml  reporte semanal
   └─ keepalive.yml      evita la pausa del plan gratuito en la pretemporada
```

**Reglas de trabajo:** rama `main` protegida; todo cambio entra por PR con CI en verde; versión semántica del paquete; `modelo_versión` = `<motor>@<semver>+<commit>`.

## 3. Base de datos (Supabase)

### 3.1 Esquemas

| Esquema | Contenido | Escribe |
| --- | --- | --- |
| `ref` | equipos, casas, fuentes, mercados | migraciones |
| `raw` | respuestas crudas de cada fuente | Edge Functions y Python |
| `core` | games, odds_snapshots, injuries, results | ingesta |
| `model` | features, predictions, prediction_inputs, model_registry, hypotheses | Python |
| `book` | tickets, ticket_legs, cashout_offers, bankroll_ledger, rules, rule_checks | Jabo (front) y Python |
| `report` | vistas de métricas (Brier, CLV, ROI, calibración) | vistas SQL |

### 3.2 Tablas clave (esbozo)

```sql
create table core.odds_snapshots (
  id            bigint generated always as identity primary key,
  game_id       text not null references core.games,
  book          text not null,              -- 'pinnacle', 'draftkings', 'playdoit', 'consensus'
  market        text not null,              -- 'h2h', 'spread', 'total', 'player_anytime_td', ...
  selection     text not null,
  line          numeric,
  price_american integer not null,
  is_main_line  boolean not null default true,
  captured_at   timestamptz not null default now(),
  available_at  timestamptz not null,       -- = captured_at salvo fuentes con hora propia
  is_closing    boolean not null default false,
  source        text not null,
  raw_id        bigint references raw.payloads
);

create table model.predictions (
  id            bigint generated always as identity primary key,
  game_id       text not null references core.games,
  market        text not null,
  selection     text not null,
  line          numeric,
  p_model       numeric(5,4) not null check (p_model between 0 and 1),
  p_method      text not null check (p_method in ('modelo','llm_con_momio','llm_sin_momio','mercado')),
  p_m0          numeric(5,4),               -- null = NO_ENCONTRADO
  devig_method  text,
  model_version text not null,
  emitted_at    timestamptz not null default now()
);

create table model.prediction_inputs (
  prediction_id bigint references model.predictions,
  source_table  text not null,
  source_id     bigint not null,
  available_at  timestamptz not null
);

-- Prueba point-in-time: debe devolver 0 filas
create view report.v_pit_violations as
select p.id, i.source_table, i.source_id, i.available_at, p.emitted_at
from model.predictions p
join model.prediction_inputs i on i.prediction_id = p.id
where i.available_at >= p.emitted_at;
```

El resto de las tablas sigue la sección 6.3 del PRD.

### 3.3 Seguridad (RLS)

| Rol | Lee | Escribe |
| --- | --- | --- |
| `anon` | nada | nada |
| `authenticated` (solo el correo de Jabo, con magic link) | todo | `book.tickets`, `ticket_legs`, `cashout_offers`, `bankroll_ledger` (solo inserción; las correcciones se hacen con una fila nueva) |
| `service_role` (GitHub Actions, Edge Functions) | todo | todo excepto UPDATE/DELETE en `model.predictions` (lo bloquea un trigger) |

### 3.4 Capturas programadas (pg_cron)

| Tarea | Frecuencia | Qué hace |
| --- | --- | --- |
| `capture_closing` | cada 5 min | Si hay partidos con kickoff dentro de 5–15 min y sin cierre capturado, llama a `capture-odds` y marca `is_closing` |
| `capture_opening` | martes 10:00 CST | Líneas de apertura de la semana |
| `capture_daily` | mié–sáb 10:00 CST | Actualización de momios |
| `health_check` | cada hora | Alerta si falló una captura o si `v_pit_violations` tiene filas |

**Consumo de The Odds API (plan gratuito, 500 créditos al mes):** una llamada cuesta mercados × regiones. Con 3 mercados principales (h2h, spreads, totals) en la región `us` = 3 créditos y devuelve todos los partidos. Cálculo semanal: 1 apertura + 4 diarias + ~6 horarios de kickoff ≈ 11 llamadas ≈ 33 créditos → **≈ 145 créditos al mes**. Cabe en el plan gratuito. Las líneas alternas y los props se cobran por partido y el histórico cuesta 10×, así que quedan fuera hasta F2.

**Playdoit:** sin cambios. Los momios del boleto, el folio, el bono y el cash-out los registra Jabo desde el front; ningún proceso programado toca Playdoit.

## 4. Front (Lovable + Netlify)

| Elemento | Decisión |
| --- | --- |
| Construcción | Lovable, proyecto `laboratorio-nfl-web`, conectado a **tu** Supabase (`labnfl-dev`), no a Lovable Cloud |
| Reglas de Lovable | `docs/lovable_instrucciones.md`, pegadas en el Knowledge del proyecto de Lovable. Resumen: no crea esquema ni Edge Functions, no calcula probabilidades, solo inserta en `book.*` |
| Repositorio | Lo crea Lovable en GitHub (`JaboLab/laboratorio-nfl-web`) con sincronización en ambos sentidos |
| Autenticación | Supabase Auth con magic link; solo el correo de Jabo está permitido (RLS) |
| Despliegue | Netlify importa `laboratorio-nfl-web`. Producción desde `main` con `labnfl-prod`; deploy previews con `labnfl-dev` |
| Variables en Netlify | URL de Supabase y llave pública (los nombres exactos los define el proyecto de Lovable). Nunca la llave `service_role` |
| Funciones de Netlify | Ninguna en F0–F1 |
| Flujo de cambios | Pantallas: Lovable. Datos nuevos: Jabo lo pide → Claude agrega migración y vista con pruebas en `laboratorio_nfl` → Lovable las consume |

**Consola mínima en F0 (aceptada, PRD v1.1):** registro de boletos y cash-out (primero, porque las tablas ya existen), cartelera M0 y desempeño básico (cuando existan sus vistas en S2–S3).

## 5. Plan por fases y sprints

Semana 1 de la temporada 2026 = domingo 13 sep, así que la Semana 18 = domingo 10 ene 2027.

### F0 — Fundaciones (9 nov 2026 – 17 ene 2027)

| Sprint | Fechas | Entregables | Criterio de terminado | Horas est. |
| --- | --- | --- | --- | --- |
| **S0 Arranque** | 9 – 14 nov | Decisión D1. Repositorio `laboratorio_nfl` con CI, proyectos `labnfl-dev`/`labnfl-prod` con la migración inicial, proyecto de Lovable conectado a `labnfl-dev`, sitio en Netlify. **Plantilla CSV en papel para la Semana 10** | CI en verde; migración aplicada en dev; consola publicada en Netlify con inicio de sesión; la Semana 10 se emite en papel antes del kickoff | 8 |
| **S1 Datos históricos + M0** | 16 – 28 nov | Pantalla de registro de boletos en Lovable. Ingesta nflverse 2018–2025 (partidos, cierres, resultados). Librería M0 (implícita, devig, CLV, valor justo) con pruebas | Desde la base se reproduce el **Brier 0.211** del backtest; pruebas de M0 con casos conocidos (−110/−110 → 50.0%/50.0%) | 12 |
| **S2 Capturas en vivo** | 30 nov – 12 dic | Edge Function `capture-odds`, tareas pg_cron, validaciones de calidad, ingesta de lesiones. Migración `book`; carga de las semanas 9–12 | Los cierres de la Semana 14 se capturan solos dentro de la ventana de 5–15 min; `v_pit_violations` = 0 | 12 |
| **S3 Reporte + consola** | 14 dic – 10 ene | Reporte semanal automático (lunes) con Brier, CLV y ROI con IC bootstrap por semana. Vistas `report.v_cartelera` y de métricas; pantallas de cartelera y desempeño en Lovable | El reporte de la Semana 16 se genera sin intervención | 16 |
| **G0** | 11 – 17 ene | Revisión de la compuerta G0 | Semanas 10–18 registradas sin huecos; prueba point-in-time en verde todas las semanas | 3 |

### F1 — Motores (18 ene – 28 mar 2027)

| Sprint | Entregables | Criterio de terminado |
| --- | --- | --- |
| S4 | Features point-in-time (descanso, viaje, QB, local); M1 Elo con walk-forward 2010–2025 | Brier y log loss de M1 contra M0 con IC95, por temporada |
| S5 | M3 distribución del margen (masa en 3, 6, 7, 10, 14); precio justo de líneas alternas | Reproduce el valor del medio punto sobre el 3 (≈ −141) y el 7 (≈ −131) del backtest |
| S6 | M5 ensamble (M0+M1+M3) con recalibración isotónica; `model_registry` campeón/retador | Curva de calibración con bandas; comparación contra M0 |
| S7 | Portafolio: calculadora de bono, validador de reglas, Monte Carlo conjunto, valor justo de cash-out, exportación de boleto | El simulador reproduce la Semana 9 (EV ≈ −$236; P(ganancia) ≈ 22%; P(perder todo) ≈ 40%) |
| G1 | Revisión | Ver PRD sección 14 |

### F2 — Producto (abr – ago 2027)

| Bloque | Entregables | Dependencia |
| --- | --- | --- |
| Datos | Play-by-play nflverse; momios de props (The Odds API de pago u OddsPapi, según D4 y D9) | Presupuesto D4 |
| Modelos | M2 (EPA con encogimiento); M4 props (Poisson / binomial negativa) | Datos de props |
| Front (Lovable) | Las 6 pantallas del PRD; tooltip de fuente, hora y versión en cada cifra; modo real con color y aviso | Consola de F0 como base |
| Tutor y aula | Edge Function `tutor` que solo cita cifras consultadas en la base; prueba automática que rechaza cifras sin origen | Llave de API del LLM en los secretos de Supabase |
| Infraestructura | Pasar `labnfl-prod` a Supabase Pro antes de septiembre (sin pausa por inactividad, respaldos diarios) | Presupuesto |

### F3 — Temporada 2027 en papel (sep 2027 – ene 2028) y F4 (desde feb 2028)

Solo operación, monitoreo y la compuerta del PRD. No se agregan modelos nuevos durante la temporada salvo como retadores ya pre-registrados.

## 6. Pruebas y calidad

| Nivel | Qué se prueba | Dónde |
| --- | --- | --- |
| Unitarias (pytest) | Matemática de M0, bono, Kelly, reglas, simulador con semilla fija | CI en cada PR |
| Base (pgTAP) | RLS por rol, inmutabilidad de `predictions`, `v_pit_violations` vacía | CI en cada PR |
| Datos | Rangos de momios, suma de implícitas 1.00–1.15, duplicados, horas en orden | En cada ingesta; si falla, la fila va a cuarentena |
| Reproducibilidad | Reconstruir el reporte de una semana pasada desde `raw` y comparar el hash | Mensual |
| Front | Revisión de cada deploy preview de Netlify contra `docs/lovable_instrucciones.md` (sin SQL nuevo, sin cálculos en el front, sin llave `service_role`) | Por cambio |
| Estadística | Toda comparación con IC95 bootstrap por bloques de semana; hipótesis pre-registradas | Reporte semanal |

## 7. Operación semanal durante F0 (horas CST)

| Día | Automático | Jabo |
| --- | --- | --- |
| Lunes | Resultados y reporte semanal | Revisar el reporte (15 min) |
| Martes | Captura de apertura | Emitir predicciones en papel (M0 + las del proceso actual, con `p_method` correcto) |
| Mié – sáb | Capturas diarias, lesiones | — |
| Domingo | Cierres 5–15 min antes de cada kickoff | Capturar ofertas de cash-out de boletos en papel si aplica (valor justo calculado) |

## 8. Costos

| Concepto | F0–F1 | F2 | F3 en adelante |
| --- | --- | --- | --- |
| Supabase | US$0 (2 proyectos gratis) | US$0–25/mes | **US$25/mes** (Pro: sin pausa, respaldos) |
| Netlify | US$0 | US$0 | US$0 |
| Lovable | Plan actual de Jabo | Según uso | Según uso |
| GitHub | US$0 | US$0 | US$0 |
| The Odds API | US$0 (≈145 de 500 créditos al mes) | Plan de pago si se usan props o histórico (D4) | Según D4 |
| LLM del tutor | — | Por definir | Por definir |

**Riesgo del plan gratuito:** Supabase pausa los proyectos gratuitos tras 7 días sin actividad. En temporada las capturas lo mantienen activo; en la pretemporada (feb–ago) corre el workflow `keepalive.yml` cada 3 días.

## 9. Riesgos de implementación

| Riesgo | Mitigación |
| --- | --- |
| Capacidad de horas de Jabo | Sprints de 2 semanas con un solo entregable que se pueda demostrar; lo que no cabe se mueve, no se comprime |
| Créditos de The Odds API agotados en domingo | Alerta al 80%; las capturas de cierre tienen prioridad sobre las diarias |
| Falla de una captura de cierre | Reintento a los 2 min; alerta al celular; si se pierde, el cierre de esa pata queda `NO_ENCONTRADO` (nunca se rellena después) |
| Cambio de esquema que rompe datos históricos | Migraciones solo hacia adelante, probadas en `labnfl-dev` antes de producción |
| Fuga de la llave `service_role` | Solo en secretos de GitHub y Supabase; nunca en el front ni en el repo; rotación si hay duda |
| Desarrollo en Windows | Supabase CLI requiere Docker para la base local; alternativa: desarrollar directo contra `labnfl-dev` |

## 10. Próximos 7 días (S0)

| # | Tarea | Dueño | Estado |
| --- | --- | --- | --- |
| 1 | D3: repositorio `JaboLab/laboratorio_nfl` | Jabo | ✅ |
| 2 | Aceptar Lovable + consola mínima en F0 | Jabo | ✅ |
| 3 | Dar acceso de la app de Claude en GitHub al repositorio privado | Jabo | Pendiente |
| 4 | Subir el esqueleto (M0 con pruebas, migración inicial con pruebas, CI, docs) | Claude | Listo para subir |
| 5 | Conectar Supabase en la sesión de Claude; crear `labnfl-dev` y `labnfl-prod`; aplicar la migración; exponer esquemas; registrar el correo permitido | Jabo + Claude | Pendiente |
| 6 | Crear el proyecto `laboratorio-nfl-web` en Lovable, conectarlo a `labnfl-dev` y a GitHub, pegar `docs/lovable_instrucciones.md` | Jabo | Pendiente |
| 7 | Importar `laboratorio-nfl-web` en Netlify y cargar las variables | Jabo + Claude | Pendiente |
| 8 | Decidir D1 (fondo y límites) | Jabo | Pendiente |
| 9 | Registrarse en The Odds API (plan gratuito) | Jabo | Pendiente |
| 10 | Plantilla CSV para la Semana 10 en papel | Claude | Pendiente |

## Historial

| Versión | Fecha | Cambios |
| --- | --- | --- |
| v1.0 | 2026-11-07 | Plan inicial |
| v1.1 | 2026-11-07 | Repositorio `JaboLab/laboratorio_nfl`. Front con Lovable en repositorio propio, desplegado en Netlify (ADR-008). Consola mínima en F0. Carpeta `web/` retirada del backend |

## Fuentes

- Netlify, Scheduled Functions (límite de 30 s, cron en UTC): https://docs.netlify.com/build/functions/scheduled-functions/
- The Odds API: costo por llamada = mercados × regiones; histórico 10×: https://oddspapi.io/blog/the-odds-api-free-tier-limits (resume la documentación de The Odds API; verificar en https://the-odds-api.com antes de comprar plan)
- Supabase, plan gratuito (2 proyectos, pausa tras 7 días de inactividad): https://automationatlas.io/answers/supabase-free-tier-limits-2026/ (verificar en https://supabase.com/pricing)
