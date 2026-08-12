-- =============================================================================
-- 13_smard_strommix.sql   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\13_smard_strommix.sql -OutFile .\00_doku\smard_ausgabe.txt
--
-- Staging und Auswertung der SMARD-Stromerzeugung. Ergebnis ist die CO₂-Intensität
-- des deutschen Strommixes in g/kWh je Stunde, Tag und Jahr.
--
-- Wozu: Der OBFCM-Wert eines Elektroautos ist per Definition 0 g/km, weil nur der
-- Auspuff zählt. Ohne Strommix ist der Vergleich Verbrenner ↔ PHEV ↔ BEV nicht
-- fair — und genau daran hängt die noch offene Hälfte von H2.
--
-- Quelle: Bundesnetzagentur | SMARD.de, CC-BY-4.0
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
-- Eingangskontrolle
--
-- Die Staging-DDL und der \copy liegen in 03_skripte/21_load_smard.ps1. Frueher
-- stand hier ein DROP TABLE + CREATE TABLE - und genau das war der Fehler vom
-- 12.08.2026: Die CSV war heruntergeladen, die Tabelle wurde angelegt, aber
-- niemand hat geladen. Das Skript rechnete auf einer leeren Tabelle weiter,
-- meldete "SELECT 0" und lieferte am Ende einen Well-to-Wheel-Vergleich aus
-- lauter NULL-Werten. Alle vier Kettenschritte standen auf "ok".
--
-- Ein leerer Eingang ist ab jetzt ein Abbruch, kein Ergebnis.
-- -----------------------------------------------------------------------------
DO $$
DECLARE n bigint;
BEGIN
    IF to_regclass('raw.smard_erzeugung') IS NULL THEN
        RAISE EXCEPTION 'raw.smard_erzeugung fehlt. Zuerst 03_skripte/21_load_smard.ps1 ausfuehren.';
    END IF;
    EXECUTE 'SELECT count(*) FROM raw.smard_erzeugung' INTO n;
    IF n = 0 THEN
        RAISE EXCEPTION 'raw.smard_erzeugung ist leer. Zuerst 03_skripte/21_load_smard.ps1 ausfuehren.';
    END IF;
    RAISE NOTICE 'Eingangskontrolle bestanden: % Stundenwerte in raw.smard_erzeugung.', n;
END $$;

-- -----------------------------------------------------------------------------
-- Emissionsfaktoren
--
-- OFFENGELEGTE ANNAHME, vor der Abgabe zu prüfen:
-- Verwendet werden **direkte** Emissionsfaktoren der Stromerzeugung
-- (Verbrennungsemissionen am Kraftwerk), nicht Lebenszyklusfaktoren. Das ist die
-- methodisch saubere Wahl, weil auch der OBFCM-Wert eines Verbrenners nur den
-- Auspuff misst und die Vorkette des Kraftstoffs nicht enthält. Beide Seiten des
-- Vergleichs sind damit gleich abgegrenzt.
--
-- Wer Lebenszyklusfaktoren einsetzen will, ändert nur diese Tabelle — die
-- Kennzahl rechnet sich neu, ohne dass eine Query angefasst wird. Genau dafür
-- steht sie hier und nicht als Konstante im SQL.
--
-- `geprueft = false` heißt: Wert plausibel, aber noch nicht gegen eine
-- zitierfähige Primärquelle (UBA-Emissionsbilanz) verifiziert.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS core.emissionsfaktor;
CREATE TABLE core.emissionsfaktor (
    traeger      text PRIMARY KEY,
    g_co2_je_kwh numeric(7,1) NOT NULL,
    art          text NOT NULL,          -- 'direkt' oder 'lebenszyklus'
    geprueft     boolean NOT NULL DEFAULT false,
    begruendung  text
);

INSERT INTO core.emissionsfaktor (traeger, g_co2_je_kwh, art, geprueft, begruendung) VALUES
    ('braunkohle',              1100.0, 'direkt', false, 'Groessenordnung deutscher Braunkohlekraftwerke; hoechster Faktor im Mix'),
    ('steinkohle',               850.0, 'direkt', false, 'Groessenordnung deutscher Steinkohlekraftwerke'),
    ('erdgas',                   400.0, 'direkt', false, 'GuD und Gasturbinen gemischt; Bandbreite 350-450'),
    ('sonstige_konventionelle',  600.0, 'direkt', false, 'Sammelposten Oel/Abfall/Sonstige; Naeherung, Anteil am Mix gering'),
    ('kernenergie',                0.0, 'direkt', true,  'keine Verbrennungsemission; ab April 2023 ohnehin 0 MWh'),
    ('wasserkraft',                0.0, 'direkt', true,  'keine Verbrennungsemission'),
    ('wind_onshore',               0.0, 'direkt', true,  'keine Verbrennungsemission'),
    ('wind_offshore',              0.0, 'direkt', true,  'keine Verbrennungsemission'),
    ('photovoltaik',               0.0, 'direkt', true,  'keine Verbrennungsemission'),
    ('biomasse',                   0.0, 'direkt', false, 'bilanziell als CO2-neutral gefuehrt; bei Lebenszyklusbetrachtung deutlich > 0'),
    ('sonstige_erneuerbare',       0.0, 'direkt', true,  'Geothermie/Sonstige'),
    ('pumpspeicher',               0.0, 'direkt', false, 'Speicher, keine Primaererzeugung. Die Emission steckt im eingespeicherten Strom und wuerde bei Anrechnung doppelt gezaehlt');

COMMENT ON TABLE core.emissionsfaktor IS 'Emissionsfaktoren je Energietraeger. Direkte Verbrennungsemissionen, gleich abgegrenzt wie der OBFCM-Auspuffwert. geprueft=false = noch nicht gegen Primaerquelle verifiziert.';

-- -----------------------------------------------------------------------------
-- core.strommix — lange Form, ein Satz je Zeitpunkt und Träger
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS core.strommix;
CREATE TABLE core.strommix AS
SELECT (core.zu_zahl(s.zeitstempel) / 1000)::bigint                       AS epoch_sek,
       to_timestamp(core.zu_zahl(s.zeitstempel) / 1000)                    AS zeitpunkt,
       t.traeger,
       core.zu_zahl(t.mwh)                                                 AS mwh
FROM raw.smard_erzeugung s
CROSS JOIN LATERAL (VALUES
    ('braunkohle', s.braunkohle), ('kernenergie', s.kernenergie),
    ('wasserkraft', s.wasserkraft), ('sonstige_konventionelle', s.sonstige_konventionelle),
    ('sonstige_erneuerbare', s.sonstige_erneuerbare), ('biomasse', s.biomasse),
    ('wind_offshore', s.wind_offshore), ('wind_onshore', s.wind_onshore),
    ('photovoltaik', s.photovoltaik), ('erdgas', s.erdgas),
    ('steinkohle', s.steinkohle), ('pumpspeicher', s.pumpspeicher)
) AS t(traeger, mwh)
WHERE core.zu_zahl(t.mwh) IS NOT NULL;

CREATE INDEX ix_strommix_zeit ON core.strommix (zeitpunkt);
CREATE INDEX ix_strommix_traeger ON core.strommix (traeger);
ANALYZE core.strommix;

-- -----------------------------------------------------------------------------
-- mart.strommix_intensitaet — CO₂-Intensität je Stunde
--
-- Pumpspeicher wird aus dem Nenner genommen: Er erzeugt keinen Strom, sondern
-- gibt vorher eingespeicherten wieder ab. Bliebe er drin, würde dieselbe Energie
-- zweimal in der Bilanz stehen und die Intensität künstlich senken.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS mart.strommix_intensitaet;
CREATE TABLE mart.strommix_intensitaet AS
SELECT m.zeitpunkt,
       extract(year  FROM m.zeitpunkt)::smallint AS jahr,
       extract(month FROM m.zeitpunkt)::smallint AS monat,
       extract(hour  FROM m.zeitpunkt)::smallint AS stunde,
       sum(m.mwh)                                                       AS erzeugung_mwh,
       sum(m.mwh * f.g_co2_je_kwh)                                      AS emission_g_je_kwh_gewichtet,
       round(sum(m.mwh * f.g_co2_je_kwh) / nullif(sum(m.mwh), 0), 1)    AS g_co2_je_kwh,
       round(100.0 * sum(m.mwh) FILTER (WHERE m.traeger IN
             ('wasserkraft','wind_onshore','wind_offshore','photovoltaik','biomasse','sonstige_erneuerbare'))
             / nullif(sum(m.mwh), 0), 1)                                AS anteil_erneuerbar_prozent
FROM core.strommix m
JOIN core.emissionsfaktor f ON f.traeger = m.traeger
WHERE m.traeger <> 'pumpspeicher'
GROUP BY m.zeitpunkt;

CREATE INDEX ix_intensitaet_zeit ON mart.strommix_intensitaet (zeitpunkt);
CREATE INDEX ix_intensitaet_jahr ON mart.strommix_intensitaet (jahr);
ANALYZE mart.strommix_intensitaet;

COMMENT ON TABLE mart.strommix_intensitaet IS 'CO2-Intensitaet des deutschen Strommixes je Stunde in g/kWh, plus Anteil erneuerbarer Erzeugung. Quelle: Bundesnetzagentur | SMARD.de, CC-BY-4.0.';

-- =============================================================================
-- Kontrolle und Plausibilität
-- =============================================================================
\echo ''
\echo '--- Jahresmittel der CO2-Intensitaet --------------------------------------'
\echo '>>> Plausibilitaetsanker: Der deutsche Strommix lag in diesen Jahren'
\echo '>>> groessenordnungsmaessig zwischen 300 und 450 g/kWh und faellt.'
\echo '>>> Werte deutlich ausserhalb deuten auf falsche Faktoren oder Filter-IDs.'
SELECT jahr,
       count(*)                                             AS stunden,
       round(avg(g_co2_je_kwh), 1)                          AS mittel_g_kwh,
       round(min(g_co2_je_kwh), 1)                          AS min_g_kwh,
       round(max(g_co2_je_kwh), 1)                          AS max_g_kwh,
       round(avg(anteil_erneuerbar_prozent), 1)             AS erneuerbar_prozent,
       round(sum(erzeugung_mwh) / 1e6, 1)                   AS erzeugung_twh
FROM mart.strommix_intensitaet
GROUP BY jahr ORDER BY jahr;

\echo ''
\echo '--- Tagesgang 2025: wann ist Laden sauber? --------------------------------'
SELECT stunde,
       round(avg(g_co2_je_kwh), 1)              AS mittel_g_kwh,
       round(avg(anteil_erneuerbar_prozent), 1) AS erneuerbar_prozent
FROM mart.strommix_intensitaet WHERE jahr = 2025
GROUP BY stunde ORDER BY stunde;

\echo ''
\echo '--- Verwendete Emissionsfaktoren (Annahmen offengelegt) -------------------'
SELECT traeger, g_co2_je_kwh, art, geprueft, begruendung
FROM core.emissionsfaktor ORDER BY g_co2_je_kwh DESC, traeger;

\echo ''
\echo '>>> Naechster Schritt: 42_wtw_vergleich.sql - Well-to-Wheel je Antriebsklasse.'
