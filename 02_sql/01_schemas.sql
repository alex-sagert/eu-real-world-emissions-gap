-- =============================================================================
-- 01_schemas.sql   ·   läuft gegen bd_co2
--   psql -U postgres -d bd_co2 -f 02_sql\01_schemas.sql
--
-- Vier Schichten. Die Trennung ist kein Selbstzweck: sie macht jeden Schritt
-- vom Rohtext bis zur Kennzahl im Bericht nachvollziehbar und rettet den Lauf,
-- wenn ein CSV kaputte Zeilen enthält.
-- =============================================================================

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS raw;    COMMENT ON SCHEMA raw  IS 'Staging: alle Spalten TEXT, 1:1 aus der Quelle, keine Constraints, UNLOGGED';
CREATE SCHEMA IF NOT EXISTS core;   COMMENT ON SCHEMA core IS 'typisiert, bereinigt, dedupliziert, mit Herkunftsspalten';
CREATE SCHEMA IF NOT EXISTS star;   COMMENT ON SCHEMA star IS 'Sternschema: dim_* und fact_*, fact_registration partitioniert nach Jahr';
CREATE SCHEMA IF NOT EXISTS mart;   COMMENT ON SCHEMA mart IS 'vorberechnete Aggregate für die Streamlit-App';
CREATE SCHEMA IF NOT EXISTS meta;   COMMENT ON SCHEMA meta IS 'Ladeprotokoll, Datenqualitätsbefunde, Quellenversionen';

-- -----------------------------------------------------------------------------
-- Ladeprotokoll: jeder Ladelauf wird protokolliert, damit im Bericht steht, mit
-- welchem Quellstand welche Zahl entstanden ist. Die Jahrgänge 2024/2025 sind
-- provisional und ändern sich zwischen zwei Läufen.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.load_log (
    load_id        bigserial PRIMARY KEY,
    quelle         text        NOT NULL,   -- 'EEA co2cars' | 'EEA OBFCM' | 'KBA' | 'SMARD'
    objekt         text        NOT NULL,   -- Tabellenname der Quelle bzw. Dateiname
    source_version text,                   -- z. B. 'v31'
    data_status    char(1),                -- 'F' final, 'P' provisional
    zeitraum       text,
    zeilen_soll    bigint,
    zeilen_ist     bigint,
    datei          text,
    geladen_am     timestamptz NOT NULL DEFAULT now(),
    bemerkung      text
);
COMMENT ON TABLE meta.load_log IS 'Ein Eintrag je geladener Quelldatei. Belegpflicht für CAT/Bericht.';

-- -----------------------------------------------------------------------------
-- Datenqualitätsbefunde: maschinell erzeugt von 15_qualitaet_raw.sql.
-- Befunde werden dokumentiert, nicht stillschweigend weggefiltert.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.dq_befund (
    befund_id   bigserial PRIMARY KEY,
    schicht     text NOT NULL,             -- 'raw' | 'core' | 'star'
    objekt      text NOT NULL,
    spalte      text,
    pruefung    text NOT NULL,
    ergebnis    numeric,
    einheit     text,
    schwelle    numeric,
    bewertung   text,                      -- 'ok' | 'auffaellig' | 'kritisch'
    kommentar   text,
    geprueft_am timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE meta.dq_befund IS 'Ergebnisse der Datenqualitätsprüfungen, Grundlage des Qualitätskapitels im Bericht.';

\echo 'Schemata raw, core, star, mart, meta angelegt.'
