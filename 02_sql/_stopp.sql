-- =============================================================================
-- _stopp.sql — hängengebliebene Abfragen beenden
--
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\_stopp.sql
--
-- Wozu: Strg+C im PowerShell-Fenster beendet zwar psql, aber nicht immer die
-- Abfrage auf dem Server. Die läuft dann weiter, hält ihre Sperren, und der
-- nächste Lauf blockiert beim DROP TABLE. Genau das ist am 12.08.2026 passiert:
-- ein INSERT lief noch nach 1:14 h weiter, während der Neustart auf die
-- Relationssperre wartete.
--
-- Dieses Skript beendet alle aktiven Abfragen in bd_co2 ausser der eigenen.
-- =============================================================================

\echo '=== Was laeuft gerade? ====================================================='
SELECT pid,
       to_char(now() - query_start, 'HH24:MI:SS')       AS laeuft_seit,
       state,
       coalesce(wait_event, 'rechnet')                  AS wartet_auf,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS abfrage
FROM pg_stat_activity
WHERE datname = 'bd_co2' AND state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;

\echo ''
\echo '=== Diese Abfragen werden jetzt beendet ==================================='
-- Erst freundlich absagen (pg_cancel_backend), dann hart beenden
-- (pg_terminate_backend), falls die Absage nicht greift. Ein laufender
-- INSERT wird dabei vollstaendig zurueckgerollt - es bleibt kein
-- halbfertiger Datenbestand zurueck.
SELECT pid,
       left(regexp_replace(query, '\s+', ' ', 'g'), 50) AS abfrage,
       pg_cancel_backend(pid)                           AS abgesagt
FROM pg_stat_activity
WHERE datname = 'bd_co2' AND state <> 'idle' AND pid <> pg_backend_pid();

SELECT pg_sleep(3);

SELECT pid,
       left(regexp_replace(query, '\s+', ' ', 'g'), 50) AS abfrage,
       pg_terminate_backend(pid)                        AS beendet
FROM pg_stat_activity
WHERE datname = 'bd_co2' AND state <> 'idle' AND pid <> pg_backend_pid();

\echo ''
\echo '=== Danach sollte hier nichts mehr stehen ================================='
SELECT pid, state, left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS abfrage
FROM pg_stat_activity
WHERE datname = 'bd_co2' AND state <> 'idle' AND pid <> pg_backend_pid();

\echo ''
\echo '>>> Jetzt neu starten:  .\03_skripte\99_run_all.ps1 -Ab 30_star'
