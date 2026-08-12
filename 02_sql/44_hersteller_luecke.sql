-- =============================================================================
-- 44_hersteller_luecke.sql   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\44_hersteller_luecke.sql -OutFile .\00_doku\44_hersteller_ausgabe.txt
--
--   A7  Wer hält sein Versprechen? Die Realverbrauchslücke je Hersteller.
--
-- DIE FALLE, DIE HIER LAUERT
-- Ein naiver Vergleich „Lücke je Hersteller" misst nicht die Ehrlichkeit des
-- Herstellers, sondern seinen ANTRIEBSMIX. Wer viele Plug-in-Hybride verkauft,
-- landet automatisch hinten — nicht weil seine Motoren schlechter wären,
-- sondern weil die PHEV-Lücke bei über 300 % liegt und alles andere überdeckt.
--
-- Deshalb wird hier dreifach gerechnet:
--   A7a  nur reine Verbrenner        -> vergleicht Gleiches mit Gleichem
--   A7b  nur Plug-in-Hybride         -> zeigt, ob es auch dort Unterschiede gibt
--   A7c  alles zusammen + Mixeffekt  -> zeigt, wie stark der Mix das Bild dreht
--
-- Nur A7a beantwortet die Frage „wer liegt nah an seinem Versprechen".
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

SET work_mem = '256MB';
SET max_parallel_workers_per_gather = 4;

-- Mindestmenge je Hersteller. Unter dieser Grenze schwankt der Median so stark,
-- dass eine Rangfolge nur Rauschen abbildet. Die Grenze wird im Bericht genannt.
\set mindest 3000

-- =============================================================================
-- A7a · Reine Verbrenner — der faire Herstellervergleich
-- =============================================================================
DROP TABLE IF EXISTS mart.a7_hersteller_verbrenner;
CREATE TABLE mart.a7_hersteller_verbrenner AS
SELECT coalesce(mh, 'unbekannt')                                              AS hersteller,
       count(*)                                                               AS fahrzeuge,
       count(*) FILTER (WHERE antriebsklasse = 'ICE_BENZIN')                  AS benziner,
       count(*) FILTER (WHERE antriebsklasse = 'ICE_DIESEL')                  AS diesel,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_wltp)::numeric, 2) AS wltp_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_real)::numeric, 2) AS real_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1) AS gap_median_pct,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1) AS gap_p90_pct,
       round(percentile_cont(0.1) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1) AS gap_p10_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY masse_kg)::numeric, 0) AS masse_kg,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY leistung_kw)::numeric, 0) AS leistung_kw
FROM core.realworld
WHERE land = 'DE' AND eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
  AND antriebsklasse IN ('ICE_BENZIN', 'ICE_DIESEL')
GROUP BY coalesce(mh, 'unbekannt')
HAVING count(*) >= :mindest;

CREATE INDEX ix_a7v ON mart.a7_hersteller_verbrenner (gap_median_pct);
COMMENT ON TABLE mart.a7_hersteller_verbrenner IS 'A7a — Realverbrauchsluecke je Hersteller, nur reine Verbrenner, Deutschland. Der methodisch faire Vergleich: gleiche Antriebsart, damit der Antriebsmix das Ergebnis nicht verzerrt.';

\echo ''
\echo '=== A7a · NAH AM VERSPRECHEN — die zehn kleinsten Luecken ================='
\echo '>>> Nur reine Verbrenner. Gleiche Antriebsart, damit der Mix nicht verzerrt.'
SELECT hersteller, fahrzeuge, wltp_l, real_l, gap_median_pct, gap_p90_pct, masse_kg, leistung_kw
FROM mart.a7_hersteller_verbrenner
ORDER BY gap_median_pct ASC LIMIT 10;

\echo ''
\echo '=== A7a · WEIT DANEBEN — die zehn groessten Luecken ======================='
SELECT hersteller, fahrzeuge, wltp_l, real_l, gap_median_pct, gap_p90_pct, masse_kg, leistung_kw
FROM mart.a7_hersteller_verbrenner
ORDER BY gap_median_pct DESC LIMIT 10;

\echo ''
\echo '=== A7a · Vollstaendige Rangliste ========================================'
SELECT rank() OVER (ORDER BY gap_median_pct) AS platz,
       hersteller, fahrzeuge, wltp_l, real_l, gap_median_pct, masse_kg
FROM mart.a7_hersteller_verbrenner
ORDER BY gap_median_pct;

\echo ''
\echo '=== A7a · Spannweite ====================================================='
\echo '>>> Wie gross ist der Abstand zwischen bestem und schlechtestem Hersteller?'
SELECT count(*)                                   AS hersteller,
       min(gap_median_pct)                        AS beste_luecke_pct,
       max(gap_median_pct)                        AS schlechteste_luecke_pct,
       round(max(gap_median_pct) - min(gap_median_pct), 1) AS spannweite_pp,
       round(avg(gap_median_pct), 1)              AS mittel_pct,
       round(stddev_pop(gap_median_pct), 1)       AS streuung_pp
FROM mart.a7_hersteller_verbrenner;

-- =============================================================================
-- A7b · Plug-in-Hybride je Hersteller
--
-- Hier ist die Lücke bei allen dreistellig. Die Frage ist nicht mehr „wer ist
-- nah dran", sondern „wo ist der Abstand am extremsten" — und ob der elektrische
-- Fahranteil das erklärt.
-- =============================================================================
DROP TABLE IF EXISTS mart.a7_hersteller_phev;
CREATE TABLE mart.a7_hersteller_phev AS
SELECT coalesce(mh, 'unbekannt')                                               AS hersteller,
       count(*)                                                                AS fahrzeuge,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_wltp)::numeric, 2)  AS wltp_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY fc_real)::numeric, 2)  AS real_l,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1)  AS gap_median_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY anteil_elektrisch)::numeric, 1) AS e_anteil_pct,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY e_reichweite_km)::numeric, 0) AS e_reichweite_km,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY masse_kg)::numeric, 0)  AS masse_kg
FROM core.realworld
WHERE land = 'DE' AND eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
  AND antriebsklasse = 'PHEV'
GROUP BY coalesce(mh, 'unbekannt')
HAVING count(*) >= 1000;

COMMENT ON TABLE mart.a7_hersteller_phev IS 'A7b — Realverbrauchsluecke je Hersteller, nur Plug-in-Hybride, Deutschland.';

\echo ''
\echo '=== A7b · Plug-in-Hybride je Hersteller =================================='
\echo '>>> e_anteil_pct = tatsaechlich elektrisch gefahrener Anteil. Die WLTP-Regel'
\echo '>>> unterstellt rund 84 Prozent.'
SELECT hersteller, fahrzeuge, wltp_l, real_l, gap_median_pct,
       e_anteil_pct, e_reichweite_km, masse_kg
FROM mart.a7_hersteller_phev
ORDER BY gap_median_pct;

\echo ''
\echo '=== A7b · Erklaert die elektrische Reichweite den Unterschied? ==========='
\echo '>>> Wenn ja, muessten grosse Reichweiten mit kleinen Luecken einhergehen.'
SELECT CASE WHEN e_reichweite_km < 45 THEN 'unter 45 km'
            WHEN e_reichweite_km < 60 THEN '45 bis 60 km'
            ELSE 'ueber 60 km' END                     AS reichweitenklasse,
       count(*)                                        AS hersteller,
       sum(fahrzeuge)                                  AS fahrzeuge,
       round(avg(gap_median_pct), 1)                   AS gap_pct,
       round(avg(e_anteil_pct), 1)                     AS e_anteil_pct
FROM mart.a7_hersteller_phev
WHERE e_reichweite_km IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- =============================================================================
-- A7c · Der Mixeffekt
--
-- Zeigt, warum die naive Rangliste in die Irre führt: Dieselben Hersteller,
-- einmal nur mit Verbrennern gerechnet und einmal über die gesamte Flotte.
-- =============================================================================
DROP TABLE IF EXISTS mart.a7_mixeffekt;
CREATE TABLE mart.a7_mixeffekt AS
WITH gesamt AS (
    SELECT coalesce(mh, 'unbekannt') AS hersteller,
           count(*)                                                            AS fahrzeuge_gesamt,
           round(100.0 * count(*) FILTER (WHERE antriebsklasse = 'PHEV') / count(*), 1) AS phev_anteil_pct,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_pct)::numeric, 1) AS gap_gesamt_pct
    FROM core.realworld
    WHERE land = 'DE' AND eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
    GROUP BY coalesce(mh, 'unbekannt')
    HAVING count(*) >= :mindest
)
SELECT g.hersteller,
       g.fahrzeuge_gesamt,
       g.phev_anteil_pct,
       g.gap_gesamt_pct,
       v.gap_median_pct                                        AS gap_nur_verbrenner_pct,
       round(g.gap_gesamt_pct - v.gap_median_pct, 1)           AS mixeffekt_pp
FROM gesamt g
JOIN mart.a7_hersteller_verbrenner v USING (hersteller);

COMMENT ON TABLE mart.a7_mixeffekt IS 'A7c — Wie stark verzerrt der Antriebsmix die Herstellerrangliste? mixeffekt_pp = Aufschlag auf die Luecke, der allein aus dem PHEV-Anteil stammt.';

\echo ''
\echo '=== A7c · Der Mixeffekt — warum die naive Rangliste taeuscht ============='
\echo '>>> gap_gesamt = ueber die ganze Flotte  ·  gap_nur_verbrenner = fair'
\echo '>>> mixeffekt_pp = Aufschlag allein durch den Plug-in-Hybrid-Anteil.'
SELECT hersteller, fahrzeuge_gesamt, phev_anteil_pct,
       gap_gesamt_pct, gap_nur_verbrenner_pct, mixeffekt_pp
FROM mart.a7_mixeffekt
ORDER BY mixeffekt_pp DESC;

\echo ''
\echo '=== A7c · Kontrolle: haengt der Mixeffekt am PHEV-Anteil? ================'
\echo '>>> Ein hoher Zusammenhang bestaetigt, dass die naive Rangliste den'
\echo '>>> Antriebsmix misst und nicht die Motorentechnik.'
SELECT round(corr(phev_anteil_pct, mixeffekt_pp)::numeric, 3) AS korrelation,
       count(*)                                               AS hersteller
FROM mart.a7_mixeffekt;

ANALYZE mart.a7_hersteller_verbrenner;
ANALYZE mart.a7_hersteller_phev;
ANALYZE mart.a7_mixeffekt;

\echo ''
\echo '>>> Fuer die Folie: A7a ist die Rangliste, die zaehlt. A7c ist die'
\echo '>>> Begruendung, warum man sie so und nicht anders rechnen muss.'
