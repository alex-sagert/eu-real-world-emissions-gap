-- =============================================================================
-- 20_core.sql   ·   Tag 2   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\20_core.sql -OutFile .\00_doku\core_ausgabe.txt
--
-- Vom Rohtext zur typisierten Schicht. Drei Dinge passieren hier, und jedes
-- davon wird gezählt und protokolliert:
--   1. Typkonvertierung, fehlertolerant (kein Abbruch bei einem kaputten Wert)
--   2. Filter Ct IN ('M1','M1G') — 691 Fremdfahrzeuge raus, Zahl dokumentiert
--   3. Ableitung der Antriebsklasse aus Ft × Fm und Tokenisierung von IT
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

-- -----------------------------------------------------------------------------
-- Hilfsfunktionen: fehlertolerante Konvertierung
-- -----------------------------------------------------------------------------

-- Warum nicht einfach ::numeric? Weil ein einziger kaputter Wert in 37 Mio.
-- Zeilen den gesamten INSERT abbrechen würde. Die Funktion liefert NULL statt
-- eines Fehlers; wie viele Werte betroffen sind, misst 15_qualitaet_raw.sql (P3).
CREATE OR REPLACE FUNCTION core.zu_zahl(t text)
RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN t IS NULL OR btrim(t) = '' THEN NULL
        WHEN replace(btrim(t), ',', '.') ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            THEN replace(btrim(t), ',', '.')::numeric
        ELSE NULL
    END
$$;
COMMENT ON FUNCTION core.zu_zahl(text) IS 'Numerische Konvertierung ohne Abbruch; akzeptiert Komma als Dezimaltrenner.';

CREATE OR REPLACE FUNCTION core.zu_datum(t text)
RETURNS date
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN t IS NULL OR btrim(t) = '' THEN NULL
        WHEN left(btrim(t), 10) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN left(btrim(t), 10)::date
        ELSE NULL
    END
$$;

-- Leerstring zu NULL. Die EEA liefert bei IT und MMS Leerstrings statt NULL.
CREATE OR REPLACE FUNCTION core.leer_zu_null(t text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT nullif(btrim(t), '')
$$;

-- Normalisierung von Marken- und Modellnamen für die Gruppierung.
-- 'i20', 'I 20', ' I20 ' werden zu 'I20'. Der Originalwert bleibt erhalten.
CREATE OR REPLACE FUNCTION core.norm_name(t text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT nullif(upper(regexp_replace(btrim(coalesce(t, '')), '[^A-Za-z0-9]+', '', 'g')), '')
$$;

-- -----------------------------------------------------------------------------
-- Öko-Innovationscodes tokenisieren
--
-- Das Feld IT ist nicht normalisiert. Beobachtet in 2025:
--   'e1 29 37'      Behörde e1 (KBA), Technologien 29 und 37
--   'e5 2937'       gleiche Technologien, ohne Trennzeichen
--   'e529  37'      Behörde und erste Technologie verschmolzen
--   'e5  e5 29'     Behörde doppelt genannt
--
-- Vorgehen, bewusst konservativ:
--   1. Auf Whitespace splitten
--   2. Tokens der Form e<Zahl> als Genehmigungsbehörde verwerfen
--   3. Aus den restlichen Ziffernfolgen 2er-Gruppen bilden (2937 -> 29, 37)
--   4. Nur Codes behalten, die in der dokumentierten Whitelist stehen
--   5. Alles, was übrig bleibt, wird gezählt und in meta.dq_befund gemeldet
--
-- Bekannte Unschärfe: Behördenkennungen wie e29, e32, e34 kollidieren mit
-- Technologienummern 29, 32, 34. Ein Token 'e529' wird deshalb komplett
-- verworfen, statt zu raten. Betrifft in 2025 genau 1 Satz. Wird im NvS genannt.
-- -----------------------------------------------------------------------------

-- Whitelist der in den Daten tatsächlich auftretenden Technologienummern.
-- Quelle: eigene Auszählung über GROUP BY IT, Jahrgang 2025.
CREATE TABLE IF NOT EXISTS core.oeko_code_liste (
    code      text PRIMARY KEY,
    bemerkung text
);
INSERT INTO core.oeko_code_liste (code, bemerkung) VALUES
    ('08', 'Öko-Innovation Nr. 8'),  ('28', 'Öko-Innovation Nr. 28'),
    ('29', 'Öko-Innovation Nr. 29'), ('32', 'Öko-Innovation Nr. 32'),
    ('33', 'Öko-Innovation Nr. 33'), ('35', 'Öko-Innovation Nr. 35'),
    ('37', 'Öko-Innovation Nr. 37'), ('38', 'Öko-Innovation Nr. 38'),
    ('39', 'Öko-Innovation Nr. 39'), ('82', 'in den Daten beobachtet, Zuordnung offen')
ON CONFLICT (code) DO NOTHING;

CREATE OR REPLACE FUNCTION core.oeko_codes(t text)
RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN t IS NULL OR btrim(t) = '' THEN NULL ELSE (
        SELECT array_agg(DISTINCT paar ORDER BY paar)
        FROM (
            SELECT substr(ziffern, g, 2) AS paar
            FROM (
                SELECT tok AS ziffern
                FROM regexp_split_to_table(btrim(t), '\s+') AS tok
                WHERE tok ~ '^[0-9]+$' AND length(tok) % 2 = 0
            ) z,
            LATERAL generate_series(1, length(z.ziffern), 2) AS g
        ) p
        WHERE paar IN (SELECT code FROM core.oeko_code_liste)
    ) END
$$;
COMMENT ON FUNCTION core.oeko_codes(text) IS 'Zerlegt das IT-Feld in geprüfte Öko-Innovationscodes; verwirft Behördenkennungen und nicht auflösbare Tokens.';

-- -----------------------------------------------------------------------------
-- Antriebsklasse aus Ft × Fm
--
-- Die Reihenfolge ist bindend. Begründung siehe 00_doku/05_Datenlandkarte.md §3.1:
-- Fm führt, weil es die Ladefähigkeit beschreibt. Ft allein würde 3,7 Mio.
-- Hybride unsichtbar unter 'petrol' verstecken und H2 falsch beantworten.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.antriebsklasse(ft text, fm text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN lower(btrim(coalesce(ft, ''))) = 'hydrogen'          THEN 'FCEV'
        WHEN upper(btrim(coalesce(fm, ''))) = 'E'                 THEN 'BEV'
        WHEN upper(btrim(coalesce(fm, ''))) = 'P'                 THEN 'PHEV'
        WHEN upper(btrim(coalesce(fm, ''))) = 'H'                 THEN 'HEV'
        WHEN upper(btrim(coalesce(fm, ''))) = 'B'                 THEN 'BIFUEL'
        WHEN upper(btrim(coalesce(fm, ''))) = 'F'                 THEN 'FLEX'
        WHEN upper(btrim(coalesce(fm, ''))) = 'M'
             AND lower(btrim(coalesce(ft, ''))) = 'diesel'        THEN 'ICE_DIESEL'
        WHEN upper(btrim(coalesce(fm, ''))) = 'M'
             AND lower(btrim(coalesce(ft, ''))) = 'petrol'        THEN 'ICE_BENZIN'
        WHEN upper(btrim(coalesce(fm, ''))) = 'M'                 THEN 'ICE_SONSTIGE'
        ELSE 'UNBEKANNT'
    END
$$;

-- =============================================================================
-- core.registration
-- =============================================================================
DROP TABLE IF EXISTS core.registration;
CREATE UNLOGGED TABLE core.registration (
    reg_id             bigserial,
    src_id             bigint      NOT NULL,   -- ID der EEA, je Jahrgang eindeutig
    jahr               smallint    NOT NULL,
    ms                 char(2)     NOT NULL,
    -- Hersteller
    mp_pool            text,
    mh_name            text,
    man_name           text,
    -- Modell und Typgenehmigung
    tan                text,
    typ                text,
    variante           text,
    version            text,
    marke              text,
    handelsname        text,
    marke_norm         text,
    handelsname_norm   text,
    fahrzeugklasse     text,
    -- Antrieb
    ft                 text,
    fm                 char(1),
    antriebsklasse     text,
    ist_elektrifiziert boolean,
    ist_extern_ladbar  boolean,
    -- Kennzahlen
    masse_kg           numeric(7,1),
    pruefmasse_kg      numeric(7,1),
    co2_wltp           numeric(6,1),
    co2_nedc           numeric(6,1),
    radstand_mm        integer,
    hubraum_cm3        integer,
    leistung_kw        numeric(6,1),
    strom_wh_km        numeric(7,2),
    verbrauch_l        numeric(6,2),
    -- Öko-Innovation
    oeko_code_roh      text,
    oeko_codes         text[],
    oeko_gutschrift    numeric(5,2),
    -- Zeit und Herkunft
    zulassung_datum    date,
    data_status        char(1),
    source_version     text
);
COMMENT ON TABLE core.registration IS 'Typisierte Zulassungen, gefiltert auf Pkw (M1/M1G), mit abgeleiteter Antriebsklasse und tokenisierten Öko-Innovationscodes.';

-- -----------------------------------------------------------------------------
-- Befüllen aus allen Jahrgängen
-- -----------------------------------------------------------------------------
INSERT INTO core.registration (
    src_id, jahr, ms, mp_pool, mh_name, man_name,
    tan, typ, variante, version, marke, handelsname,
    marke_norm, handelsname_norm, fahrzeugklasse,
    ft, fm, antriebsklasse, ist_elektrifiziert, ist_extern_ladbar,
    masse_kg, pruefmasse_kg, co2_wltp, co2_nedc, radstand_mm,
    hubraum_cm3, leistung_kw, strom_wh_km, verbrauch_l,
    oeko_code_roh, oeko_codes, oeko_gutschrift,
    zulassung_datum, data_status, source_version
)
SELECT
    core.zu_zahl(r.id)::bigint,
    core.zu_zahl(r.jahr)::smallint,
    upper(btrim(r.ms)),
    core.leer_zu_null(r.mp),
    core.leer_zu_null(r.mh),
    core.leer_zu_null(r.man),
    core.leer_zu_null(r.tan),
    core.leer_zu_null(r.typ),
    core.leer_zu_null(r.va),
    core.leer_zu_null(r.ve),
    core.leer_zu_null(r.mk),
    core.leer_zu_null(r.cn),
    core.norm_name(r.mk),
    core.norm_name(r.cn),
    upper(btrim(r.ct)),
    lower(core.leer_zu_null(r.ft)),
    upper(left(btrim(coalesce(r.fm, '')), 1)),
    core.antriebsklasse(r.ft, r.fm),
    core.antriebsklasse(r.ft, r.fm) IN ('BEV', 'PHEV', 'HEV', 'FCEV'),
    core.antriebsklasse(r.ft, r.fm) IN ('BEV', 'PHEV'),
    core.zu_zahl(r.m_kg),
    core.zu_zahl(r.mt),
    core.zu_zahl(r.ewltp),
    core.zu_zahl(r.enedc),
    core.zu_zahl(r.w_mm)::integer,
    core.zu_zahl(r.ec_cm3)::integer,
    core.zu_zahl(r.ep_kw),
    core.zu_zahl(r.z_whkm),
    core.zu_zahl(r.fc),
    core.leer_zu_null(r.it_code),
    core.oeko_codes(r.it_code),
    core.zu_zahl(r.erwltp),
    core.zu_datum(r.dr),
    upper(left(btrim(coalesce(r.status, '')), 1)),
    core.leer_zu_null(r.version_file)
FROM (
    -- Deduplizierung auf (Jahrgang, Satz-ID).
    --
    -- Nötig geworden durch die Ladehistorie: Wurde ein Downloadlauf beendet und
    -- der gesicherte Stand lag hinter dem tatsächlichen Schreibstand, kamen die
    -- Sätze dazwischen beim Wiederaufsetzen ein zweites Mal in die CSV. Die
    -- EEA-Satz-ID ist je Jahrgang eindeutig (für 2021 verifiziert: 9.920.521
    -- verschiedene Werte bei 9.920.521 Zeilen), also ist DISTINCT ON hier
    -- fachlich korrekt und nicht bloß ein Notbehelf.
    --
    -- Bewusst hier und nicht im Reparaturskript: In SQL ist die Entscheidung
    -- dokumentiert, wiederholbar und die Zahl der entfernten Sätze messbar.
    SELECT DISTINCT ON (v.jahr, v.id) v.*
    FROM raw.v_co2cars_alle v
    WHERE upper(btrim(coalesce(v.ct, ''))) IN ('M1', 'M1G')   -- Filterentscheidung, siehe unten
    ORDER BY v.jahr, v.id
) r;

-- =============================================================================
-- Protokoll der Filterentscheidung — nicht stillschweigend wegfiltern
-- =============================================================================
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'core', 'registration', 'fahrzeugklasse',
       'Beim Übergang raw -> core ausgeschlossene Zeilen',
       count(*), 'Zeilen', NULL,
       'auffaellig',
       'Fahrzeugklasse ' || coalesce(nullif(upper(btrim(coalesce(ct, ''))), ''), '(leer)')
       || ' gehört nicht zu M1/M1G'
FROM raw.v_co2cars_alle
WHERE upper(btrim(coalesce(ct, ''))) NOT IN ('M1', 'M1G')
GROUP BY upper(btrim(coalesce(ct, '')));

-- Doppelte Satz-IDs aus der Ladehistorie zählen und melden
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'core', 'registration', 'src_id',
       'Beim Uebergang raw -> core entfernte Dubletten (gleiche Satz-ID)',
       (SELECT count(*) FROM raw.v_co2cars_alle
        WHERE upper(btrim(coalesce(ct, ''))) IN ('M1', 'M1G'))
       - (SELECT count(*) FROM core.registration),
       'Zeilen', 0,
       CASE WHEN (SELECT count(*) FROM raw.v_co2cars_alle
                  WHERE upper(btrim(coalesce(ct, ''))) IN ('M1', 'M1G'))
                 = (SELECT count(*) FROM core.registration)
            THEN 'ok' ELSE 'auffaellig' END,
       'Entstehen, wenn ein Wiederaufsetzpunkt hinter dem tatsaechlichen Schreibstand lag. Die EEA-Satz-ID ist je Jahrgang eindeutig, DISTINCT ON ist daher fachlich korrekt.';

-- Zeilenzahl je Jahr gegen die an der Quelle gezaehlte Sollmenge
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'core', 'registration', 'jahr ' || s.jahr,
       'Eindeutige Saetze gegen Quellzaehlung (vor Klassenfilter)',
       coalesce(c.n, 0) - s.soll, 'Zeilen', 0,
       CASE WHEN abs(coalesce(c.n, 0) - s.soll) <= 1000 THEN 'ok' ELSE 'auffaellig' END,
       format('Ist %s, Soll %s. Differenz erklaert sich aus dem Filter Ct IN (M1, M1G).',
              coalesce(c.n, 0), s.soll)
FROM (VALUES (2021, 7164289), (2022, 6853648), (2023, 7685055),
             (2024, 7666174), (2025, 7770432)) AS s(jahr, soll)
LEFT JOIN (SELECT jahr, count(*) AS n FROM core.registration GROUP BY jahr) c ON c.jahr = s.jahr;

INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar)
SELECT 'core', 'registration', 'antriebsklasse',
       'Sätze ohne zuordenbare Antriebsklasse', count(*), 'Zeilen',
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'auffaellig' END,
       'Kombination Ft/Fm nicht in der Regeltabelle — Regel in core.antriebsklasse prüfen'
FROM core.registration WHERE antriebsklasse = 'UNBEKANNT';

INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar)
SELECT 'core', 'registration', 'oeko_codes',
       'IT belegt, aber kein Code auflösbar', count(*), 'Zeilen',
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'auffaellig' END,
       'Behördenkennung und Technologienummer verschmolzen (z. B. e529) — bewusst verworfen statt geraten'
FROM core.registration WHERE oeko_code_roh IS NOT NULL AND oeko_codes IS NULL;

INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar)
SELECT 'core', 'registration', 'co2_wltp',
       'Ewltp im Rohtext vorhanden, aber nicht konvertierbar', count(*), 'Zeilen',
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'kritisch' END,
       'Wenn > 0, ist die Konvertierungsregel in core.zu_zahl unvollständig'
FROM raw.v_co2cars_alle r
WHERE upper(btrim(coalesce(r.ct, ''))) IN ('M1', 'M1G')
  AND core.leer_zu_null(r.ewltp) IS NOT NULL
  AND core.zu_zahl(r.ewltp) IS NULL;

-- =============================================================================
-- Kontrollausgabe
-- =============================================================================
\echo ''
\echo '--- Zeilen je Jahr: raw gegen core ----------------------------------------'
SELECT r.jahr,
       r.n_raw,
       c.n_core,
       r.n_raw - c.n_core AS ausgefiltert
FROM (SELECT jahr, count(*) AS n_raw FROM raw.v_co2cars_alle GROUP BY jahr) r
LEFT JOIN (SELECT jahr::text AS jahr, count(*) AS n_core FROM core.registration GROUP BY jahr) c
       ON c.jahr = r.jahr
ORDER BY r.jahr;

\echo ''
\echo '--- Antriebsklassen je Jahr -----------------------------------------------'
SELECT antriebsklasse,
       count(*) FILTER (WHERE jahr = 2021) AS j2021,
       count(*) FILTER (WHERE jahr = 2023) AS j2023,
       count(*) FILTER (WHERE jahr = 2025) AS j2025,
       count(*) AS gesamt,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS prozent
FROM core.registration
GROUP BY antriebsklasse
ORDER BY gesamt DESC;

\echo ''
\echo '--- Öko-Innovation: wie viele Fahrzeuge, wie viele Codes ------------------'
SELECT jahr,
       count(*)                                          AS fahrzeuge,
       count(*) FILTER (WHERE oeko_codes IS NOT NULL)    AS mit_oeko,
       round(100.0 * count(*) FILTER (WHERE oeko_codes IS NOT NULL) / count(*), 2) AS prozent,
       round(avg(oeko_gutschrift) FILTER (WHERE oeko_gutschrift IS NOT NULL), 2)   AS avg_gutschrift
FROM core.registration
GROUP BY jahr ORDER BY jahr;

\echo ''
\echo '--- Häufigste Öko-Innovationscodes (tokenisiert) --------------------------'
SELECT code, count(*) AS fahrzeuge
FROM core.registration, unnest(oeko_codes) AS code
GROUP BY code ORDER BY fahrzeuge DESC;

\echo ''
\echo '--- Neue Befunde aus dem core-Schritt -------------------------------------'
SELECT objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar
FROM meta.dq_befund WHERE schicht = 'core' ORDER BY befund_id;
