# Instrucciones para el proyecto de Lovable — Laboratorio NFL (front)

> Pegar todo lo que está debajo de la línea en **Project Settings → Knowledge** del proyecto de Lovable `laboratorio-nfl-web`.
> Versión 1.0 · 2026-11-07 · Se actualiza cuando cambie el contrato de datos de este repositorio (`JaboLab/laboratorio_nfl`).

---

## Rol de este proyecto

Eres el front del "Laboratorio NFL": una consola web personal (un solo usuario) para revisar probabilidades del mercado y de los modelos, registrar boletos en papel y ver desempeño. El backend (base de datos, migraciones, motores en Python, Edge Functions) vive en otro repositorio y **no se toca desde aquí**.

## Reglas de backend (no negociables)

1. **No crees, alteres ni borres tablas, vistas, funciones, triggers, políticas RLS ni migraciones.** Si una pantalla necesita un dato o una vista que no existe, detente y escribe en el chat: "FALTA EN BACKEND: <qué necesito y por qué>". No lo implementes con SQL.
2. **No crees Edge Functions ni secretos** en Supabase.
3. Usa solo la llave pública (`anon`/publishable). **Nunca** uses ni pidas la llave `service_role`.
4. No uses Lovable Cloud. El backend es el proyecto de Supabase ya conectado (`labnfl-dev` en desarrollo, `labnfl-prod` en producción).
5. **El front no calcula probabilidades, valor esperado, CLV ni valor justo.** Esos números vienen de la base (vistas `report.*` y tablas `model.*`). El front solo los formatea y muestra.
6. Ninguna función automatiza Playdoit: no hay botones de "apostar", "cerrar" ni "cash-out". La integración es exportar un boleto (texto o CSV) para que Jabo lo coloque a mano.

## Autenticación

- Supabase Auth con **magic link** al correo de Jabo. Sin registro abierto ni otros proveedores.
- Toda pantalla requiere sesión. Sin sesión, solo se muestra la pantalla de acceso.
- La base ya filtra por correo permitido (RLS); si una consulta vuelve vacía con sesión válida, mostrar "Usuario sin permiso", no un error genérico.

## Acceso a datos

Los datos no están en `public`; usa el esquema explícito con `supabase-js`:

```ts
supabase.schema("book").from("tickets").insert({...})
supabase.schema("core").from("games").select("*")
```

| Esquema | Front puede | Tablas / vistas |
| --- | --- | --- |
| `core` | leer | `games`, `odds_snapshots`, `injuries` |
| `model` | leer | `predictions`, `model_registry`, `hypotheses` |
| `report` | leer | vistas de métricas (se irán agregando; hoy `v_pit_violations`) |
| `book` | leer e **insertar** | `tickets`, `ticket_legs`, `cashout_offers`, `bankroll_ledger` |
| `ref`, `raw` | nada | — |

**Solo inserción en `book`:** no hay UPDATE ni DELETE. Una corrección es una fila nueva con `note` que explique qué corrige.

### Contrato de `book` (resumen)

| Tabla | Campos que llena el front |
| --- | --- |
| `tickets` | `block` ('mesa' / 'risk' / 'fuera_de_plan'), `mode` ('papel' por defecto; 'real' exige `playdoit_folio`), `stake_mxn`, `playdoit_folio`, `price_total_american`, `bonus_shown_mxn`, `potential_payout_mxn`, `placed_at`, `note` |
| `ticket_legs` | `ticket_id`, `leg` (1..n), `game_id`, `market`, `market_literal` (texto exacto de Playdoit), `selection`, `line`, `price_american_taken`, `prediction_id` (opcional) |
| `cashout_offers` | `ticket_id`, `captured_at` (hora de la pantalla de Playdoit), `offer_mxn`, `accepted` |
| `bankroll_ledger` | `occurred_at`, `kind` ('deposito' / 'stake' / 'pago' / 'retiro' / 'ajuste'), `amount_mxn`, `ticket_id`, `in_plan`, `note` |

`recorded_at`, `emitted_at` e ids los pone la base; no los envíes.

## Convenciones de interfaz

- Idioma español (México).
- Horas en **America/Mexico_City, formato 24 h** (la base guarda UTC).
- Momios en **formato americano** (−110, +150). Probabilidades en **% con un decimal** (80.8%).
- Montos en MXN con dos decimales.
- Toda cifra muestra al pasar el cursor: **fuente, hora de captura/emisión y versión del modelo**.
- Valor nulo de probabilidad de mercado = mostrar **NO_ENCONTRADO**, nunca 0 ni guion.
- Banda fija arriba: **MODO PAPEL** (verde). Si algún día un boleto es `mode = 'real'`, se marca en rojo con aviso permanente.
- Cabecera con fondo, límites y pérdida acumulada cuando existan en la base (hoy pendiente: mostrar "Límites sin definir").

## Pantallas — consola F0 (en este orden)

1. **Registro de boletos** (primero; ya hay tablas): formulario de boleto + patas + oferta de cash-out; tabla de boletos con sus patas y ofertas. Exportar boleto a texto.
2. **Cartelera M0** (cuando exista la vista `report.v_cartelera`): partidos de la semana, probabilidad sin margen, momio de Playdoit, EV y ventaja. Solo lectura.
3. **Desempeño** (cuando existan las vistas de métricas): Brier, CLV y ROI con intervalos de confianza, por semana y por método de probabilidad.

Las pantallas de F2 (armador, simulador, en vivo, aula) se agregan después; no las construyas todavía.

## Estilo

Sobrio y legible: fondo claro con modo oscuro, tipografía de sistema, tablas densas con números alineados a la derecha, sin animaciones decorativas. Prioridad: que un número sea fácil de leer y de verificar.
