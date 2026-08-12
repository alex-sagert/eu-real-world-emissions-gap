-- =============================================================================
-- 42_wtw_vergleich.sql   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\42_wtw_vergleich.sql -OutFile .\00_doku\wtw_ausgabe.txt
--
-- Well-to-Wheel: der faire Vergleich zwischen Verbrenner, Hybrid, Plug-in-Hybrid
-- und Batterieauto. Beantwortet die zweite Hälfte von H2.
--
-- Voraussetzungen: 25_core_realworld.sql und 13_smard_strommix.sql sind gelaufen.
--
-- Die Frage, die hier entschieden wird:
--   Auf den Auspuff gerechnet verbraucht der Plug-in-Hybrid real 6,00 l/100 km
--   gegenüber 7,44 l beim reinen Benziner — er bleibt also vorn. Aber er zieht
--   zusätzlich Netzstrom, der beim Verbrenner nicht anfällt. Kippt das Bild,
--   wenn dieser Strom mit dem realen deutschen Mix bewertet wird?
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
-- Ohne Strommix ist dieser Vergleich nicht rechenbar. Ist mart.strommix_intensitaet
-- leer, liefert avg() ueber die leere Menge NULL, jede Multiplikation damit wird
-- NULL - und heraus kaeme eine formal vollstaendige Tabelle aus lauter Leerwerten,
-- ohne eine einzige Fehlermeldung. Genau so ist der Lauf vom 12.08.2026 durch die
-- Kette gerutscht. Lieber ein harter Abbruch als ein leeres Ergebnis.
-- -----------------------------------------------------------------------------
DO $$
DECLARE n bigint;
BEGIN
    IF to_regclass('mart.strommix_intensitaet') IS NULL THEN
        RAISE EXCEPTION 'mart.strommix_intensitaet fehlt. Zuerst 21_load_smard.ps1 und 13_smard_strommix.sql.';
    END IF;
    EXECUTE 'SELECT count(*) FROM mart.strommix_intensitaet' INTO n;
    IF n = 0 THEN
        RAISE EXCEPTION 'mart.strommix_intensitaet ist leer - der Well-to-Wheel-Vergleich waere ohne Aussage.';
    END IF;
    RAISE NOTICE 'Eingangskontrolle bestanden: % Stundenwerte im Strommix.', n;
END $$;

-- -----------------------------------------------------------------------------
-- Kraftstoff-Emissionsfaktoren
--
-- OFFENGELEGTE ANNAHME. Die Werte werden unten zusätzlich empirisch aus der
-- EEA-Aggregatdatei zurückgerechnet — dort stehen Verbrauch UND CO2 nebeneinander,
-- der Quotient ergibt den von der EEA selbst verwendeten Faktor. Weicht unsere
-- Annahme davon ab, ist das ein Fehlersignal.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS core.kraftstofffaktor;
CREATE TABLE core.kraftstofffaktor (
    kraftstoff   text PRIMARY KEY,
    g_co2_je_l   numeric(7,1) NOT NULL,
    geprueft     boolean NOT NULL DEFAULT false,
    begruendung  text
);
-- NACHGEPRUEFT am 12.08.2026. Die Gegenprobe unten hat die urspruengliche
-- Annahme widerlegt und wird deshalb hier uebernommen:
--
--   angenommen war   Benzin 2330,  Diesel 2640 g/l  (Literaturwerte)
--   die EEA rechnet  Benzin 2278,  Diesel 2631 g/l  (aus ihren eigenen Daten
--                    zurueckgerechnet, obfcm_co2 / obfcm_fc * 100, ueber 94
--                    bzw. 57 Fahrzeuggruppen identisch fuer OBFCM und WLTP)
--
-- Beim Benzin sind das 2,2 % Abweichung. Uebernommen werden die EEA-Werte, weil
-- unsere Verbrauchszahlen aus derselben Quelle stammen - eine fremde Konstante
-- daraufzurechnen wuerde einen Bruch in der Systemgrenze erzeugen. Die
-- Literaturwerte stehen in der Begruendungsspalte, damit die Entscheidung
-- nachvollziehbar bleibt.
INSERT INTO core.kraftstofffaktor VALUES
    ('petrol',          2278.0, true,  'Aus der EEA-Aggregatdatei zurueckgerechnet (94 Gruppen). Literaturannahme war 2330 - Abweichung 2,2 %.'),
    ('diesel',          2631.0, true,  'Aus der EEA-Aggregatdatei zurueckgerechnet (57 Gruppen). Literaturannahme war 2640 - Abweichung 0,3 %.'),
    ('petrol/electric', 2278.0, true,  'PHEV Benzin - Kraftstoffanteil, EEA-Faktor (56 Gruppen bestaetigen 2278)'),
    ('diesel/electric', 2631.0, true,  'PHEV Diesel - Kraftstoffanteil, EEA-Faktor (3 Gruppen: 2631 OBFCM / 2637 WLTP)'),
    ('e85',             1600.0, false, 'E85, bilanziell reduziert wegen Bioethanolanteil'),
    ('lpg',             1660.0, false, 'Autogas'),
    ('ng',              1620.0, false, 'Erdgas, je kg statt je l - nur naeherungsweise vergleichbar');
COMMENT ON TABLE core.kraftstofffaktor IS 'Direkte Verbrennungsemission je Liter. Gleiche Systemgrenze wie die SMARD-Faktoren: ohne Vorkette, damit beide Seiten des Vergleichs gleich abgegrenzt sind.';

-- -----------------------------------------------------------------------------
-- Empirische Gegenprobe der Faktoren aus der EEA-Aggregatdatei
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Gegenprobe: welchen Faktor verwendet die EEA selbst? =================='
\echo '>>> Quotient aus CO2 (g/km) und Verbrauch (l/100 km), mal 100.'
SELECT kraftstoff,
       count(*)                                                             AS gruppen,
       round(avg(core.zu_zahl(obfcm_co2) / nullif(core.zu_zahl(obfcm_fc), 0) * 100), 0) AS faktor_aus_obfcm,
       round(avg(core.zu_zahl(wltp_co2)  / nullif(core.zu_zahl(wltp_fc),  0) * 100), 0) AS faktor_aus_wltp
FROM raw.obfcm_cars_agg
WHERE core.zu_zahl(n_fahrzeuge) >= 1000
GROUP BY kraftstoff ORDER BY kraftstoff;

-- -----------------------------------------------------------------------------
-- Annahme für den Realverbrauch des Batterieautos
--
-- Das OBFCM-System misst Kraftstoff, nicht Strom. Für reine Elektroautos gibt es
-- deshalb KEINEN gemessenen Realverbrauch in diesem Datensatz — nur den WLTP-Wert
-- `Z (Wh/km)` aus der Typprüfung.
--
-- Das ist eine echte Lücke, und sie wird nicht kaschiert: Für das BEV wird der
-- Laborwert mit einem Aufschlag versehen, der als Parameter offen liegt. Die
-- Auswertung wird für mehrere Aufschläge gerechnet, damit sichtbar ist, ob das
-- Ergebnis von dieser Annahme abhängt.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS core.bev_aufschlag;
CREATE TABLE core.bev_aufschlag (
    szenario  text PRIMARY KEY,
    aufschlag numeric(4,2) NOT NULL,
    begruendung text
);
INSERT INTO core.bev_aufschlag VALUES
    ('optimistisch', 1.00, 'BEV erreicht den Laborwert - untere Grenze, unrealistisch guenstig'),
    ('mittel',       1.15, 'plus 15 Prozent, in der Groessenordnung der gemessenen Verbrennerluecke'),
    ('konservativ',  1.30, 'plus 30 Prozent, deckt Winterbetrieb und Ladeverluste ab');

-- =============================================================================
-- Well-to-Wheel je Antriebsklasse
-- =============================================================================
DROP TABLE IF EXISTS mart.wtw_vergleich;
CREATE TABLE mart.wtw_vergleich AS
WITH strom AS (   -- Jahresmittel der CO2-Intensitaet des deutschen Mixes
    SELECT jahr, round(avg(g_co2_je_kwh), 1) AS g_kwh
    FROM mart.strommix_intensitaet GROUP BY jahr
),
strom_gesamt AS (
    SELECT round(avg(g_co2_je_kwh), 1) AS g_kwh FROM mart.strommix_intensitaet
),
verbrenner AS (
    -- KORREKTUR 12.08.2026. Vorher stand hier min(r.ft) AS ft_beispiel, und der
    -- Emissionsfaktor wurde ueber diesen einen Wert gezogen. min() waehlt aber
    -- ALPHABETISCH: In der PHEV-Klasse kommen 'diesel/electric' und
    -- 'petrol/electric' vor, min() liefert 'diesel/electric' - also wurde die
    -- gesamte PHEV-Flotte mit dem Dieselfaktor bepreist, obwohl sie
    -- ueberwiegend aus Benzinern besteht. Dasselbe traf die HEV-Klasse.
    -- Der Fehler war an der Ausgabe sichtbar: dieselbe PHEV-Flotte erschien in
    -- der Haupttabelle mit 157,7 g/km Auspuff und in der Sensitivitaets-
    -- rechnung mit 139,6 g/km.
    --
    -- Jetzt wird der Faktor je FAHRZEUG gezogen und als Mittel ueber die Klasse
    -- gebildet. Er ist damit mit der tatsaechlichen Kraftstoffverteilung
    -- gewichtet. mode() haelt zusaetzlich fest, welcher Kraftstoff die Klasse
    -- dominiert - das gehoert in die Dokumentation, nicht in die Rechnung.
    SELECT r.antriebsklasse,
           count(*)                                                            AS fahrzeuge,
           -- ::numeric ist zwingend: percentile_cont liefert double precision,
           -- und weiter unten wird mit numeric-Faktoren multipliziert und
           -- gerundet. round(double precision, integer) existiert nicht.
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.fc_real)::numeric      AS fc_real,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.fc_wltp)::numeric      AS fc_wltp,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.co2_wltp)::numeric     AS co2_wltp,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.masse_kg)::numeric     AS masse_kg,
           -- Netzstrom je 100 km, nur bei PHEV belegt
           percentile_cont(0.5) WITHIN GROUP (
               ORDER BY CASE WHEN r.dist_total_km > 0 AND r.grid_kwh IS NOT NULL
                             THEN r.grid_kwh / r.dist_total_km * 100 END)::numeric AS kwh_je_100km,
           NULL::numeric                                                       AS wh_je_km_wltp,
           mode() WITHIN GROUP (ORDER BY r.ft)                                 AS ft_haeufigster,
           round(avg(k.g_co2_je_l), 1)                                         AS faktor_g_je_l,
           'OBFCM gemessen'::text                                              AS quelle_real
    FROM core.realworld r
    LEFT JOIN core.kraftstofffaktor k ON k.kraftstoff = r.ft
    WHERE r.land = 'DE' AND r.eea_verwendbar AND r.hat_mindestlauf
    GROUP BY r.antriebsklasse
),
bev AS (
    -- Das BEV fehlte bisher vollstaendig, und zwar aus einem sachlichen Grund:
    -- OBFCM ist ein KRAFTSTOFF-Verbrauchsmesser. Ein Batterieauto hat keinen,
    -- steht also gar nicht in core.realworld. Die BEV-Zeile war deshalb leer -
    -- ausgerechnet fuer die Antriebsart, um die es bei H2 geht.
    --
    -- Die Zahlen kommen deshalb aus der Zulassungsstatistik: `Z (Wh/km)` aus
    -- der WLTP-Typpruefung. Das ist ein LABORWERT, kein gemessener. Genau
    -- dafuer stehen die drei Aufschlagsszenarien - und deshalb wird die Zeile
    -- in der Ausgabe als 'WLTP Laborwert' gekennzeichnet und nicht mit den
    -- gemessenen Verbrennerwerten in einen Topf geworfen.
    SELECT 'BEV'::text                                                         AS antriebsklasse,
           count(*)                                                            AS fahrzeuge,
           NULL::numeric AS fc_real, NULL::numeric AS fc_wltp,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY g.co2_wltp)::numeric    AS co2_wltp,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY g.masse_kg)::numeric    AS masse_kg,
           NULL::numeric                                                       AS kwh_je_100km,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY g.strom_wh_km)::numeric AS wh_je_km_wltp,
           'electric'::text                                                    AS ft_haeufigster,
           NULL::numeric                                                       AS faktor_g_je_l,
           'WLTP Laborwert'::text                                              AS quelle_real
    FROM core.registration g
    WHERE g.ms = 'DE' AND g.antriebsklasse = 'BEV' AND g.strom_wh_km IS NOT NULL
),
basis AS (
    SELECT * FROM verbrenner
    UNION ALL
    SELECT * FROM bev
)
SELECT b.antriebsklasse,
       b.fahrzeuge,
       b.quelle_real,
       b.ft_haeufigster,
       b.faktor_g_je_l,
       round(b.masse_kg, 0)                                                    AS masse_kg,
       -- offizieller Wert
       round(b.co2_wltp, 1)                                                    AS co2_offiziell,
       -- Auspuff real: Kraftstoff mal klassengewichteter Faktor.
       -- coalesce(...,0) statt eines Ersatzfaktors: Beim BEV gibt es keinen
       -- Auspuff, und ein stillschweigend eingesetzter Benzinfaktor haette dort
       -- eine Emission erfunden.
       round(coalesce(b.fc_real, 0) * coalesce(b.faktor_g_je_l, 0) / 100, 1)   AS co2_auspuff_real,
       -- Netzstrom real (PHEV, aus OBFCM gemessen)
       round(coalesce(b.kwh_je_100km, 0) * s.g_kwh / 100, 1)                   AS co2_strom_phev,
       -- Netzstrom BEV: Laborverbrauch mal Szenarioaufschlag
       round(coalesce(b.wh_je_km_wltp, 0) * a.aufschlag * s.g_kwh / 1000, 1)   AS co2_strom_bev,
       -- Summe
       round(coalesce(b.fc_real, 0) * coalesce(b.faktor_g_je_l, 0) / 100
             + coalesce(b.kwh_je_100km, 0) * s.g_kwh / 100
             + CASE WHEN b.antriebsklasse = 'BEV'
                    THEN coalesce(b.wh_je_km_wltp, 0) * a.aufschlag * s.g_kwh / 1000
                    ELSE 0 END, 1)                                             AS co2_wtw_gesamt,
       a.szenario                                                              AS bev_szenario,
       a.aufschlag                                                             AS bev_aufschlag,
       s.g_kwh                                                                 AS strommix_g_kwh,
       round(b.fc_real, 2)                                                     AS fc_real,
       round(b.kwh_je_100km, 1)                                                AS kwh_je_100km,
       round(b.wh_je_km_wltp, 1)                                               AS wh_je_km_wltp
FROM basis b
CROSS JOIN strom_gesamt s
CROSS JOIN core.bev_aufschlag a;

COMMENT ON TABLE mart.wtw_vergleich IS 'Well-to-Wheel je Antriebsklasse, Deutschland. Auspuff aus OBFCM gemessen, Strom mit dem realen SMARD-Mix bewertet. BEV-Realverbrauch ist nicht gemessen und deshalb in drei Szenarien gerechnet.';

\echo ''
\echo '=== H2 · Der faire Vergleich (Szenario mittel, BEV +15 %) ================='
\echo '>>> co2_offiziell    = WLTP-Typpruefwert, das Papier'
\echo '>>> co2_auspuff_real = gemessener Kraftstoff, mal Emissionsfaktor'
\echo '>>> co2_strom_*      = Netzstrom mit dem realen deutschen Mix bewertet'
SELECT antriebsklasse, fahrzeuge, quelle_real, ft_haeufigster, faktor_g_je_l, masse_kg,
       co2_offiziell, co2_auspuff_real,
       CASE WHEN antriebsklasse = 'BEV' THEN co2_strom_bev ELSE co2_strom_phev END AS co2_strom,
       co2_wtw_gesamt,
       round(co2_wtw_gesamt - co2_offiziell, 1)                                  AS differenz_zum_papier,
       round(100.0 * (co2_wtw_gesamt - co2_offiziell) / nullif(co2_offiziell, 0), 0) AS abweichung_prozent
FROM mart.wtw_vergleich
WHERE bev_szenario = 'mittel'
ORDER BY co2_wtw_gesamt;

\echo ''
\echo '>>> ACHTUNG bei der Auslegung: Die BEV-Zeile stammt aus der WLTP-Typpruefung,'
\echo '>>> alle anderen Zeilen aus gemessenem Realverbrauch. Die Spalte quelle_real'
\echo '>>> haelt das fest. OBFCM misst Kraftstoff - ein Batterieauto hat keinen'
\echo '>>> Kraftstoffmesser und ist in dieser Quelle deshalb nicht enthalten.'

\echo ''
\echo '=== H2 · Haengt das Ergebnis an der BEV-Annahme? =========================='
SELECT bev_szenario,
       max(co2_wtw_gesamt) FILTER (WHERE antriebsklasse = 'BEV')        AS bev,
       max(co2_wtw_gesamt) FILTER (WHERE antriebsklasse = 'PHEV')       AS phev,
       max(co2_wtw_gesamt) FILTER (WHERE antriebsklasse = 'ICE_BENZIN') AS benzin_rein,
       max(co2_wtw_gesamt) FILTER (WHERE antriebsklasse = 'ICE_DIESEL') AS diesel_rein,
       max(co2_wtw_gesamt) FILTER (WHERE antriebsklasse = 'HEV')        AS hybrid
FROM mart.wtw_vergleich GROUP BY bev_szenario ORDER BY bev_szenario;

\echo ''
\echo '=== H2 · Ab welchem Strommix kippt der PHEV hinter den Benziner? =========='
\echo '>>> Sensitivitaet: PHEV-Gesamtemission bei verschiedenen Strommix-Werten,'
\echo '>>> gegen den festen Auspuffwert des reinen Benziners.'
-- Der Emissionsfaktor kommt aus der Tabelle, NICHT als Zahl im SQL. Vorher
-- stand hier die Konstante 2330 - dieselbe Flotte erschien dadurch in dieser
-- Rechnung mit einem anderen Auspuffwert als in der Haupttabelle darueber.
-- Zwei Zahlen fuer denselben Sachverhalt sind immer ein Fehler, auch wenn
-- beide fuer sich plausibel aussehen.
WITH p AS (
    SELECT fc_real, kwh_je_100km, faktor_g_je_l, co2_auspuff_real FROM mart.wtw_vergleich
    WHERE antriebsklasse = 'PHEV' AND bev_szenario = 'mittel'
), b AS (
    SELECT co2_auspuff_real AS benzin FROM mart.wtw_vergleich
    WHERE antriebsklasse = 'ICE_BENZIN' AND bev_szenario = 'mittel'
)
SELECT mix.g_kwh                                                       AS strommix_g_kwh,
       p.co2_auspuff_real                                              AS phev_auspuff,
       round(p.kwh_je_100km * mix.g_kwh / 100, 1)                      AS phev_strom,
       round(p.co2_auspuff_real + p.kwh_je_100km * mix.g_kwh / 100, 1) AS phev_gesamt,
       b.benzin                                                        AS benzin_rein,
       CASE WHEN p.co2_auspuff_real + p.kwh_je_100km * mix.g_kwh / 100 > b.benzin
            THEN 'PHEV schlechter' ELSE 'PHEV besser' END              AS ergebnis
FROM p, b, (VALUES (0.0), (100.0), (200.0), (300.0), (350.0), (400.0), (450.0), (500.0), (600.0)) AS mix(g_kwh)
ORDER BY mix.g_kwh;

\echo ''
\echo '=== Kontrolle: stimmen Haupttabelle und Sensitivitaet ueberein? ==========='
\echo '>>> Der Auspuffwert des PHEV muss in beiden Rechnungen identisch sein.'
\echo '>>> Der Strommix-Jahresmittelwert muss zwischen 300 und 450 g/kWh liegen.'
SELECT round(strommix_g_kwh, 1)                                        AS verwendeter_mix_g_kwh,
       (SELECT co2_auspuff_real FROM mart.wtw_vergleich
        WHERE antriebsklasse = 'PHEV' AND bev_szenario = 'mittel')     AS phev_auspuff_haupttabelle,
       CASE WHEN strommix_g_kwh BETWEEN 300 AND 450
            THEN 'plausibel' ELSE 'PRUEFEN' END                        AS bewertung_mix
FROM mart.wtw_vergleich LIMIT 1;

ANALYZE mart.wtw_vergleich;

\echo ''
\echo '>>> Ergebnis in 00_doku/06_Ergebnis_Realverbrauchsluecke.md nachtragen und'
\echo '>>> H2 abschliessend bewerten.'
