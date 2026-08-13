-- =============================================================================
-- 45_oeko_gutschrift_pruefung.sql   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\45_oeko_gutschrift_pruefung.sql -OutFile .\00_doku\45_oeko_ausgabe.txt
--
-- DIE OFFENE FRAGE
-- Die Rohdaten führen zwei Spalten nebeneinander:
--     Ewltp   der zertifizierte CO2-Wert  -> core.registration.co2_wltp
--     Erwltp  die Öko-Innovationsgutschrift -> core.registration.oeko_gutschrift
--
-- Ungeklärt war bisher: Ist die Gutschrift in Ewltp bereits abgezogen, oder
-- steht sie daneben und muss noch abgezogen werden? Davon hängt ab, ob die
-- "offiziellen" Werte im Well-to-Wheel-Vergleich um die Gutschrift zu hoch sind.
--
-- DER TEST
-- CO2 und Kraftstoffverbrauch stehen in derselben Zeile. Ihr Quotient ergibt
-- den Emissionsfaktor, mit dem die Behörde selbst rechnet — bekannt aus der
-- Gegenprobe: 2278 g/l Benzin, 2631 g/l Diesel.
--
--   Ist die Gutschrift NICHT abgezogen, liegt der Quotient in beiden Gruppen
--   gleich hoch.
--   Ist sie abgezogen, liegt er bei Fahrzeugen mit Gutschrift NIEDRIGER — und
--   das Zurückaddieren der Gutschrift stellt den Faktor wieder her.
--
-- Damit entscheidet sich die Frage an den Daten und nicht an einer Auslegung
-- des Verordnungstextes.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

SET work_mem = '256MB';

\echo ''
\echo '=== Wie viele Fahrzeuge tragen ueberhaupt eine Gutschrift? ================'
SELECT jahr,
       count(*)                                                        AS fahrzeuge,
       count(*) FILTER (WHERE coalesce(oeko_gutschrift, 0) > 0)         AS mit_gutschrift,
       round(100.0 * count(*) FILTER (WHERE coalesce(oeko_gutschrift, 0) > 0)
             / nullif(count(*), 0), 1)                                  AS anteil_prozent,
       round(avg(oeko_gutschrift) FILTER (WHERE oeko_gutschrift > 0), 2) AS mittlere_gutschrift_g_km,
       max(oeko_gutschrift)                                             AS groesste_gutschrift
FROM core.registration
WHERE ms = 'DE'
GROUP BY jahr ORDER BY jahr;

\echo ''
\echo '=== DER ENTSCHEIDENDE TEST ==============================================='
\echo '>>> faktor_wie_gemeldet  = co2_wltp / verbrauch * 100'
\echo '>>> faktor_zurueckaddiert = (co2_wltp + gutschrift) / verbrauch * 100'
\echo '>>>'
\echo '>>> Erwartung Benzin 2278, Diesel 2631 (aus der Gegenprobe in 42_wtw).'
\echo '>>> Liegt "wie gemeldet" bei den Fahrzeugen MIT Gutschrift unter diesem'
\echo '>>> Wert und "zurueckaddiert" wieder darauf, dann ist die Gutschrift'
\echo '>>> in Ewltp bereits abgezogen.'
SELECT ft,
       CASE WHEN coalesce(oeko_gutschrift, 0) > 0 THEN 'mit Gutschrift'
            ELSE 'ohne Gutschrift' END                                   AS gruppe,
       count(*)                                                          AS fahrzeuge,
       round(avg(coalesce(oeko_gutschrift, 0))::numeric, 2)              AS gutschrift_g_km,
       round(avg(co2_wltp / nullif(verbrauch_l, 0) * 100)::numeric, 1)   AS faktor_wie_gemeldet,
       round(avg((co2_wltp + coalesce(oeko_gutschrift, 0))
                 / nullif(verbrauch_l, 0) * 100)::numeric, 1)            AS faktor_zurueckaddiert
FROM core.registration
WHERE ms = 'DE'
  AND ft IN ('petrol', 'diesel')
  AND verbrauch_l > 0 AND co2_wltp > 0
GROUP BY ft, 2
ORDER BY ft, 2 DESC;

\echo ''
\echo '=== Gegenprobe am Median, falls Ausreisser den Mittelwert ziehen =========='
SELECT ft,
       CASE WHEN coalesce(oeko_gutschrift, 0) > 0 THEN 'mit Gutschrift'
            ELSE 'ohne Gutschrift' END                                   AS gruppe,
       count(*)                                                          AS fahrzeuge,
       round(percentile_cont(0.5) WITHIN GROUP (
             ORDER BY co2_wltp / nullif(verbrauch_l, 0) * 100)::numeric, 1) AS faktor_median,
       round(percentile_cont(0.5) WITHIN GROUP (
             ORDER BY (co2_wltp + coalesce(oeko_gutschrift, 0))
                      / nullif(verbrauch_l, 0) * 100)::numeric, 1)       AS faktor_median_zurueckaddiert
FROM core.registration
WHERE ms = 'DE'
  AND ft IN ('petrol', 'diesel')
  AND verbrauch_l > 0 AND co2_wltp > 0
GROUP BY ft, 2
ORDER BY ft, 2 DESC;

\echo ''
\echo '=== Wie stark wuerde der Well-to-Wheel-Vergleich betroffen? ==============='
\echo '>>> Nur relevant, falls die Gutschrift NICHT abgezogen ist: dann waeren'
\echo '>>> die offiziellen Werte um diesen Betrag zu hoch ausgewiesen.'
SELECT antriebsklasse,
       count(*)                                                          AS fahrzeuge,
       round(avg(co2_wltp)::numeric, 1)                                  AS co2_offiziell,
       round(avg(coalesce(oeko_gutschrift, 0))::numeric, 2)              AS mittlere_gutschrift,
       round(100.0 * avg(coalesce(oeko_gutschrift, 0))
             / nullif(avg(co2_wltp), 0), 2)                              AS anteil_prozent
FROM core.registration
WHERE ms = 'DE' AND co2_wltp > 0
GROUP BY antriebsklasse
ORDER BY count(*) DESC;

\echo ''
\echo '>>> Ergebnis in 00_doku/06_Ergebnis_Realverbrauchsluecke.md unter'
\echo '>>> "Geprüfte Annahmen" nachtragen und geprueft-Kennzeichen setzen.'
