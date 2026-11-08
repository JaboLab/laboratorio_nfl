-- Asesor de seguridad de Supabase (lint 0011): fijar search_path en las funciones de trigger.
alter function ref.forbid_change() set search_path = '';
alter function ref.force_now() set search_path = '';
