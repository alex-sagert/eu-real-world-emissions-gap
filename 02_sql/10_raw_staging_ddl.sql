-- =============================================================================
-- 10_raw_staging_ddl.sql   ·   läuft gegen bd_co2
--   psql -U postgres -d bd_co2 -f 02_sql\10_raw_staging_ddl.sql
--
-- Staging-Schicht. Bewusste Entscheidungen:
--   * alle Spalten TEXT      → kein einziger Satz geht beim Laden verloren, auch
--                              wenn ein Feld unerwartet leer, gerundet oder
--                              lokalisiert formatiert ist
--   * UNLOGGED               → kein WAL beim Erstladen, spart bei 37 Mio. Zeilen
--                              deutlich Zeit. Verlust bei Crash ist egal, die
--                              Quelle ist reproduzierbar
--   * keine Constraints/Indizes → Indizes entstehen erst nach dem Laden
--   * Spaltennamen exakt in der Reihenfolge, die
--     03_skripte\01_download_co2cars.ps1 schreibt
-- =============================================================================

\set ON_ERROR_STOP on

-- -----------------------------------------------------------------------------
-- co2cars — ein Staging-Table je Jahrgang
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    j int;
BEGIN
    FOREACH j IN ARRAY ARRAY[2021, 2022, 2023, 2024, 2025] LOOP
        EXECUTE format($f$
            DROP TABLE IF EXISTS raw.co2cars_%1$s;
            CREATE UNLOGGED TABLE raw.co2cars_%1$s (
                id            text,   -- Satz-ID der EEA, je Jahrgang aufsteigend
                ms            text,   -- Mitgliedstaat
                mp            text,   -- Herstellergruppe (Pool)
                mh            text,   -- Hersteller harmonisiert
                man           text,   -- Hersteller Rechtsname
                tan           text,   -- Typgenehmigungsnummer
                typ           text,   -- Typ
                va            text,   -- Variante
                ve            text,   -- Version
                mk            text,   -- Marke
                cn            text,   -- Handelsname
                ct            text,   -- Fahrzeugklasse (M1 = Pkw)
                m_kg          text,   -- Masse fahrbereit
                mt            text,   -- Prüfmasse WLTP
                enedc         text,   -- CO2 NEDC
                ewltp         text,   -- CO2 WLTP
                w_mm          text,   -- Radstand
                ft            text,   -- Kraftstoffart
                fm            text,   -- Fuel Mode
                ec_cm3        text,   -- Hubraum
                ep_kw         text,   -- Leistung
                z_whkm        text,   -- Stromverbrauch
                it_code       text,   -- Öko-Innovationscode (Leerstring statt NULL!)
                erwltp        text,   -- Gutschrift Öko-Innovation
                dr            text,   -- Zulassungsdatum
                fc            text,   -- Verbrauch l/100km
                r_count       text,   -- Anzahl Zulassungen des Satzes
                jahr          text,   -- Berichtsjahr
                status        text,   -- F final / P provisional
                version_file  text    -- v24 … v31
            );
            COMMENT ON TABLE raw.co2cars_%1$s IS
                'Staging EEA co2cars %1$s, alle Spalten TEXT, 1:1 aus DiscoData-REST.';
        $f$, j);
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Historische Massen-Aggregate 2010–2020 (für H4, an der Quelle vorverdichtet)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.co2cars_hist_massen;
CREATE UNLOGGED TABLE raw.co2cars_hist_massen (
    jahr        text,
    tabelle     text,
    ms          text,
    mass_bucket text,
    ft          text,
    n           text,
    avg_mass    text,
    avg_ewltp   text,
    avg_enedc   text,
    avg_kw      text
);
COMMENT ON TABLE raw.co2cars_hist_massen IS 'Massen-Histogramm je Land/Jahr/Antrieb in 50-kg-Klassen, 2010–2020. Vorverdichtung an der Quelle statt 100 Mio. Einzelzeilen — begründet im NvS.';

-- -----------------------------------------------------------------------------
-- Zuordnung Jahr → EEA-Tabellenname (Reproduzierbarkeit)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS raw.co2cars_tabellen;
CREATE TABLE raw.co2cars_tabellen (
    jahr    text,
    tabelle text
);

\echo 'Staging-Tabellen angelegt. Nächster Schritt: 03_skripte\11_load_staging.ps1'
