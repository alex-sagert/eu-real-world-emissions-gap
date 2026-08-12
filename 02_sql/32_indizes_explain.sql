-- =============================================================================
-- 32_indizes_explain.sql   ·   Tag 2   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\32_indizes_explain.sql -OutFile .\00_doku\explain_ausgabe.txt
--
-- Zwei Dinge in einer Datei:
--   A) Der Nachweis, dass Partitionierung etwas bringt — EXPLAIN ANALYZE mit
--      abgeschaltetem und eingeschaltetem Partition Pruning. Sauberer als ein
--      Vergleich gegen eine unpartitionierte Kopie, weil derselbe Datenbestand,
--      dieselbe Query, nur ein Planner-Schalter unterschiedlich ist.
--   B) Indizes anlegen — ERST JETZT, nach dem Laden — und der Vorher/Nachher-
--      Vergleich für dieselbe Query.
--
-- Die Ausgabe dieser Datei geht als Beleg in den Bericht. Die Laufzeiten bitte aus der
-- Ausgabedatei ins LOGBUCH.md übertragen.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

-- -----------------------------------------------------------------------------
-- Sitzungsparameter fuer die Schwerarbeit
--
-- PostgreSQL laeuft mit work_mem = 4 MB aus der Standardkonfiguration. Bei
-- Sortierungen und Hash-Aggregaten ueber zweistellige Millionenzeilen reicht das
-- nicht annaehernd - jede Gruppierung landet auf der Platte und der Schritt
-- dauert ein Vielfaches. Die Anhebung gilt nur fuer diese Sitzung, die
-- Serverkonfiguration bleibt unangetastet.
--
-- Der Effekt gehoert in den Bericht: Er ist mit EXPLAIN (ANALYZE, BUFFERS) sichtbar
-- als Wechsel von "external merge Disk" zu "quicksort Memory".
-- -----------------------------------------------------------------------------
SET work_mem = '256MB';
SET maintenance_work_mem = '1GB';
SET max_parallel_workers_per_gather = 4;
SET synchronous_commit = off;   -- nur Ladelauf, kein Produktivbetrieb

\echo '############################################################'
\echo '# A · Partition Pruning'
\echo '############################################################'

-- Testfrage: Antriebsmix in Deutschland im Jahr 2025.
-- Ohne Pruning muss der Planner alle sechs Partitionen anfassen,
-- mit Pruning genau eine.

\echo ''
\echo '--- A1 · OHNE Partition Pruning -------------------------------------------'
SET enable_partition_pruning = off;
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT p.antriebsklasse, count(*) AS n, round(avg(f.co2_wltp), 1) AS avg_co2
FROM star.fact_registration f
JOIN star.dim_powertrain p ON p.powertrain_sk = f.powertrain_sk
JOIN star.dim_country   c ON c.country_sk    = f.country_sk
WHERE f.jahr = 2025 AND c.ms_code = 'DE'
GROUP BY p.antriebsklasse;

\echo ''
\echo '--- A2 · MIT Partition Pruning --------------------------------------------'
SET enable_partition_pruning = on;
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT p.antriebsklasse, count(*) AS n, round(avg(f.co2_wltp), 1) AS avg_co2
FROM star.fact_registration f
JOIN star.dim_powertrain p ON p.powertrain_sk = f.powertrain_sk
JOIN star.dim_country   c ON c.country_sk    = f.country_sk
WHERE f.jahr = 2025 AND c.ms_code = 'DE'
GROUP BY p.antriebsklasse;

\echo ''
\echo '>>> Im Plan A2 steht bei den Partitionen "(never executed)" bzw. es tauchen'
\echo '>>> nur fact_registration_2025 und _rest auf. Genau das ist der Beweis.'

\echo ''
\echo '############################################################'
\echo '# B · Indizes — vorher/nachher'
\echo '############################################################'

-- Testfrage: alle Plug-in-Hybride eines Herstellerpools in Deutschland.
-- Ohne Index bleibt nur ein Sequential Scan über die Jahrespartition.

\echo ''
\echo '--- B1 · VOR dem Index ----------------------------------------------------'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS n, round(avg(f.co2_wltp), 1) AS avg_co2
FROM star.fact_registration f
JOIN star.dim_powertrain p ON p.powertrain_sk = f.powertrain_sk
WHERE f.jahr = 2025 AND p.antriebsklasse = 'PHEV';

\echo ''
\echo '--- B2 · Indizes anlegen --------------------------------------------------'

-- Auf der partitionierten Tabelle angelegt, PostgreSQL erzeugt die
-- Partitionsindizes automatisch mit.
CREATE INDEX IF NOT EXISTS ix_fact_powertrain    ON star.fact_registration (powertrain_sk);
CREATE INDEX IF NOT EXISTS ix_fact_country       ON star.fact_registration (country_sk);
CREATE INDEX IF NOT EXISTS ix_fact_manufacturer  ON star.fact_registration (manufacturer_sk);
CREATE INDEX IF NOT EXISTS ix_fact_model         ON star.fact_registration (model_sk);
CREATE INDEX IF NOT EXISTS ix_fact_date          ON star.fact_registration (date_sk);

-- Abdeckender Index für A1/A2 (Antriebsmix je Land und Jahr): der Planner kann
-- die Aggregation aus dem Index bedienen, ohne die Tabelle anzufassen.
CREATE INDEX IF NOT EXISTS ix_fact_a1
    ON star.fact_registration (jahr, country_sk, powertrain_sk)
    INCLUDE (co2_wltp, masse_kg);

-- GIN für die tokenisierten Öko-Innovationscodes (H5): erlaubt
-- WHERE oeko_codes @> ARRAY['29'] ohne vollen Scan.
CREATE INDEX IF NOT EXISTS ix_fact_oeko ON star.fact_registration USING gin (oeko_codes);

\echo ''
\echo '--- B3 · Statistiken aktualisieren ----------------------------------------'
\echo '>>> Ohne ANALYZE wählt der Planner auf Basis veralteter Schätzungen Unsinn.'
ANALYZE star.fact_registration;
ANALYZE star.dim_powertrain;
ANALYZE star.dim_country;
ANALYZE star.dim_manufacturer;
ANALYZE star.dim_model;
ANALYZE star.dim_date;

\echo ''
\echo '--- B4 · NACH dem Index (dieselbe Query wie B1) ---------------------------'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS n, round(avg(f.co2_wltp), 1) AS avg_co2
FROM star.fact_registration f
JOIN star.dim_powertrain p ON p.powertrain_sk = f.powertrain_sk
WHERE f.jahr = 2025 AND p.antriebsklasse = 'PHEV';

\echo ''
\echo '--- B5 · Öko-Innovation über den GIN-Index (H5) ---------------------------'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS n
FROM star.fact_registration
WHERE jahr = 2025 AND oeko_codes @> ARRAY['29'];

\echo ''
\echo '############################################################'
\echo '# C · Größen'
\echo '############################################################'

SELECT c.relname AS objekt,
       pg_size_pretty(pg_relation_size(c.oid))        AS tabelle,
       pg_size_pretty(pg_indexes_size(c.oid))         AS indizes,
       pg_size_pretty(pg_total_relation_size(c.oid))  AS gesamt
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('raw', 'core', 'star')
  AND c.relkind IN ('r', 'p')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 25;

\echo ''
\echo '>>> Fertig. Laufzeiten aus A1/A2 und B1/B4 ins LOGBUCH.md übertragen.'
