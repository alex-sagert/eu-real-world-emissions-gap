-- =============================================================================
-- 12_obfcm_staging.sql   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\12_obfcm_staging.sql
--
-- Staging für die EEA-Realverbrauchsdaten (OBFCM, VO 2019/631 Art. 12).
-- Spaltenreihenfolge exakt wie in 2023_Cars_Raw.csv (32 Spalten, am 10.08.2026
-- aus der Kopfzeile gelesen). Alle Spalten TEXT.
--
-- Zwei Besonderheiten der Datei, beide beim Laden zu beachten:
--   * Fehlende Werte stehen als Zeichenkette 'NULL', nicht als Leerfeld
--     -> COPY ... WITH (NULL 'NULL')
--   * 622.032 von 7.791.120 Zeilen (8,0 %) enthalten Kommas innerhalb von
--     Anführungszeichen, z. B. "XG1TJ(JP,M)". Die Datei ist korrekt
--     RFC-4180-quotiert, FORMAT csv verarbeitet das richtig.
-- =============================================================================

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS raw.obfcm_cars;
CREATE UNLOGGED TABLE raw.obfcm_cars (
    vehicle_id        text,   -- Vehicle Identifier (anonymisiert, VIN-Verknüpfung von der EEA gemacht)
    data_source       text,   -- OBFCM data source (beobachtet: durchgehend 'OEM')
    reporting_period  text,   -- OBFCM ReportingPeriod
    fuel_total_l      text,   -- Total fuel consumed (lifetime) (l)
    dist_total_km     text,   -- Total distance travelled (lifetime) (km)
    dist_cd_off_km    text,   -- charge depleting, Motor aus
    dist_cd_on_km     text,   -- charge depleting, Motor läuft
    dist_ci_km        text,   -- driver-selectable charge increasing
    fuel_cd_l         text,   -- Kraftstoff im charge depleting
    fuel_ci_l         text,   -- Kraftstoff im charge increasing
    grid_energy_kwh   text,   -- Total grid energy into the battery (lifetime) (kWh)
    country           text,
    vfn               text,
    mh                text,
    typ               text,   -- T
    va                text,
    ve                text,
    mk                text,
    cn                text,
    cr                text,
    m_kg              text,
    mt                text,
    ewltp             text,   -- Ewltp (g/km) — der Laborwert, im selben Satz!
    ft                text,   -- ACHTUNG: gemischte Gross-/Kleinschreibung
    fm                text,
    ec_cm3            text,
    ep_kw             text,
    z_whkm            text,
    jahr              text,   -- Year = Zulassungsjahr
    wltp_fc           text,   -- Fuel consumption = WLTP-Verbrauch l/100 km
    e_range_km        text,   -- Electric range (km)
    used_in_calc      text    -- 1 = von der EEA als verwendbar markiert
);
COMMENT ON TABLE raw.obfcm_cars IS 'Staging EEA OBFCM Cars, Berichtsjahr 2024 (Zulassungen 2021-2023), alle Spalten TEXT, 1:1 aus der Quelle.';

DROP TABLE IF EXISTS raw.obfcm_cars_agg;
CREATE UNLOGGED TABLE raw.obfcm_cars_agg (
    jahr                  text,
    hersteller            text,
    kraftstoff            text,
    n_fahrzeuge           text,
    obfcm_fc              text,
    wltp_fc               text,
    gap_fc_abs            text,
    gap_fc_pct            text,
    obfcm_co2             text,
    wltp_co2              text,
    gap_co2_abs           text,
    gap_co2_pct           text,
    obfcm_fc_w            text,
    wltp_fc_w             text,
    gap_fc_abs_w          text,
    gap_fc_pct_w          text,
    obfcm_co2_w           text,
    wltp_co2_w            text,
    gap_co2_abs_w         text,
    gap_co2_pct_w         text
);
COMMENT ON TABLE raw.obfcm_cars_agg IS 'Aggregatdatei der EEA: Luecke je Hersteller und Kraftstoff, bereits fertig gerechnet. Dient als unabhaengige Gegenprobe zur eigenen Rechnung.';

\echo 'OBFCM-Staging angelegt. Weiter mit 03_skripte\12_load_obfcm.ps1'
