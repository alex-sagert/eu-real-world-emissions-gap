-- =============================================================================
-- 43_knime_trainingsbasis.sql   ·   läuft gegen bd_co2
--   .\03_skripte\10_run_sql.ps1 -File .\02_sql\43_knime_trainingsbasis.sql -OutFile .\00_doku\43_knime_basis_ausgabe.txt
--
-- Belegt, wie viele Sätze die Filter der KNIME-Trainingsabfragen kosten.
--
-- Wozu: Der Numeric Scorer brach am 12.08.2026 ab, weil einzelne Merkmale leer
-- waren und der Regression Predictor für solche Zeilen keine Vorhersage liefert.
-- Die Lösung war, diese Zeilen in SQL auszuschließen statt Werte zu erfinden.
-- Ein Ausschluss ist aber nur dann zulässig, wenn beziffert wird, was er kostet
-- und ob er die Stichprobe verzerrt. Genau das steht hier — und gehört so ins
-- NvS, nicht als Nebensatz.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

SET work_mem = '256MB';

\echo ''
\echo '=== Was kosten die Vollstaendigkeitsfilter? (alle Antriebe) ==============='
SELECT count(*)                                                          AS grundgesamtheit,
       count(*) FILTER (WHERE gap_pct BETWEEN -50 AND 900)               AS nach_ausreissergrenze,
       count(*) FILTER (WHERE gap_pct BETWEEN -50 AND 900
                          AND masse_kg IS NOT NULL
                          AND leistung_kw IS NOT NULL
                          AND fc_wltp IS NOT NULL
                          AND co2_wltp IS NOT NULL
                          AND dist_total_km IS NOT NULL)                 AS trainingsbasis,
       round(100.0 * count(*) FILTER (WHERE gap_pct BETWEEN -50 AND 900
                          AND masse_kg IS NOT NULL
                          AND leistung_kw IS NOT NULL
                          AND fc_wltp IS NOT NULL
                          AND co2_wltp IS NOT NULL
                          AND dist_total_km IS NOT NULL) / nullif(count(*), 0), 2) AS anteil_prozent
FROM core.realworld
WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL;

\echo ''
\echo '=== Welche Spalte kostet wie viel? ======================================='
\echo '>>> Je Merkmal die Zahl der Saetze, die allein daran scheitern.'
SELECT 'masse_kg'      AS merkmal, count(*) FILTER (WHERE masse_kg IS NULL)      AS fehlend FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
UNION ALL SELECT 'leistung_kw',    count(*) FILTER (WHERE leistung_kw IS NULL)   FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
UNION ALL SELECT 'fc_wltp',        count(*) FILTER (WHERE fc_wltp IS NULL)       FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
UNION ALL SELECT 'co2_wltp',       count(*) FILTER (WHERE co2_wltp IS NULL)      FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
UNION ALL SELECT 'dist_total_km',  count(*) FILTER (WHERE dist_total_km IS NULL) FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
UNION ALL SELECT 'hubraum_cm3 (auf 0 gesetzt)',     count(*) FILTER (WHERE hubraum_cm3 IS NULL)     FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
UNION ALL SELECT 'e_reichweite_km (auf 0 gesetzt)', count(*) FILTER (WHERE e_reichweite_km IS NULL) FROM core.realworld WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
ORDER BY fehlend DESC;

\echo ''
\echo '=== Verzerrt der Ausschluss die Stichprobe? =============================='
\echo '>>> Antriebsmix vor und nach dem Filter. Grosse Verschiebungen waeren'
\echo '>>> ein Grund, den Filter zu verwerfen statt ihn nur zu dokumentieren.'
WITH vorher AS (
    SELECT antriebsklasse, count(*) AS n
    FROM core.realworld
    WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
      AND gap_pct BETWEEN -50 AND 900
    GROUP BY antriebsklasse
), nachher AS (
    SELECT antriebsklasse, count(*) AS n
    FROM core.realworld
    WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
      AND gap_pct BETWEEN -50 AND 900
      AND masse_kg IS NOT NULL AND leistung_kw IS NOT NULL
      AND fc_wltp IS NOT NULL AND co2_wltp IS NOT NULL
      AND dist_total_km IS NOT NULL
    GROUP BY antriebsklasse
)
SELECT v.antriebsklasse,
       v.n                                                               AS vorher,
       coalesce(n.n, 0)                                                  AS nachher,
       round(100.0 * v.n / sum(v.n) OVER (), 2)                          AS anteil_vorher_pct,
       round(100.0 * coalesce(n.n, 0) / nullif(sum(coalesce(n.n, 0)) OVER (), 0), 2) AS anteil_nachher_pct
FROM vorher v LEFT JOIN nachher n USING (antriebsklasse)
ORDER BY v.n DESC;

\echo ''
\echo '=== Dasselbe fuer die PHEV-Teilmenge ====================================='
\echo '>>> Hier wiegt der Filter schwerer: anteil_elektrisch und grid_kwh werden'
\echo '>>> VERLANGT, nicht ersetzt. Sie sind die Erklaergroessen der Luecke -'
\echo '>>> ein Ersatzwert wuerde genau die Frage beantworten, um die es geht.'
SELECT count(*)                                                          AS phev_gesamt,
       count(*) FILTER (WHERE gap_pct BETWEEN 0 AND 2000)                AS nach_ausreissergrenze,
       count(*) FILTER (WHERE anteil_elektrisch IS NULL)                 AS ohne_e_anteil,
       count(*) FILTER (WHERE grid_kwh IS NULL)                          AS ohne_netzstrom,
       count(*) FILTER (WHERE gap_pct BETWEEN 0 AND 2000
                          AND masse_kg IS NOT NULL AND leistung_kw IS NOT NULL
                          AND fc_wltp IS NOT NULL AND co2_wltp IS NOT NULL
                          AND dist_total_km IS NOT NULL
                          AND anteil_elektrisch IS NOT NULL
                          AND grid_kwh IS NOT NULL)                      AS trainingsbasis
FROM core.realworld
WHERE eea_verwendbar AND hat_mindestlauf AND gap_pct IS NOT NULL
  AND antriebsklasse = 'PHEV';

\echo ''
\echo '>>> Diese Zahlen gehoeren in das Kapitel Datenaufbereitung des NvS.'
