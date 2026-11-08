# Laboratorio NFL

Simulador propio de predicción NFL con base de datos point-in-time, motores validados contra el mercado de cierre y motor de portafolio con el espíritu de NFL_Mesa y NFL_Risk.

- Documento rector: PRD v1.1 (privado; no se publica en este repositorio porque contiene datos personales de operación)
- Plan: [`docs/Plan_Implementacion_Laboratorio_NFL_v1.1_2026-11-07.md`](docs/Plan_Implementacion_Laboratorio_NFL_v1.1_2026-11-07.md)

**Modo papel.** Ningún componente coloca, cierra ni hace cash-out en Playdoit.

## Estructura

| Carpeta | Contenido |
| --- | --- |
| `labnfl/` | Paquete Python. Hoy: `market` (M0: momios, sin margen, EV, CLV, valor justo) |
| `tests/` | Pruebas pytest |
| `supabase/migrations/` | Esquema `ref`, `raw`, `core`, `model`, `book`, `report` con RLS |
| `supabase/tests/` | Pruebas SQL de la migración (solo inserción, point-in-time, RLS) |
| `docs/` | PRD, plan, reportes |

## Desarrollo local

```bash
pip install -e ".[dev]"
ruff check . && pytest -q
```

## Supabase

Proyectos: `labnfl-dev` y `labnfl-prod`.

1. Aplicar migraciones: `supabase link --project-ref <ref>` y `supabase db push`.
2. En **Settings → API → Exposed schemas**, agregar `core, model, book, report` (y `ref` si el front la necesita).
3. Registrar el correo permitido (no se guarda en el repo):
   `insert into ref.allowed_users values ('<correo>');`
4. En **Authentication**, desactivar el registro abierto y usar magic link.

Secretos: la llave `service_role` solo va en los secretos de GitHub Actions y de Supabase. Nunca en el front.

## Front (Lovable + Netlify)

El front vive en otro repositorio, `laboratorio-nfl-web`, creado y sincronizado por Lovable, y se despliega en Netlify desde ese repositorio. Usa solo la llave pública de Supabase.

**Este repositorio es el dueño del esquema.** Lovable no crea tablas, migraciones, políticas ni Edge Functions; sus reglas están en [`docs/lovable_instrucciones.md`](docs/lovable_instrucciones.md). Si el front necesita un dato nuevo, se agrega aquí con una migración probada.
