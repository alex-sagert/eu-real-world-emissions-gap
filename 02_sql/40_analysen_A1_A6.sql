-- =============================================================================
-- 40_analysen_A1_A6.sql   ·   Tag 3   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\40_analysen_A1_A6.sql -OutFile .\00_doku\analysen_ausgabe.txt
--
-- Sechs Auswertungen. Jede legt ihr Ergebnis zusätzlich als mart_-Tabelle ab,
-- damit die Streamlit-App nicht bei jedem Klick 37 Mio. Zeilen aggregiert.
--
--   A1  Antriebsmix je Land und Jahr, mit Veränderung zum Vorjahr   -> H3
--   A2  Deutschland gegen EU-Durchschnitt, in Prozentpunkten        -> H3
--   A3  Massengewichtetes Flottenmittel gegen Zielwert              -> H5
--   A4  Realverbrauchslücke je Fahrzeug (Median und P90)            -> H1
--   A5  Rangfolgen-Umkehr offiziell gegen real                      -> H2
--   A6  Gewichtsspirale mit rollierendem Mittel                     -> H4
--
-- A4 und A5 brauchen die OBFCM-Daten in core.realworld. Solange die nicht
-- geladen sind, überspringen sich beide selbst mit einem Hinweis, statt
-- abzubrechen.
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
-- A1 · Antriebsmix je Land und Jahr, mit Veränderungsrate
--
-- Konstruktion: SUM() OVER (PARTITION BY land, jahr) für den Anteil ohne
-- Selbst-Join, LAG() OVER (PARTITION BY land, antrieb ORDER BY jahr) für die
-- Veränderung zum Vorjahr. Beides in einem Durchlauf.
-- =============================================================================
DROP TABLE IF EXISTS mart.a1_antriebsmix;
CREATE TABLE mart.a1_antriebsmix AS
WITH basis AS (
    SELECT c.ms_code,
           c.land_name,
           f.jahr,
           p.antriebsklasse,
           p.antrieb_label,
           count(*)                   AS zulassungen,
           avg(f.co2_wltp)            AS avg_co2_wltp,
           avg(f.masse_kg)            AS avg_masse_kg,
           max(f.data_status)         AS data_status
    FROM star.fact_registration f
    JOIN star.dim_country    c ON c.country_sk    = f.country_sk
    JOIN star.dim_powertrain p ON p.powertrain_sk = f.powertrain_sk
    GROUP BY c.ms_code, c.land_name, f.jahr, p.antriebsklasse, p.antrieb_label
),
-- Zweite Stufe zwingend getrennt: PostgreSQL erlaubt keine verschachtelten
-- Window-Funktionen. Der Anteil (SUM OVER) muss fertig berechnet sein, bevor
-- LAG darauf zugreifen darf.
anteile AS (
    SELECT ms_code, land_name, jahr, antriebsklasse, antrieb_label, zulassungen,
           sum(zulassungen) OVER (PARTITION BY ms_code, jahr)             AS zulassungen_land_jahr,
           round(100.0 * zulassungen
                 / sum(zulassungen) OVER (PARTITION BY ms_code, jahr), 3) AS anteil_prozent,
           avg_co2_wltp, avg_masse_kg, data_status
    FROM basis
)
SELECT ms_code, land_name, jahr, antriebsklasse, antrieb_label,
       zulassungen, zulassungen_land_jahr, anteil_prozent,
       lag(zulassungen)     OVER w                       AS zulassungen_vorjahr,
       round(anteil_prozent - lag(anteil_prozent) OVER w, 3) AS delta_prozentpunkte,
       round(avg_co2_wltp, 1) AS avg_co2_wltp,
       round(avg_masse_kg, 0) AS avg_masse_kg,
       data_status
FROM anteile
WINDOW w AS (PARTITION BY ms_code, antriebsklasse ORDER BY jahr);

CREATE INDEX ix_a1 ON mart.a1_antriebsmix (ms_code, jahr, antriebsklasse);
COMMENT ON TABLE mart.a1_antriebsmix IS 'A1 — Antriebsmix je Land und Jahr mit Anteil und Veränderung zum Vorjahr. Grundlage für H3.';

\echo ''
\echo '=== A1 · Elektrifizierung Deutschland gegen Norwegen ======================'
SELECT jahr, ms_code, antrieb_label,
       zulassungen, anteil_prozent, delta_prozentpunkte
FROM mart.a1_antriebsmix
WHERE ms_code IN ('DE', 'NO') AND antriebsklasse IN ('BEV', 'PHEV', 'ICE_BENZIN', 'ICE_DIESEL')
ORDER BY antriebsklasse, ms_code, jahr;

-- =============================================================================
-- A2 · Deutschland gegen EU-Durchschnitt, in Prozentpunkten
--
-- Konstruktion: CTE bildet die Referenz über alle geladenen Länder, ein
-- zweiter CTE die deutsche Zeile, danach Differenz. Bewusst ohne Self-Join
-- auf die Faktentabelle — die Referenz wird genau einmal berechnet.
--
-- Wichtig für die Interpretation: Der "EU-Durchschnitt" ist hier der
-- Durchschnitt der SECHS geladenen Länder (rund 72 % der EU-Neuzulassungen),
-- nicht der EU-27. Das steht so im NvS.
-- =============================================================================
DROP TABLE IF EXISTS mart.a2_de_vs_eu;
CREATE TABLE mart.a2_de_vs_eu AS
WITH referenz AS (
    SELECT jahr, antriebsklasse,
           sum(zulassungen)                                                    AS zul_ref,
           round(100.0 * sum(zulassungen)
                 / sum(sum(zulassungen)) OVER (PARTITION BY jahr), 3)          AS anteil_ref,
           round(sum(zulassungen * avg_co2_wltp) / nullif(sum(zulassungen), 0), 1) AS co2_ref
    FROM mart.a1_antriebsmix
    GROUP BY jahr, antriebsklasse
),
deutschland AS (
    SELECT jahr, antriebsklasse, zulassungen AS zul_de, anteil_prozent AS anteil_de, avg_co2_wltp AS co2_de
    FROM mart.a1_antriebsmix
    WHERE ms_code = 'DE'
)
SELECT r.jahr, r.antriebsklasse,
       d.zul_de, d.anteil_de,
       r.zul_ref, r.anteil_ref,
       round(d.anteil_de - r.anteil_ref, 3) AS delta_prozentpunkte,
       d.co2_de, r.co2_ref,
       round(d.co2_de - r.co2_ref, 1)       AS delta_co2_g_km
FROM referenz r
LEFT JOIN deutschland d ON d.jahr = r.jahr AND d.antriebsklasse = r.antriebsklasse;

COMMENT ON TABLE mart.a2_de_vs_eu IS 'A2 — Deutschland gegen den Durchschnitt der sechs Fokusländer. Referenz ist NICHT EU-27.';

\echo ''
\echo '=== A2 · Deutschland gegen Vergleichsgruppe (Prozentpunkte) ==============='
SELECT jahr, antriebsklasse, anteil_de, anteil_ref, delta_prozentpunkte, delta_co2_g_km
FROM mart.a2_de_vs_eu
WHERE antriebsklasse IN ('BEV', 'PHEV', 'HEV', 'ICE_BENZIN', 'ICE_DIESEL')
ORDER BY antriebsklasse, jahr;

-- =============================================================================
-- A3 · Massengewichtetes Flottenmittel je Abrechnungseinheit gegen Zielwert
--
-- ACHTUNG — offengelegte Näherung:
-- Die Zielwertformel der VO (EU) 2019/631 ist komplex (Phase-in, Superkredite,
-- herstellerspezifische WLTP-Referenzwerte aus dem NEDC-Übergang). Hier wird
-- die Grundform verwendet:
--
--     Ziel = Basisziel + a * (Prüfmasse - M0)
--
-- Die Parameter stehen in einer eigenen Tabelle und sind damit im NvS
-- nachvollziehbar und einzeln korrigierbar. Sie sind ausdrücklich als
-- Näherung gekennzeichnet und dürfen NICHT als amtlicher Zielwert zitiert
-- werden. Vor der Abgabe gegen den Verordnungstext prüfen.
-- =============================================================================
DROP TABLE IF EXISTS star.ziel_parameter;
CREATE TABLE star.ziel_parameter (
    jahr       smallint PRIMARY KEY,
    basis_g_km numeric(6,2) NOT NULL,
    a_faktor   numeric(8,5) NOT NULL,
    m0_kg      numeric(8,2) NOT NULL,
    geprueft   boolean      NOT NULL DEFAULT false,
    quelle     text
);
COMMENT ON TABLE star.ziel_parameter IS 'Parameter der genäherten Zielwertformel. geprueft=false bedeutet: noch nicht gegen den Verordnungstext verifiziert.';

INSERT INTO star.ziel_parameter (jahr, basis_g_km, a_faktor, m0_kg, geprueft, quelle) VALUES
    (2021, 115.00, 0.03330, 1379.88, false, 'NAEHERUNG — Phase-in-Jahr, WLTP-Aequivalent noch zu verifizieren'),
    (2022, 115.00, 0.03330, 1379.88, false, 'NAEHERUNG — vor Abgabe pruefen'),
    (2023, 115.00, 0.03330, 1379.88, false, 'NAEHERUNG — vor Abgabe pruefen'),
    (2024, 115.00, 0.03330, 1379.88, false, 'NAEHERUNG — vor Abgabe pruefen'),
    (2025,  93.60, 0.03330, 1610.00, false, 'NAEHERUNG — 15 %-Stufe ab 2025, vor Abgabe pruefen');

CREATE OR REPLACE FUNCTION star.flottenziel(p_jahr smallint, p_pruefmasse numeric)
RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT round(z.basis_g_km + z.a_faktor * (p_pruefmasse - z.m0_kg), 2)
    FROM star.ziel_parameter z WHERE z.jahr = p_jahr
$$;
COMMENT ON FUNCTION star.flottenziel(smallint, numeric) IS 'Genaeherter spezifischer CO2-Zielwert. Annahmen in star.ziel_parameter, ausdruecklich keine amtliche Groesse.';

DROP TABLE IF EXISTS mart.a3_flottenziele;
CREATE TABLE mart.a3_flottenziele AS
SELECT m.hersteller_gruppe,
       m.ist_gepoolt,
       f.jahr,
       count(*)                                                        AS zulassungen,
       -- Mengengewichtetes Flottenmittel: jede Zulassung ist eine Zeile,
       -- der Mittelwert ist damit bereits mengengewichtet.
       --
       -- ANNAHME, die vor der Abgabe zu pruefen ist: In den EEA-Daten ist
       -- `Ewltp` der gemessene Wert VOR Abzug der Oeko-Innovationsgutschrift,
       -- `Erwltp` die Gutschrift. Der Compliance-Wert ist damit Ewltp - Erwltp.
       -- Beide Groessen werden getrennt ausgewiesen, damit der Effekt der
       -- Gutschrift sichtbar bleibt — genau das ist H5.
       round(avg(f.co2_wltp), 2)                                       AS flottenmittel_vor_oeko,
       round(avg(f.co2_wltp - coalesce(f.oeko_gutschrift, 0)), 2)      AS flottenmittel_nach_oeko,
       round(avg(f.pruefmasse_kg), 1)                                  AS avg_pruefmasse,
       star.flottenziel(f.jahr, avg(f.pruefmasse_kg))                  AS flottenziel_naeherung,
       round(avg(f.co2_wltp - coalesce(f.oeko_gutschrift, 0))
             - star.flottenziel(f.jahr, avg(f.pruefmasse_kg)), 2)      AS abweichung_g_km,
       round(avg(f.co2_wltp) - star.flottenziel(f.jahr, avg(f.pruefmasse_kg)), 2) AS abweichung_ohne_oeko_g_km,
       -- Wie stark haengt die Zielerreichung an Oeko-Innovationen? (H5)
       round(avg(f.oeko_gutschrift) FILTER (WHERE f.oeko_gutschrift IS NOT NULL), 3) AS avg_oeko_gutschrift,
       count(*) FILTER (WHERE f.oeko_gutschrift IS NOT NULL)           AS mit_oeko,
       round(100.0 * count(*) FILTER (WHERE f.oeko_gutschrift IS NOT NULL) / count(*), 2) AS anteil_oeko_prozent,
       -- Anteil der elektrifizierten Fahrzeuge, die den Schnitt druecken
       round(100.0 * count(*) FILTER (WHERE p.antriebsklasse = 'BEV')  / count(*), 2) AS anteil_bev_prozent,
       round(100.0 * count(*) FILTER (WHERE p.antriebsklasse = 'PHEV') / count(*), 2) AS anteil_phev_prozent
FROM star.fact_registration f
JOIN star.dim_manufacturer m ON m.manufacturer_sk = f.manufacturer_sk
JOIN star.dim_powertrain   p ON p.powertrain_sk   = f.powertrain_sk
WHERE f.co2_wltp IS NOT NULL AND f.pruefmasse_kg IS NOT NULL
GROUP BY m.hersteller_gruppe, m.ist_gepoolt, f.jahr
HAVING count(*) >= 1000;   -- Kleinsthersteller haben eigene Regeln, hier ausgeklammert

COMMENT ON TABLE mart.a3_flottenziele IS 'A3 — Flottenmittel gegen genaeherten Zielwert je Abrechnungseinheit. Grundlage fuer H5.';

\echo ''
\echo '=== A3 · Zielerreichung 2025, groesste Abrechnungseinheiten ==============='
\echo '>>> ACHTUNG: flottenziel_naeherung ist eine dokumentierte Naeherung,'
\echo '>>> siehe star.ziel_parameter. Nicht als amtlicher Zielwert zitieren.'
SELECT hersteller_gruppe, ist_gepoolt, zulassungen,
       flottenmittel_vor_oeko, flottenmittel_nach_oeko,
       flottenziel_naeherung, abweichung_g_km, abweichung_ohne_oeko_g_km,
       anteil_bev_prozent, anteil_phev_prozent, anteil_oeko_prozent
FROM mart.a3_flottenziele
WHERE jahr = 2025
ORDER BY zulassungen DESC
LIMIT 30;

\echo ''
\echo '=== A3b · Wie viele Einheiten kippen ohne Oeko-Gutschrift? (H5) ==========='
\echo '>>> nur_dank_oeko = Ziel mit Gutschrift erreicht, ohne Gutschrift verfehlt.'
SELECT jahr,
       count(*)                                                AS einheiten,
       count(*) FILTER (WHERE abweichung_g_km <= 0)            AS ziel_erreicht,
       count(*) FILTER (WHERE abweichung_g_km >  0)            AS ziel_verfehlt,
       count(*) FILTER (WHERE abweichung_g_km <= 0
                          AND abweichung_ohne_oeko_g_km > 0)   AS nur_dank_oeko,
       count(*) FILTER (WHERE abweichung_g_km <= 0 AND ist_gepoolt) AS ziel_erreicht_im_pool
FROM mart.a3_flottenziele
GROUP BY jahr ORDER BY jahr;

-- =============================================================================
-- A6 · Gewichtsspirale mit rollierendem Mittel
--
-- Konstruktion: AVG() OVER (ORDER BY jahr ROWS BETWEEN 2 PRECEDING AND CURRENT ROW).
-- Die Zeitreihe 2010–2020 kommt aus dem an der Quelle vorverdichteten
-- Massenhistogramm, 2021–2025 aus der Faktentabelle. Beide Teile werden
-- getrennt gekennzeichnet, damit im NvS klar ist, wo die Datenbasis wechselt.
-- =============================================================================
DROP TABLE IF EXISTS mart.a6_gewichtsspirale;
CREATE TABLE mart.a6_gewichtsspirale AS
WITH hist AS (   -- 2010–2020 aus dem Histogramm, mengengewichtet
    SELECT h.jahr::smallint AS jahr,
           h.ms             AS ms_code,
           'histogramm'     AS quelle,
           sum(core.zu_zahl(h.n))                                        AS zulassungen,
           sum(core.zu_zahl(h.avg_mass)  * core.zu_zahl(h.n))
               / nullif(sum(core.zu_zahl(h.n)), 0)                       AS avg_masse_kg,
           sum(core.zu_zahl(h.avg_ewltp) * core.zu_zahl(h.n))
               / nullif(sum(core.zu_zahl(h.n)) FILTER (WHERE core.zu_zahl(h.avg_ewltp) IS NOT NULL), 0) AS avg_co2_wltp
    FROM raw.co2cars_hist_massen h
    WHERE core.zu_zahl(h.jahr) IS NOT NULL
    GROUP BY h.jahr, h.ms
),
aktuell AS (     -- 2021–2025 aus der Faktentabelle
    SELECT f.jahr, c.ms_code, 'faktentabelle' AS quelle,
           count(*)::numeric AS zulassungen,
           avg(f.masse_kg)   AS avg_masse_kg,
           avg(f.co2_wltp)   AS avg_co2_wltp
    FROM star.fact_registration f
    JOIN star.dim_country c ON c.country_sk = f.country_sk
    GROUP BY f.jahr, c.ms_code
),
alle AS (
    SELECT * FROM hist UNION ALL SELECT * FROM aktuell
)
SELECT ms_code, jahr, quelle, zulassungen,
       round(avg_masse_kg, 1) AS avg_masse_kg,
       round(avg_co2_wltp, 1) AS avg_co2_wltp,
       round(avg(avg_masse_kg) OVER (PARTITION BY ms_code ORDER BY jahr
                                     ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS masse_gleitend_3j,
       round(avg(avg_co2_wltp) OVER (PARTITION BY ms_code ORDER BY jahr
                                     ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS co2_gleitend_3j,
       round(avg_masse_kg - first_value(avg_masse_kg) OVER (PARTITION BY ms_code ORDER BY jahr), 1) AS masse_delta_zum_start,
       round(avg_co2_wltp - first_value(avg_co2_wltp) OVER (PARTITION BY ms_code ORDER BY jahr), 1) AS co2_delta_zum_start
FROM alle;

COMMENT ON TABLE mart.a6_gewichtsspirale IS 'A6 — Masse und CO2 im Zeitverlauf mit rollierendem 3-Jahres-Mittel. Datenbasis wechselt 2021 von Histogramm auf Faktentabelle (Spalte quelle).';

\echo ''
\echo '=== A6 · Gewichtsspirale Deutschland ======================================'
SELECT jahr, quelle, zulassungen, avg_masse_kg, masse_gleitend_3j, masse_delta_zum_start,
       avg_co2_wltp, co2_gleitend_3j, co2_delta_zum_start
FROM mart.a6_gewichtsspirale
WHERE ms_code = 'DE' ORDER BY jahr;

-- =============================================================================
-- A4 und A5 · brauchen OBFCM in core.realworld
-- =============================================================================
DO $$
BEGIN
    IF to_regclass('core.realworld') IS NULL THEN
        RAISE NOTICE '';
        RAISE NOTICE '### A4 und A5 uebersprungen: core.realworld existiert noch nicht.';
        RAISE NOTICE '### Zuerst 02_download_obfcm.ps1 und den OBFCM-Load ausfuehren,';
        RAISE NOTICE '### dann 41_analysen_A4_A5.sql starten.';
        RAISE NOTICE '';
    ELSE
        RAISE NOTICE 'core.realworld vorhanden — 41_analysen_A4_A5.sql kann laufen.';
    END IF;
END $$;

-- =============================================================================
-- Statistiken und Übersicht
-- =============================================================================
ANALYZE mart.a1_antriebsmix;
ANALYZE mart.a2_de_vs_eu;
ANALYZE mart.a3_flottenziele;
ANALYZE mart.a6_gewichtsspirale;

\echo ''
\echo '=== Erzeugte mart-Tabellen ==============================================='
SELECT c.relname AS tabelle, c.reltuples::bigint AS zeilen,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS groesse
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'mart' AND c.relkind = 'r'
ORDER BY c.relname;
