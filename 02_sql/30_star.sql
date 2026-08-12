-- =============================================================================
-- 30_star.sql   ·   Tag 2   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\30_star.sql -OutFile .\00_doku\star_ausgabe.txt
--
-- Sternschema. Fünf Dimensionen, eine Faktentabelle, partitioniert nach Jahr.
-- Reihenfolge ist bewusst: Dimensionen füllen -> Fakten füllen -> ERST DANACH
-- Indizes (32_indizes_explain.sql). Indizes vor dem Laden kosten ein Vielfaches.
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

DROP TABLE IF EXISTS star.fact_registration CASCADE;
DROP TABLE IF EXISTS star.dim_country      CASCADE;
DROP TABLE IF EXISTS star.dim_manufacturer CASCADE;
DROP TABLE IF EXISTS star.dim_model        CASCADE;
DROP TABLE IF EXISTS star.dim_powertrain   CASCADE;
DROP TABLE IF EXISTS star.dim_date         CASCADE;

-- =============================================================================
-- Dimensionen
-- =============================================================================

-- --- Land --------------------------------------------------------------------
CREATE TABLE star.dim_country (
    country_sk    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ms_code       char(2) NOT NULL UNIQUE,
    land_name     text    NOT NULL,
    region        text,
    ist_fokusland boolean NOT NULL DEFAULT false
);
COMMENT ON COLUMN star.dim_country.ist_fokusland IS 'DE, FR, IT, ES, NL, NO — der geladene Umfang. Siehe PROJEKT_Kontext.md §1.';

INSERT INTO star.dim_country (ms_code, land_name, region, ist_fokusland) VALUES
    ('DE','Deutschland','West',  true),  ('FR','Frankreich','West', true),
    ('IT','Italien',    'Sued',  true),  ('ES','Spanien',   'Sued', true),
    ('NL','Niederlande','West',  true),  ('NO','Norwegen',  'Nord', true),
    ('AT','Oesterreich','West',  false), ('BE','Belgien',   'West', false),
    ('BG','Bulgarien',  'Ost',   false), ('CY','Zypern',    'Sued', false),
    ('CZ','Tschechien', 'Ost',   false), ('DK','Daenemark', 'Nord', false),
    ('EE','Estland',    'Nord',  false), ('FI','Finnland',  'Nord', false),
    ('GR','Griechenland','Sued', false), ('HR','Kroatien',  'Sued', false),
    ('HU','Ungarn',     'Ost',   false), ('IE','Irland',    'West', false),
    ('IS','Island',     'Nord',  false), ('LT','Litauen',   'Nord', false),
    ('LU','Luxemburg',  'West',  false), ('LV','Lettland',  'Nord', false),
    ('MT','Malta',      'Sued',  false), ('PL','Polen',     'Ost',  false),
    ('PT','Portugal',   'Sued',  false), ('RO','Rumaenien', 'Ost',  false),
    ('SE','Schweden',   'Nord',  false), ('SI','Slowenien', 'Ost',  false),
    ('SK','Slowakei',   'Ost',   false);

-- --- Hersteller ---------------------------------------------------------------
-- Drei Ebenen. Für H5 (Flottenziele, Pooling) rechnet die EU nach VO 2019/631
-- auf Pool-Ebene ab.
--
-- WICHTIGER BEFUND (Stichprobe 10.08.2026, Jahrgang 2025):
-- `Mp` ist NICHT durchgängig gefüllt. COUNT(Mp) meldet zwar 100 % — aber
-- 6.677.964 Sätze (61,64 %) enthalten einen LEERSTRING. Nur Hersteller, die
-- tatsächlich in einem Pool sind, tragen dort einen Wert:
--     TESLA                                          1.711.929  (15,80 %)
--     MERCEDES-BENZ, VOLVO CARS, POLESTAR AND SMART    861.580  ( 7,95 %)
--     BMW                                              761.099  ( 7,03 %)
--     HYUNDAI MOTOR EUROPE                             425.493  ( 3,93 %)
--     NISSAN-BYD                                       328.460  ( 3,03 %)
--     KG MOBILITY XPENG                                 40.899  ( 0,38 %)
--     MAZDA                                             26.173  ( 0,24 %)
--
-- Für H5 heißt das: Die Abrechnungseinheit ist der Pool, WENN es einen gibt,
-- sonst der Hersteller selbst. Genau das leistet `hersteller_gruppe`.
-- `ist_gepoolt` macht die Pooling-Frage direkt auswertbar — das ist der Kern
-- von H5 ("Ziele nur über Pooling erreicht?").
-- `schluessel` ist der eigentliche Join-Schlüssel: eine einzige Textspalte aus
-- den drei Namensfeldern, NULL zu Leerstring normalisiert.
--
-- WARUM: Der erste Entwurf verband die Faktentabelle über
-- `IS NOT DISTINCT FROM` auf drei Textspalten, damit NULL-Werte matchen.
-- Dieser Operator ist NICHT hashbar — PostgreSQL kann keinen Hash Join bauen
-- und fällt auf verschachtelte Schleifen zurück. Gemessen: 15 MB pro Minute,
-- hochgerechnet über sechs Stunden für 37 Mio. Zeilen. Mit einem einzigen
-- gleichheitsfähigen Textschlüssel wird daraus ein Hash Join gegen eine
-- Dimension mit 413 Zeilen.
CREATE TABLE star.dim_manufacturer (
    manufacturer_sk   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schluessel        text    NOT NULL UNIQUE,
    mp_pool           text,
    mh_name           text,
    man_name          text,
    hersteller_gruppe text    NOT NULL,   -- Abrechnungseinheit: Pool oder Hersteller
    ist_gepoolt       boolean NOT NULL
);
COMMENT ON COLUMN star.dim_manufacturer.hersteller_gruppe IS 'coalesce(mp_pool, mh_name, man_name) — die Ebene, auf der das Flottenziel gilt.';
COMMENT ON COLUMN star.dim_manufacturer.ist_gepoolt IS 'true, wenn der Hersteller einem gemeldeten Pool angehört. Direkter Test für H5.';

INSERT INTO star.dim_manufacturer (schluessel, mp_pool, mh_name, man_name, hersteller_gruppe, ist_gepoolt)
SELECT DISTINCT
    coalesce(mp_pool, '') || '|' || coalesce(mh_name, '') || '|' || coalesce(man_name, ''),
    mp_pool, mh_name, man_name,
    coalesce(mp_pool, mh_name, man_name, '(unbekannt)'),
    mp_pool IS NOT NULL
FROM core.registration;

-- --- Modell -------------------------------------------------------------------
-- Original und normalisierte Form nebeneinander: gruppiert wird über die
-- normalisierte Spalte ('I20', 'i 20', 'I-20' -> 'I20'), angezeigt wird das Original.
CREATE TABLE star.dim_model (
    model_sk         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schluessel       text NOT NULL UNIQUE,   -- siehe Begruendung bei dim_manufacturer
    marke            text,
    handelsname      text,
    marke_norm       text,
    handelsname_norm text
);

INSERT INTO star.dim_model (schluessel, marke, handelsname, marke_norm, handelsname_norm)
SELECT DISTINCT
    coalesce(marke, '') || '|' || coalesce(handelsname, ''),
    marke, handelsname, marke_norm, handelsname_norm
FROM core.registration;

-- --- Antrieb ------------------------------------------------------------------
-- Die zentrale Dimension der Arbeit. Aufgebaut über Ft x Fm, nicht über Ft allein.
-- Begründung: 00_doku/05_Datenlandkarte.md §2.4 — 34 % der Flotte sind Hybride
-- ohne Stecker, die unter Ft='petrol' unsichtbar wären.
CREATE TABLE star.dim_powertrain (
    powertrain_sk      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schluessel         text    NOT NULL UNIQUE,   -- siehe dim_manufacturer
    ft                 text,
    fm                 char(1),
    antriebsklasse     text    NOT NULL,
    antrieb_label      text    NOT NULL,
    ist_elektrifiziert boolean NOT NULL,
    ist_extern_ladbar  boolean NOT NULL
);

INSERT INTO star.dim_powertrain (schluessel, ft, fm, antriebsklasse, antrieb_label, ist_elektrifiziert, ist_extern_ladbar)
SELECT DISTINCT
    coalesce(ft, '') || '|' || coalesce(fm, ''),
    ft, fm, antriebsklasse,
    CASE antriebsklasse
        WHEN 'BEV'          THEN 'Batterieelektrisch'
        WHEN 'PHEV'         THEN 'Plug-in-Hybrid'
        WHEN 'HEV'          THEN 'Hybrid ohne Stecker'
        WHEN 'FCEV'         THEN 'Brennstoffzelle'
        WHEN 'ICE_DIESEL'   THEN 'Diesel (rein)'
        WHEN 'ICE_BENZIN'   THEN 'Benzin (rein)'
        WHEN 'ICE_SONSTIGE' THEN 'Verbrenner sonstige'
        WHEN 'BIFUEL'       THEN 'Bi-Fuel (LPG/Erdgas)'
        WHEN 'FLEX'         THEN 'Flex-Fuel (E85)'
        ELSE 'Unbekannt'
    END,
    ist_elektrifiziert, ist_extern_ladbar
FROM core.registration;

-- --- Zeit ---------------------------------------------------------------------
-- date_sk als YYYYMMDD: lesbar, sortierbar, und im EXPLAIN sofort erkennbar.
-- Zeile 0 fängt Sätze ohne Zulassungsdatum ab, damit der Join kein INNER-Join
-- sein muss und keine Zeile stillschweigend verloren geht.
CREATE TABLE star.dim_date (
    date_sk   integer PRIMARY KEY,
    datum     date,
    jahr      smallint,
    quartal   smallint,
    monat     smallint,
    monat_name text,
    kw        smallint,
    wochentag smallint
);

INSERT INTO star.dim_date VALUES (0, NULL, NULL, NULL, NULL, 'unbekannt', NULL, NULL);

INSERT INTO star.dim_date
SELECT to_char(d, 'YYYYMMDD')::int,
       d::date,
       extract(year    FROM d)::smallint,
       extract(quarter FROM d)::smallint,
       extract(month   FROM d)::smallint,
       to_char(d, 'TMMonth'),
       extract(week    FROM d)::smallint,
       extract(isodow  FROM d)::smallint
FROM generate_series(DATE '2010-01-01', DATE '2026-12-31', INTERVAL '1 day') AS d;

-- =============================================================================
-- Faktentabelle
--
-- PARTITION BY RANGE (jahr): Bei 37 Mio. Zeilen entscheidet Partition Pruning
-- darüber, ob eine Jahresabfrage 4 Sekunden oder 4 Minuten läuft. Der Beweis
-- steht in 32_indizes_explain.sql als EXPLAIN ANALYZE vorher/nachher.
--
-- Der Partitionsschlüssel muss Teil des Primärschlüssels sein — deshalb (jahr, reg_sk).
-- =============================================================================
-- Weder Primärschlüssel noch Fremdschlüssel im CREATE.
--
-- WARUM: Beides wird bei JEDER eingefügten Zeile geprüft — der PK pflegt
-- einen Index mit, jeder FK schlägt in der Zieldimension nach. Bei 37 Mio.
-- Zeilen sind das fünf Nachschlagevorgänge und ein Indexeintrag pro Zeile.
-- Beides wird NACH dem Laden in einem Rutsch angelegt, wo PostgreSQL
-- sortieren und den Index am Stück bauen kann. Das ist dieselbe Logik wie
-- "Indizes erst nach dem COPY" beim Staging-Load.
CREATE TABLE star.fact_registration (
    reg_sk           bigint GENERATED ALWAYS AS IDENTITY,
    jahr             smallint NOT NULL,
    date_sk          integer  NOT NULL,
    country_sk       smallint NOT NULL,
    manufacturer_sk  integer  NOT NULL,
    model_sk         integer  NOT NULL,
    powertrain_sk    smallint NOT NULL,
    -- Kennzahlen
    masse_kg         numeric(7,1),
    pruefmasse_kg    numeric(7,1),
    co2_wltp         numeric(6,1),
    co2_nedc         numeric(6,1),
    hubraum_cm3      integer,
    leistung_kw      numeric(6,1),
    strom_wh_km      numeric(7,2),
    verbrauch_l      numeric(6,2),
    oeko_gutschrift  numeric(5,2),
    oeko_codes       text[],
    -- Herkunft
    src_id           bigint,
    tan              text,
    data_status      char(1),
    source_version   text
) PARTITION BY RANGE (jahr);

CREATE TABLE star.fact_registration_2021 PARTITION OF star.fact_registration FOR VALUES FROM (2021) TO (2022);
CREATE TABLE star.fact_registration_2022 PARTITION OF star.fact_registration FOR VALUES FROM (2022) TO (2023);
CREATE TABLE star.fact_registration_2023 PARTITION OF star.fact_registration FOR VALUES FROM (2023) TO (2024);
CREATE TABLE star.fact_registration_2024 PARTITION OF star.fact_registration FOR VALUES FROM (2024) TO (2025);
CREATE TABLE star.fact_registration_2025 PARTITION OF star.fact_registration FOR VALUES FROM (2025) TO (2026);
CREATE TABLE star.fact_registration_rest PARTITION OF star.fact_registration DEFAULT;

COMMENT ON TABLE star.fact_registration IS 'Eine Zeile je Neuzulassung. Körnigkeit: Fahrzeug. 37,1 Mio. Zeilen, DE/FR/IT/ES/NL/NO, 2021–2025.';

-- --- Befüllen -----------------------------------------------------------------
INSERT INTO star.fact_registration (
    jahr, date_sk, country_sk, manufacturer_sk, model_sk, powertrain_sk,
    masse_kg, pruefmasse_kg, co2_wltp, co2_nedc, hubraum_cm3, leistung_kw,
    strom_wh_km, verbrauch_l, oeko_gutschrift, oeko_codes,
    src_id, tan, data_status, source_version
)
SELECT
    c.jahr,
    coalesce(to_char(c.zulassung_datum, 'YYYYMMDD')::int, 0),
    dc.country_sk,
    dm.manufacturer_sk,
    dmo.model_sk,
    dp.powertrain_sk,
    c.masse_kg, c.pruefmasse_kg, c.co2_wltp, c.co2_nedc,
    c.hubraum_cm3, c.leistung_kw, c.strom_wh_km, c.verbrauch_l,
    c.oeko_gutschrift, c.oeko_codes,
    c.src_id, c.tan, c.data_status, c.source_version
FROM core.registration c
-- Alle Verknüpfungen über einfache Gleichheit auf einer Textspalte, damit
-- PostgreSQL Hash Joins gegen die kleinen Dimensionen bauen kann.
JOIN star.dim_country      dc  ON dc.ms_code = c.ms
JOIN star.dim_manufacturer dm  ON dm.schluessel =
        coalesce(c.mp_pool, '') || '|' || coalesce(c.mh_name, '') || '|' || coalesce(c.man_name, '')
JOIN star.dim_model        dmo ON dmo.schluessel =
        coalesce(c.marke, '') || '|' || coalesce(c.handelsname, '')
JOIN star.dim_powertrain   dp  ON dp.schluessel =
        coalesce(c.ft, '') || '|' || coalesce(c.fm, '');

-- =============================================================================
-- Schlüssel und Indizes ERST JETZT — nach dem Laden, in einem Rutsch
-- =============================================================================
\echo ''
\echo '--- Primaerschluessel anlegen (nach dem Laden) ----------------------------'
ALTER TABLE star.fact_registration ADD PRIMARY KEY (jahr, reg_sk);

\echo '--- Fremdschluessel anlegen ----------------------------------------------'
ALTER TABLE star.fact_registration
    ADD CONSTRAINT fk_fact_date         FOREIGN KEY (date_sk)         REFERENCES star.dim_date(date_sk),
    ADD CONSTRAINT fk_fact_country      FOREIGN KEY (country_sk)      REFERENCES star.dim_country(country_sk),
    ADD CONSTRAINT fk_fact_manufacturer FOREIGN KEY (manufacturer_sk) REFERENCES star.dim_manufacturer(manufacturer_sk),
    ADD CONSTRAINT fk_fact_model        FOREIGN KEY (model_sk)        REFERENCES star.dim_model(model_sk),
    ADD CONSTRAINT fk_fact_powertrain   FOREIGN KEY (powertrain_sk)   REFERENCES star.dim_powertrain(powertrain_sk);

-- =============================================================================
-- Kontrolle: geht beim Übergang core -> star eine Zeile verloren?
-- =============================================================================
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'star', 'fact_registration', NULL,
       'Zeilendifferenz core -> star',
       (SELECT count(*) FROM core.registration) - (SELECT count(*) FROM star.fact_registration),
       'Zeilen', 0,
       CASE WHEN (SELECT count(*) FROM core.registration) = (SELECT count(*) FROM star.fact_registration)
            THEN 'ok' ELSE 'kritisch' END,
       'Ein Verlust hier bedeutet einen fehlgeschlagenen Dimensions-Join (NULL-Behandlung prüfen).';

\echo ''
\echo '--- Größe der Dimensionen -------------------------------------------------'
SELECT 'dim_country'      AS dimension, count(*) AS zeilen FROM star.dim_country
UNION ALL SELECT 'dim_manufacturer', count(*) FROM star.dim_manufacturer
UNION ALL SELECT 'dim_model',        count(*) FROM star.dim_model
UNION ALL SELECT 'dim_powertrain',   count(*) FROM star.dim_powertrain
UNION ALL SELECT 'dim_date',         count(*) FROM star.dim_date
ORDER BY zeilen DESC;

\echo ''
\echo '--- Faktentabelle je Partition --------------------------------------------'
SELECT c.relname                                  AS partition,
       to_char(c.reltuples::bigint, 'FM999G999G999') AS zeilen_geschaetzt,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS groesse
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'star' AND c.relname LIKE 'fact_registration%'
ORDER BY c.relname;

\echo ''
\echo '--- Zeilenkontrolle core gegen star ---------------------------------------'
SELECT (SELECT count(*) FROM core.registration)     AS core_zeilen,
       (SELECT count(*) FROM star.fact_registration) AS star_zeilen,
       (SELECT count(*) FROM core.registration)
       - (SELECT count(*) FROM star.fact_registration) AS differenz;

\echo ''
\echo '--- Pooling je Jahr (H5) --------------------------------------------------'
SELECT f.jahr,
       count(*) FILTER (WHERE m.ist_gepoolt)     AS in_pool,
       count(*) FILTER (WHERE NOT m.ist_gepoolt) AS einzeln,
       round(100.0 * count(*) FILTER (WHERE m.ist_gepoolt) / count(*), 2) AS prozent_gepoolt
FROM star.fact_registration f
JOIN star.dim_manufacturer m ON m.manufacturer_sk = f.manufacturer_sk
GROUP BY f.jahr ORDER BY f.jahr;

\echo ''
\echo '--- Größte Abrechnungseinheiten 2025 --------------------------------------'
SELECT m.hersteller_gruppe, m.ist_gepoolt,
       count(*) AS zulassungen,
       round(avg(f.co2_wltp), 1) AS avg_co2_wltp,
       round(avg(f.masse_kg), 0) AS avg_masse_kg,
       round(avg(f.oeko_gutschrift) FILTER (WHERE f.oeko_gutschrift IS NOT NULL), 2) AS avg_oeko_gutschrift
FROM star.fact_registration f
JOIN star.dim_manufacturer m ON m.manufacturer_sk = f.manufacturer_sk
WHERE f.jahr = 2025
GROUP BY m.hersteller_gruppe, m.ist_gepoolt
ORDER BY zulassungen DESC
LIMIT 25;

\echo ''
\echo '--- Antriebsmix je Jahr (erste fachliche Kontrolle) ------------------------'
SELECT f.jahr, p.antrieb_label,
       count(*) AS zulassungen,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY f.jahr), 2) AS prozent,
       round(avg(f.co2_wltp), 1) AS avg_co2_wltp,
       round(avg(f.masse_kg), 0) AS avg_masse_kg
FROM star.fact_registration f
JOIN star.dim_powertrain p ON p.powertrain_sk = f.powertrain_sk
GROUP BY f.jahr, p.antrieb_label
ORDER BY f.jahr, zulassungen DESC;
