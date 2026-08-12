-- =============================================================================
-- _status.sql — was macht PostgreSQL gerade?
--
-- In einem ZWEITEN Terminal ausführen, während die Kette läuft:
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\_status.sql
--
-- Zweimal im Abstand von einer Minute aufrufen. Wächst die Tabellengröße,
-- arbeitet der INSERT. Bleibt sie stehen und steht bei wait_event etwas
-- anderes als NULL, hängt etwas.
-- =============================================================================

\echo '=== Aktive Abfragen ========================================================'
SELECT pid,
       to_char(now() - query_start, 'HH24:MI:SS')      AS laeuft_seit,
       state,
       coalesce(wait_event_type, '-')                  AS wartet_auf_typ,
       coalesce(wait_event, 'nichts, rechnet')         AS wartet_auf,
       left(regexp_replace(query, '\s+', ' ', 'g'), 70) AS abfrage
FROM pg_stat_activity
WHERE datname = 'bd_co2' AND state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;

\echo ''
\echo '=== Groesse der Faktentabelle (zweimal messen!) ============================'
SELECT c.relname                                       AS tabelle,
       to_char(c.reltuples::bigint, 'FM999G999G999')    AS zeilen_geschaetzt,
       pg_size_pretty(pg_total_relation_size(c.oid))    AS groesse
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'star' AND c.relname LIKE 'fact_registration%'
ORDER BY c.relname;

\echo ''
\echo '=== Zeilen in den bereits fertigen Schichten ==============================='
SELECT 'core.registration' AS tabelle, count(*) AS zeilen FROM core.registration
UNION ALL SELECT 'core.realworld', count(*) FROM core.realworld;

\echo ''
\echo '>>> Waechst die Groesse zwischen zwei Aufrufen, laeuft alles.'
\echo '>>> Steht wait_event auf einem Lock, gibt es ein Problem - dann melden.'
