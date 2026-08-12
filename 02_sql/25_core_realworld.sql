-- =============================================================================
-- 25_core_realworld.sql   ·   läuft gegen bd_co2, nach dem OBFCM-Load
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\25_core_realworld.sql -OutFile .\00_doku\realworld_ausgabe.txt
--
-- Typisierung der Realverbrauchsdaten und Berechnung der Lücke je Fahrzeug.
-- Alle Filterentscheidungen stehen als Spalte in der Tabelle, damit sie in der
-- Analyse ein- und ausschaltbar sind und im Bericht begründet werden können.
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

DROP TABLE IF EXISTS core.realworld;
CREATE UNLOGGED TABLE core.realworld (
    rw_id             bigserial,
    vehicle_id        text,
    land              char(2),
    jahr              smallint,          -- Zulassungsjahr
    data_source       text,
    -- Fahrzeug
    mh                text,
    marke             text,
    handelsname       text,
    marke_norm        text,
    handelsname_norm  text,
    -- Alle Messgroessen ohne Stellenbegrenzung, siehe Begruendung weiter unten.
    masse_kg          numeric,
    pruefmasse_kg     numeric,
    hubraum_cm3       numeric,
    leistung_kw       numeric,
    -- Antrieb, identische Regel wie in core.registration
    ft                text,
    fm                char(1),
    antriebsklasse    text,
    ist_extern_ladbar boolean,
    -- Laborwerte
    co2_wltp          numeric,
    fc_wltp           numeric,           -- l/100 km
    strom_wh_km       numeric,
    e_reichweite_km   numeric,
    -- Messwerte aus dem Bordzähler
    fuel_total_l      numeric,
    dist_total_km     numeric,
    dist_cd_off_km    numeric,
    dist_cd_on_km     numeric,
    dist_ci_km        numeric,
    grid_kwh          numeric,
    -- Abgeleitet
    --
    -- BEWUSST OHNE Stellenbegrenzung. Erster Versuch mit numeric(8,3) bzw.
    -- numeric(10,2) endete mit "Feldueberlauf bei Typ numeric": In der
    -- OBFCM-Datei stehen Fahrzeuge mit einer Lebensdauerstrecke von unter
    -- 10 km. Kraftstoff / Strecke * 100 wird dort beliebig gross, und
    -- (real - wltp) / wltp * 100 ebenso, wenn der WLTP-Wert eines PHEV bei
    -- 0,9 l liegt.
    --
    -- Solche Saetze werden NICHT weggeworfen, sondern ueber hat_mindestlauf
    -- gekennzeichnet und erst in der Analyse ausgeschlossen. Ein enger Typ
    -- haette die Entscheidung "was ist plausibel" in die Tabellendefinition
    -- verlegt, wo sie niemand mehr sieht.
    fc_real           numeric,           -- l/100 km, aus Verbrauch und Strecke
    gap_abs           numeric,           -- l/100 km
    gap_pct           numeric,           -- %
    anteil_elektrisch numeric,           -- gefahrener E-Anteil beim PHEV
    -- Filterkennzeichen, NICHT vorgefiltert
    eea_verwendbar    boolean,           -- Used in calculation = 1
    hat_mindestlauf   boolean            -- Strecke >= 1000 km
);
COMMENT ON TABLE core.realworld IS 'Typisierte OBFCM-Realverbrauchsdaten mit berechneter Luecke je Fahrzeug. Filter sind als Spalten hinterlegt, nicht angewendet.';

INSERT INTO core.realworld (
    vehicle_id, land, jahr, data_source, mh, marke, handelsname, marke_norm, handelsname_norm,
    masse_kg, pruefmasse_kg, hubraum_cm3, leistung_kw,
    ft, fm, antriebsklasse, ist_extern_ladbar,
    co2_wltp, fc_wltp, strom_wh_km, e_reichweite_km,
    fuel_total_l, dist_total_km, dist_cd_off_km, dist_cd_on_km, dist_ci_km, grid_kwh,
    fc_real, gap_abs, gap_pct, anteil_elektrisch,
    eea_verwendbar, hat_mindestlauf
)
SELECT
    o.vehicle_id,
    upper(btrim(o.country)),
    -- Bereichspruefung vor dem Cast: smallint laeuft ab 32.768 ueber, und nach
    -- zwei Ueberlaeufen in dieser Datei wird hier nichts mehr riskiert.
    -- Ein Jahr ausserhalb 1900-2100 wird zu NULL und faellt in der Kontrolle auf.
    CASE WHEN core.zu_zahl(o.jahr) BETWEEN 1900 AND 2100
         THEN core.zu_zahl(o.jahr)::smallint END,
    o.data_source,
    core.leer_zu_null(o.mh),
    core.leer_zu_null(o.mk),
    core.leer_zu_null(o.cn),
    core.norm_name(o.mk),
    core.norm_name(o.cn),
    core.zu_zahl(o.m_kg),
    core.zu_zahl(o.mt),
    core.zu_zahl(o.ec_cm3),
    core.zu_zahl(o.ep_kw),
    -- WICHTIG: lower(). Die Quelle mischt 'petrol' und 'PETROL' innerhalb
    -- desselben Meldewegs (4.872.859 zu 2.918.261). Ohne Normalisierung
    -- zerfaellt jede Gruppierung in zwei Haelften.
    lower(core.leer_zu_null(o.ft)),
    upper(left(btrim(coalesce(o.fm, '')), 1)),
    core.antriebsklasse(lower(o.ft), o.fm),
    core.antriebsklasse(lower(o.ft), o.fm) IN ('BEV', 'PHEV'),
    core.zu_zahl(o.ewltp),
    core.zu_zahl(o.wltp_fc),
    core.zu_zahl(o.z_whkm),
    core.zu_zahl(o.e_range_km),
    core.zu_zahl(o.fuel_total_l),
    core.zu_zahl(o.dist_total_km),
    core.zu_zahl(o.dist_cd_off_km),
    core.zu_zahl(o.dist_cd_on_km),
    core.zu_zahl(o.dist_ci_km),
    core.zu_zahl(o.grid_energy_kwh),
    -- Realverbrauch: Lebensdauer-Kraftstoff auf Lebensdauer-Strecke
    CASE WHEN core.zu_zahl(o.dist_total_km) > 0
         THEN round(core.zu_zahl(o.fuel_total_l) / core.zu_zahl(o.dist_total_km) * 100, 3) END,
    -- absolute Luecke in l/100 km
    CASE WHEN core.zu_zahl(o.dist_total_km) > 0 AND core.zu_zahl(o.wltp_fc) > 0
         THEN round(core.zu_zahl(o.fuel_total_l) / core.zu_zahl(o.dist_total_km) * 100
                    - core.zu_zahl(o.wltp_fc), 3) END,
    -- prozentuale Luecke: unabhaengig vom CO2-Umrechnungsfaktor und deshalb
    -- die robustere Kennzahl
    CASE WHEN core.zu_zahl(o.dist_total_km) > 0 AND core.zu_zahl(o.wltp_fc) > 0
         THEN round((core.zu_zahl(o.fuel_total_l) / core.zu_zahl(o.dist_total_km) * 100
                     - core.zu_zahl(o.wltp_fc)) / core.zu_zahl(o.wltp_fc) * 100, 2) END,
    -- tatsaechlich elektrisch gefahrener Anteil (nur PHEV belegt)
    CASE WHEN core.zu_zahl(o.dist_total_km) > 0 AND core.zu_zahl(o.dist_cd_off_km) IS NOT NULL
         THEN round(core.zu_zahl(o.dist_cd_off_km) / core.zu_zahl(o.dist_total_km) * 100, 3) END,
    o.used_in_calc = '1',
    coalesce(core.zu_zahl(o.dist_total_km), 0) >= 1000
FROM raw.obfcm_cars o;

-- -----------------------------------------------------------------------------
-- Befunde protokollieren
-- -----------------------------------------------------------------------------
-- Wie extrem wird es bei Kleinstlaufleistungen wirklich? Die Zahl gehoert ins
-- Bericht als Begruendung fuer die Mindestlaufleistung und fuer den Verzicht auf
-- eine Stellenbegrenzung in der Tabellendefinition.
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar)
SELECT 'core', 'realworld', 'dist_total_km',
       'Lebensdauerstrecke ueber 1 Mio. km (unmoeglich)',
       count(*), 'Zeilen',
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'auffaellig' END,
       format('Groesster Wert %s km. Der Bordzaehler liefert offensichtlich fehlerhafte Einzelwerte; deshalb tragen alle Messspalten in core.realworld keine Stellenbegrenzung.',
              round(max(dist_total_km), 0))
FROM core.realworld WHERE dist_total_km > 1000000
UNION ALL
SELECT 'core', 'realworld', 'fc_real',
       'Realverbrauch ueber 100 l/100 km (physikalisch unmoeglich)',
       count(*), 'Zeilen',
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'auffaellig' END,
       format('Groesster Wert %s l/100 km bei %s km Lebensdauerstrecke. Entsteht rechnerisch bei Kleinstlaufleistung, deshalb Mindestlaufleistung 1000 km.',
              round(max(fc_real), 0),
              round(min(dist_total_km) FILTER (WHERE fc_real > 100), 1))
FROM core.realworld WHERE fc_real > 100
UNION ALL
SELECT 'core', 'realworld', 'gap_pct',
       'Prozentuale Luecke ueber 5000 Prozent',
       count(*), 'Zeilen',
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'auffaellig' END,
       'Entsteht bei sehr kleinem WLTP-Wert im Nenner (PHEV ab 0,9 l) und kurzer Strecke im Zaehler'
FROM core.realworld WHERE gap_pct > 5000;

INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar)
SELECT 'core', 'realworld', 'used_in_calc', 'Von der EEA als nicht verwendbar markiert',
       count(*) FILTER (WHERE NOT eea_verwendbar), 'Zeilen', 'auffaellig',
       'Plausibilitaetspruefung der EEA wird uebernommen, Anteil wird im Bericht genannt'
FROM core.realworld
UNION ALL
SELECT 'core', 'realworld', 'dist_total_km', 'Laufleistung unter 1000 km',
       count(*) FILTER (WHERE NOT hat_mindestlauf), 'Zeilen', 'auffaellig',
       'Kurzstreckenfahrzeuge verzerren die Luecke; Filter dokumentiert, zusaetzlich Median statt Mittelwert'
FROM core.realworld
UNION ALL
SELECT 'core', 'realworld', 'fc_wltp', 'Kein WLTP-Referenzwert vorhanden',
       count(*) FILTER (WHERE fc_wltp IS NULL OR fc_wltp <= 0), 'Zeilen', 'auffaellig',
       'Ohne Laborwert ist keine Luecke berechenbar; betrifft vor allem BEV'
FROM core.realworld
UNION ALL
SELECT 'core', 'realworld', 'ft', 'Uneinheitliche Schreibweise in der Quelle vor lower()',
       (SELECT count(DISTINCT ft) FROM raw.obfcm_cars) - (SELECT count(DISTINCT ft) FROM core.realworld),
       'Auspraegungen', 'auffaellig',
       'Quelle mischt petrol/PETROL im selben Meldeweg; in core normalisiert'
FROM core.realworld LIMIT 1;

CREATE INDEX ix_rw_klasse ON core.realworld (antriebsklasse, land, jahr)
    WHERE eea_verwendbar AND hat_mindestlauf;
CREATE INDEX ix_rw_modell ON core.realworld (marke_norm, handelsname_norm);
ANALYZE core.realworld;

-- =============================================================================
-- Kontrolle
-- =============================================================================
\echo ''
\echo '--- Zeilen, Filterwirkung -------------------------------------------------'
SELECT count(*)                                                              AS zeilen_gesamt,
       count(*) FILTER (WHERE eea_verwendbar)                                AS eea_verwendbar,
       count(*) FILTER (WHERE eea_verwendbar AND hat_mindestlauf)            AS plus_mindestlauf,
       count(*) FILTER (WHERE eea_verwendbar AND hat_mindestlauf
                          AND gap_pct IS NOT NULL)                           AS auswertbar
FROM core.realworld;

\echo ''
\echo '--- Meldewege und Zulassungsjahre ----------------------------------------'
SELECT data_source, jahr, count(*) AS n FROM core.realworld GROUP BY data_source, jahr ORDER BY jahr;

\echo ''
\echo '--- Top-Laender -----------------------------------------------------------'
SELECT land, count(*) AS n FROM core.realworld GROUP BY land ORDER BY n DESC LIMIT 10;

\echo ''
\echo '--- Antriebsklassen -------------------------------------------------------'
SELECT antriebsklasse, count(*) AS n,
       count(*) FILTER (WHERE gap_pct IS NOT NULL) AS mit_luecke
FROM core.realworld GROUP BY antriebsklasse ORDER BY n DESC;

\echo ''
\echo '--- Neue Befunde ----------------------------------------------------------'
SELECT objekt, spalte, pruefung, ergebnis, einheit, kommentar
FROM meta.dq_befund WHERE objekt = 'realworld' ORDER BY befund_id;
