-- =============================================================================
-- 41_analysen_A4_A5.sql   ·   Tag 3   ·   läuft gegen bd_co2 nach 25_core_realworld.sql
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\41_analysen_A4_A5.sql -OutFile .\00_doku\a4_a5_ausgabe.txt
--
--   A4  Realverbrauchslücke je Antriebsklasse, Median und P90   -> H1
--   A5  Rangfolgen-Umkehr offiziell gegen real, je Modell        -> H2
--
-- Diese Datei muss die Werte aus 00_doku/06_Ergebnis_Realverbrauchsluecke.md
-- reproduzieren. Weicht sie ab, ist die Pipeline fehlerhaft, nicht die
-- Vorab-Auswertung. Erwartet für Deutschland (Median, Filter eea_verwendbar
-- und hat_mindestlauf):
--     Benzin rein   7,44 real / 6,40 WLTP / +16,0 %
--     Diesel rein   6,59 / 5,60 / +16,6 %
--     PHEV Benzin   6,00 / 1,30 / +317,8 %
--     PHEV Diesel   6,27 / 1,40 / +335,5 %
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
-- Der Effekt gehoert ins NvS: Er ist mit EXPLAIN (ANALYZE, BUFFERS) sichtbar
-- als Wechsel von "external merge Disk" zu "quicksort Memory".
-- -----------------------------------------------------------------------------
SET work_mem = '256MB';
SET maintenance_work_mem = '1GB';
SET max_parallel_workers_per_gather = 4;
SET synchronous_commit = off;   -- nur Ladelauf, kein Produktivbetrieb

-- =============================================================================
-- A4 · Die Realverbrauchslücke
--
-- PERCENTILE_CONT statt avg(): Der Median ist hier belastbarer, weil einzelne
-- Fahrzeuge mit extremer Nutzung den Mittelwert verschieben. P90 zeigt, wie
-- weit das obere Ende reicht — bei PHEV ist genau das die Aussage.
-- =============================================================================
DROP TABLE IF EXISTS mart.a4_luecke;
CREATE TABLE mart.a4_luecke AS
SELECT land,
       antriebsklasse,
       jahr,
       count(*)                                                              AS fahrzeuge,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY dist_total_km)::numeric, 0) AS median_laufleistung,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_real)::numeric, 2)  AS median_real_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_wltp)::numeric, 2)  AS median_wltp_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_abs)::numeric, 2)  AS median_gap_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS median_gap_pct,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS p90_gap_pct,
       round(percentile_cont(0.1) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS p10_gap_pct,
       round(avg(gap_pct), 1)                                                AS mittelwert_gap_pct,
       -- Beim PHEV: wie viel wurde tatsaechlich elektrisch gefahren?
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY anteil_elektrisch)::numeric, 1) AS median_e_anteil_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY grid_kwh)::numeric, 0)  AS median_netzstrom_kwh
FROM core.realworld
WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
GROUP BY land, antriebsklasse, jahr;

CREATE INDEX ix_a4 ON mart.a4_luecke (land, antriebsklasse, jahr);
COMMENT ON TABLE mart.a4_luecke IS 'A4 — Realverbrauchsluecke je Land, Antriebsklasse und Zulassungsjahr. Median und Perzentile. Grundlage fuer H1.';

\echo ''
\echo '=== A4 · Deutschland, alle Zulassungsjahre zusammen ======================='
SELECT antriebsklasse,
       sum(fahrzeuge)                                     AS fahrzeuge,
       round(avg(median_real_l), 2)                       AS real_l,
       round(avg(median_wltp_l), 2)                       AS wltp_l,
       round(avg(median_gap_pct), 1)                      AS gap_median_pct,
       round(avg(p90_gap_pct), 1)                         AS gap_p90_pct,
       round(avg(median_e_anteil_pct), 1)                 AS e_anteil_pct
FROM mart.a4_luecke WHERE land = 'DE'
GROUP BY antriebsklasse ORDER BY fahrzeuge DESC;

-- -----------------------------------------------------------------------------
-- A4a2 · Gepoolter Median, nicht Mittelwert der Jahresmediane
--
-- WICHTIG fuer das NvS. Die Abfrage darueber bildet avg() ueber die
-- Jahresmediane - jeder Zulassungsjahrgang zaehlt dort gleich viel, egal ob er
-- 20.000 oder 120.000 Fahrzeuge umfasst. Die Vorab-Auswertung in
-- 06_Ergebnis_Realverbrauchsluecke.md hat dagegen den Median ueber alle
-- Fahrzeuge gemeinsam gebildet.
--
-- Beide Zahlen sind richtig, sie beantworten nur verschiedene Fragen. Weil die
-- Abweichung sonst wie ein Pipelinefehler aussieht, wird sie hier explizit
-- nebeneinander gestellt. Ins NvS geht der gepoolte Median: er gewichtet jedes
-- Fahrzeug gleich, und genau das ist die Aussage von H1.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== A4a2 · Gepoolter Median ueber ALLE Zulassungsjahre (DE) ==============='
\echo '>>> Diese Zahlen sind die massgeblichen fuer H1, nicht die Zeile darueber.'
SELECT antriebsklasse,
       count(*)                                                             AS fahrzeuge,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_real)::numeric, 2)  AS real_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_wltp)::numeric, 2)  AS wltp_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS gap_median_pct,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS gap_p90_pct
FROM core.realworld
WHERE land = 'DE' AND eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
GROUP BY antriebsklasse
ORDER BY count(*) DESC;

-- -----------------------------------------------------------------------------
-- mart.a4_luecke_gepoolt — die massgebliche Ergebnistabelle
--
-- Warum es diese Tabelle zusaetzlich braucht: mart.a4_luecke haelt einen Median
-- JE ZULASSUNGSJAHRGANG. Wer daraus einen Gesamtwert bilden will, kann nur den
-- Mittelwert der Jahresmediane nehmen — und der gewichtet 2023 mit 27.000
-- Fahrzeugen genauso stark wie 2022 mit 120.000. Genau diese Abweichung war in
-- der Streamlit-Anwendung sichtbar: 352,9 % statt der berichteten 320,7 %.
--
-- Der Median laesst sich nicht nachtraeglich aus Teilmedianen zusammensetzen.
-- Er muss ueber die Einzelfahrzeuge gerechnet werden. Deshalb diese Tabelle:
-- Bericht, Praesentation und Anwendung lesen ab jetzt dieselbe Quelle.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS mart.a4_luecke_gepoolt;
CREATE TABLE mart.a4_luecke_gepoolt AS
SELECT land,
       antriebsklasse,
       count(*)                                                              AS fahrzeuge,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_real)::numeric, 2)  AS real_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_wltp)::numeric, 2)  AS wltp_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_abs)::numeric, 2)  AS gap_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS gap_median_pct,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS gap_p90_pct,
       round(percentile_cont(0.1) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS gap_p10_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY anteil_elektrisch)::numeric, 1) AS e_anteil_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY dist_total_km)::numeric, 0) AS laufleistung_km,
       min(jahr)                                                             AS jahr_von,
       max(jahr)                                                             AS jahr_bis
FROM core.realworld
WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
GROUP BY land, antriebsklasse;

CREATE INDEX ix_a4g ON mart.a4_luecke_gepoolt (land, antriebsklasse);
COMMENT ON TABLE mart.a4_luecke_gepoolt IS 'A4 — Realverbrauchsluecke je Land und Antriebsklasse, Median ueber ALLE Zulassungsjahrgaenge gemeinsam. Massgeblich fuer Bericht, Praesentation und Anwendung. mart.a4_luecke ist die Aufschluesselung nach Jahrgang und liefert bei nachtraeglicher Mittelung abweichende Werte.';

ANALYZE mart.a4_luecke_gepoolt;

\echo ''
\echo '=== Kontrolle: stimmt die gepoolte Tabelle mit A4a2 ueberein? ============='
SELECT antriebsklasse, fahrzeuge, real_l, wltp_l, gap_median_pct, gap_p90_pct
FROM mart.a4_luecke_gepoolt
WHERE land = 'DE'
ORDER BY fahrzeuge DESC;

\echo ''
\echo '=== A4b · Die Luecke im Zeitverlauf (Zulassungsjahrgang) =================='
SELECT jahr, antriebsklasse, sum(fahrzeuge) AS n,
       round(avg(median_gap_pct), 1) AS gap_median_pct
FROM mart.a4_luecke
WHERE land = 'DE' AND antriebsklasse IN ('PHEV', 'ICE_BENZIN', 'ICE_DIESEL', 'HEV')
GROUP BY jahr, antriebsklasse ORDER BY antriebsklasse, jahr;

\echo ''
\echo '=== A4c · Der Utility Factor in der Praxis (nur PHEV) ====================='
\echo '>>> WLTP unterstellt rund 84 % elektrische Fahrleistung.'
\echo '>>> median_e_anteil_pct zeigt, was tatsaechlich elektrisch gefahren wurde.'
SELECT land, jahr, sum(fahrzeuge) AS phev,
       round(avg(median_e_anteil_pct), 1) AS e_anteil_gefahren_pct,
       round(avg(median_netzstrom_kwh), 0) AS netzstrom_kwh,
       round(avg(median_gap_pct), 1) AS gap_pct
FROM mart.a4_luecke WHERE antriebsklasse = 'PHEV'
GROUP BY land, jahr ORDER BY land, jahr;

-- =============================================================================
-- A5 · Rangfolgen-Umkehr
--
-- Konstruktion: RANK() OVER auf dem offiziellen und auf dem realen Wert,
-- danach die Rangdifferenz. Zeigt, welche Modelle auf dem Papier gut und auf
-- der Strasse schlecht dastehen — und umgekehrt.
--
-- Auf Klassenebene bleibt die Umkehr aus (siehe 06_Ergebnis...md). Die Frage
-- ist, ob sie auf Modellebene auftritt: Ein sparsamer Benziner kann sehr wohl
-- real unter einem schweren PHEV liegen.
-- =============================================================================
DROP TABLE IF EXISTS mart.a5_rangumkehr;
CREATE TABLE mart.a5_rangumkehr AS
WITH modelle AS (
    SELECT marke_norm, handelsname_norm,
           min(marke)                                                        AS marke,
           min(handelsname)                                                  AS modell,
           min(antriebsklasse)                                               AS antriebsklasse,
           count(*)                                                          AS fahrzeuge,
           -- ::numeric ist zwingend. percentile_cont nimmt double precision und
           -- gibt double precision zurueck - auch wenn die Eingabespalte numeric
           -- ist. round(double precision, integer) gibt es in PostgreSQL nicht,
           -- nur round(numeric, integer). Ohne den Cast bricht das CREATE TABLE
           -- mit "Funktion round(double precision, integer) existiert nicht" ab.
           -- In A4 oben stehen die Casts deshalb ebenfalls.
           percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_wltp)::numeric       AS wltp_l,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_real)::numeric       AS real_l,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric       AS gap_pct,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY masse_kg)::numeric      AS masse_kg
    FROM core.realworld
    WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL AND land = 'DE'
    GROUP BY marke_norm, handelsname_norm
    HAVING count(*) >= 500          -- Modelle mit zu duenner Basis wuerden nur rauschen
)
SELECT marke, modell, antriebsklasse, fahrzeuge,
       round(wltp_l, 2)  AS wltp_l,
       round(real_l, 2)  AS real_l,
       round(gap_pct, 1) AS gap_pct,
       round(masse_kg, 0) AS masse_kg,
       rank() OVER (ORDER BY wltp_l)              AS rang_papier,
       rank() OVER (ORDER BY real_l)              AS rang_strasse,
       rank() OVER (ORDER BY real_l)
       - rank() OVER (ORDER BY wltp_l)            AS rang_differenz
FROM modelle;

COMMENT ON TABLE mart.a5_rangumkehr IS 'A5 — Rangfolge nach offiziellem und realem Verbrauch je Modell, Deutschland, mindestens 500 Fahrzeuge. Grundlage fuer H2.';

\echo ''
\echo '=== A5 · Groesste Absteiger: auf dem Papier gut, auf der Strasse schlecht =='
SELECT marke, modell, antriebsklasse, fahrzeuge, wltp_l, real_l, gap_pct,
       rang_papier, rang_strasse, rang_differenz
FROM mart.a5_rangumkehr ORDER BY rang_differenz DESC LIMIT 25;

\echo ''
\echo '=== A5b · Groesste Aufsteiger: auf dem Papier schlecht, real gut ==========='
SELECT marke, modell, antriebsklasse, fahrzeuge, wltp_l, real_l, gap_pct,
       rang_papier, rang_strasse, rang_differenz
FROM mart.a5_rangumkehr ORDER BY rang_differenz ASC LIMIT 25;

\echo ''
\echo '=== A5c · KERNFRAGE H2: schlagen reale Verbrenner reale PHEV? ============='
\echo '>>> Zaehlt Modellpaare, bei denen ein reiner Verbrenner real sparsamer ist'
\echo '>>> als ein PHEV - obwohl er auf dem Papier schlechter dasteht.'
WITH phev AS (
    SELECT marke, modell, wltp_l, real_l FROM mart.a5_rangumkehr WHERE antriebsklasse = 'PHEV'
), ice AS (
    SELECT marke, modell, wltp_l, real_l FROM mart.a5_rangumkehr
    WHERE antriebsklasse IN ('ICE_BENZIN', 'ICE_DIESEL')
)
SELECT count(*)                                                        AS modellpaare,
       count(*) FILTER (WHERE i.real_l < p.real_l)                     AS verbrenner_real_besser,
       round(100.0 * count(*) FILTER (WHERE i.real_l < p.real_l) / nullif(count(*), 0), 1) AS anteil_prozent
FROM ice i CROSS JOIN phev p
WHERE i.wltp_l > p.wltp_l;   -- auf dem Papier war der PHEV besser

\echo ''
\echo '=== A5d · Konkrete Umkehrungen, die stattfinden ==========================='
WITH phev AS (
    SELECT marke, modell, wltp_l, real_l, masse_kg FROM mart.a5_rangumkehr WHERE antriebsklasse = 'PHEV'
), ice AS (
    SELECT marke, modell, antriebsklasse, wltp_l, real_l, masse_kg FROM mart.a5_rangumkehr
    WHERE antriebsklasse IN ('ICE_BENZIN', 'ICE_DIESEL')
)
SELECT i.marke || ' ' || i.modell   AS verbrenner,
       i.antriebsklasse,
       i.wltp_l AS v_papier, i.real_l AS v_strasse,
       p.marke || ' ' || p.modell   AS phev,
       p.wltp_l AS p_papier, p.real_l AS p_strasse,
       round(i.real_l - p.real_l, 2) AS differenz_real_l
FROM ice i CROSS JOIN phev p
WHERE i.wltp_l > p.wltp_l AND i.real_l < p.real_l
ORDER BY (p.real_l - i.real_l) DESC
LIMIT 25;

ANALYZE mart.a4_luecke;
ANALYZE mart.a5_rangumkehr;

\echo ''
\echo '=== Gegenprobe gegen die EEA-Aggregatdatei ==============================='
\echo '>>> Eigene Rechnung gegen die von der EEA veroeffentlichten Werte.'
\echo '>>> Grosse Abweichungen sind ein Fehlersignal, kein Ergebnis.'
SELECT a.jahr, a.kraftstoff,
       sum(core.zu_zahl(a.n_fahrzeuge))                                        AS eea_fahrzeuge,
       round(avg(core.zu_zahl(a.gap_fc_pct)), 1)                               AS eea_gap_pct,
       round(avg(core.zu_zahl(a.obfcm_fc)), 2)                                 AS eea_real_l,
       round(avg(core.zu_zahl(a.wltp_fc)), 2)                                  AS eea_wltp_l
FROM raw.obfcm_cars_agg a
WHERE core.zu_zahl(a.n_fahrzeuge) >= 1000
GROUP BY a.jahr, a.kraftstoff
ORDER BY a.jahr, a.kraftstoff;
