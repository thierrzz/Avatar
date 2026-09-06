-- E13.8 (2026-09-06): Messages krijgt `targeting.maxAppVersion` naast
-- `minAppVersion`, zodat een "installeer de DMG opnieuw"-bericht alléén de
-- 2.0.0/2.0.1-installs bereikt (die missen de Sparkle-sandbox-entitlements en
-- kunnen zichzelf niet via het feed repareren); 2.0.2+ valt eruit.
-- Backend-filter: api/v1/messages.ts (withinMaxVersion, zelfde helper als
-- announcements/021).
--
-- Payload-schema is handmatig (push:false). Group-velden worden plat
-- opgeslagen als <group>_<veld> (zie 019: "targeting_min_app_version").
-- Idempotent. Toepassen in de Supabase SQL-editor VÓÓR de admin-deploy
-- (= vóór de main-push): een ontbrekende kolom maakt de Messages-detailpagina
-- zwart en laat /v1/messages soft-failen op een lege lijst.

ALTER TABLE "payload"."messages"
  ADD COLUMN IF NOT EXISTS "targeting_max_app_version" varchar;

-- Verificatie:
--   select column_name, data_type from information_schema.columns
--    where table_schema = 'payload' and table_name = 'messages'
--      and column_name in ('targeting_min_app_version', 'targeting_max_app_version');
