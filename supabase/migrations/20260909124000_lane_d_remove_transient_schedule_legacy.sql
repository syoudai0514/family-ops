-- Lane D cleanup for the temporary compatibility detour introduced by
-- 20260909122000. 20260909123000 restored the canonical historical
-- server_tx_get_today_schedule(uuid) contract and moved LINE `今日` to its
-- dedicated DailyBrief reader, so this renamed duplicate has no remaining
-- caller or authority and must not survive as a second schedule truth.

drop function if exists public.server_read_today_schedule_legacy_v1(uuid);
