-- =============================================================================
-- 15_qualitaet_raw.sql   ·   läuft gegen bd_co2, nach dem Staging-Load
--   psql -U postgres -d bd_co2 -f 02_sql\15_qualitaet_raw.sql
--
-- Datenqualitätsanalyse VOR der Typisierung. Befunde landen in meta.dq_befund
-- und werden im NvS berichtet — auch die unangenehmen. Es wird hier nichts
-- gefiltert, nur gemessen.
-- =============================================================================

\set ON_ERROR_STOP on

-- Sammelsicht über alle Jahrgänge
DROP VIEW IF EXISTS raw.v_co2cars_alle;
CREATE VIEW raw.v_co2cars_alle AS
    SELECT * FROM raw.co2cars_2021
    UNION ALL SELECT * FROM raw.co2cars_2022
    UNION ALL SELECT * FROM raw.co2cars_2023
    UNION ALL SELECT * FROM raw.co2cars_2024
    UNION ALL SELECT * FROM raw.co2cars_2025;

TRUNCATE meta.dq_befund;

-- -----------------------------------------------------------------------------
-- P1 — Zeilenzahl je Jahr und Land gegen die am 10.08.2026 an der Quelle
--      gezählten Sollwerte (00_doku/02_Verifikationsprotokoll.md, §2)
-- -----------------------------------------------------------------------------
WITH soll(jahr, ms, n) AS (
    VALUES
      ('2021','DE',2530135),('2021','FR',1777879),('2021','IT',1456503),
      ('2021','ES', 908449),('2021','NL', 315471),('2021','NO', 175852),
      ('2022','DE',2571033),('2022','FR',1638878),('2022','IT',1312635),
      ('2022','ES', 851105),('2022','NL', 305890),('2022','NO', 174107),
      ('2023','DE',2765152),('2023','FR',1889602),('2023','IT',1564369),
      ('2023','ES', 974231),('2023','NL', 364769),('2023','NO', 126932),
      ('2024','DE',2728237),('2024','FR',1820622),('2024','IT',1555384),
      ('2024','ES',1055935),('2024','NL', 377394),('2024','NO', 128602),
      ('2025','DE',2772367),('2025','FR',1731737),('2025','IT',1505912),
      ('2025','ES',1196466),('2025','NL', 384556),('2025','NO', 179394)
), ist AS (
    SELECT jahr, ms, count(*) AS n FROM raw.v_co2cars_alle GROUP BY jahr, ms
)
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'raw',
       'co2cars_' || s.jahr,
       s.ms,
       'Zeilenzahl gegen Quellzählung 10.08.2026',
       coalesce(i.n, 0) - s.n,
       'Zeilen Differenz',
       0,
       CASE WHEN coalesce(i.n,0) = s.n THEN 'ok'
            WHEN abs(coalesce(i.n,0) - s.n) < s.n * 0.001 THEN 'auffaellig'
            ELSE 'kritisch' END,
       format('Soll %s, Ist %s', s.n, coalesce(i.n, 0))
FROM soll s LEFT JOIN ist i ON i.jahr = s.jahr AND i.ms = s.ms;

-- -----------------------------------------------------------------------------
-- P2 — NULL- und Leerstring-Quote je relevanter Spalte und Jahr
--      Wichtig: die EEA liefert bei IT einen Leerstring, kein NULL.
-- -----------------------------------------------------------------------------
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'raw', 'co2cars_' || jahr, spalte, 'Anteil ohne Wert (NULL oder Leerstring)',
       round(100.0 * fehlend / gesamt, 2), '%', NULL,
       CASE WHEN fehlend = 0 THEN 'ok'
            WHEN fehlend < gesamt THEN 'auffaellig'
            ELSE 'kritisch' END,
       format('%s von %s Sätzen ohne Wert', fehlend, gesamt)
FROM (
    SELECT jahr, s.spalte,
           count(*)                                              AS gesamt,
           count(*) FILTER (WHERE s.wert IS NULL OR s.wert = '') AS fehlend
    FROM raw.v_co2cars_alle t
    CROSS JOIN LATERAL (VALUES
        ('mp', t.mp), ('mk', t.mk), ('cn', t.cn), ('tan', t.tan),
        ('m_kg', t.m_kg), ('mt', t.mt), ('ewltp', t.ewltp), ('enedc', t.enedc),
        ('ft', t.ft), ('fm', t.fm), ('ec_cm3', t.ec_cm3), ('ep_kw', t.ep_kw),
        ('z_whkm', t.z_whkm), ('it_code', t.it_code), ('erwltp', t.erwltp),
        ('dr', t.dr), ('fc', t.fc), ('w_mm', t.w_mm)
    ) AS s(spalte, wert)
    GROUP BY jahr, s.spalte
) q;

-- -----------------------------------------------------------------------------
-- P3 — Werte, die sich nicht in Zahlen wandeln lassen
--      Wenn hier etwas auftaucht, war die TEXT-Staging-Schicht die richtige
--      Entscheidung: bei direkter Typisierung wäre der Ladelauf abgebrochen.
-- -----------------------------------------------------------------------------
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'raw', 'co2cars_' || jahr, spalte, 'nicht in numeric wandelbar', anzahl, 'Sätze', 0,
       CASE WHEN anzahl = 0 THEN 'ok' ELSE 'kritisch' END,
       'Beispielwert: ' || coalesce(beispiel, '—')
FROM (
    SELECT jahr, s.spalte,
           count(*) FILTER (WHERE s.wert !~ '^-?[0-9]+([.,][0-9]+)?([eE][-+]?[0-9]+)?$'
                              AND s.wert IS NOT NULL AND s.wert <> '') AS anzahl,
           min(s.wert) FILTER (WHERE s.wert !~ '^-?[0-9]+([.,][0-9]+)?([eE][-+]?[0-9]+)?$'
                                 AND s.wert IS NOT NULL AND s.wert <> '') AS beispiel
    FROM raw.v_co2cars_alle t
    CROSS JOIN LATERAL (VALUES
        ('m_kg', t.m_kg), ('mt', t.mt), ('ewltp', t.ewltp), ('enedc', t.enedc),
        ('ec_cm3', t.ec_cm3), ('ep_kw', t.ep_kw), ('z_whkm', t.z_whkm),
        ('erwltp', t.erwltp), ('fc', t.fc), ('r_count', t.r_count)
    ) AS s(spalte, wert)
    GROUP BY jahr, s.spalte
) q;

-- -----------------------------------------------------------------------------
-- P4 — Wertebereiche: physikalisch unmögliche oder unplausible Werte
-- -----------------------------------------------------------------------------
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'raw', 'co2cars_alle', spalte, pruefung, anzahl, 'Sätze', 0,
       CASE WHEN anzahl = 0 THEN 'ok' ELSE 'auffaellig' END, kommentar
FROM (
    SELECT 'm_kg' AS spalte, 'Masse < 500 kg oder > 3500 kg' AS pruefung,
           count(*) AS anzahl,
           'Pkw außerhalb des plausiblen Bereichs; M1 ist auf 3500 kg begrenzt' AS kommentar
    FROM raw.v_co2cars_alle
    WHERE m_kg ~ '^[0-9.]+$' AND (m_kg::numeric < 500 OR m_kg::numeric > 3500)
    UNION ALL
    SELECT 'ewltp', 'CO2 WLTP > 500 g/km', count(*),
           'Oberhalb dessen, was ein M1-Fahrzeug erreicht'
    FROM raw.v_co2cars_alle
    WHERE ewltp ~ '^[0-9.]+$' AND ewltp::numeric > 500
    UNION ALL
    SELECT 'ewltp', 'CO2 WLTP = 0 bei Verbrenner', count(*),
           'Nur bei electric/hydrogen zulässig'
    FROM raw.v_co2cars_alle
    WHERE ewltp ~ '^[0-9.]+$' AND ewltp::numeric = 0
      AND ft NOT IN ('electric', 'hydrogen')
    UNION ALL
    SELECT 'ewltp', 'CO2 WLTP > 0 bei electric', count(*),
           'Ein reines BEV darf im WLTP keinen Auspuffausstoß haben'
    FROM raw.v_co2cars_alle
    WHERE ewltp ~ '^[0-9.]+$' AND ewltp::numeric > 0 AND ft = 'electric'
    UNION ALL
    SELECT 'ep_kw', 'Leistung < 10 kW oder > 800 kW', count(*),
           'Außerhalb des Pkw-Bereichs'
    FROM raw.v_co2cars_alle
    WHERE ep_kw ~ '^[0-9.]+$' AND (ep_kw::numeric < 10 OR ep_kw::numeric > 800)
    UNION ALL
    SELECT 'dr', 'Zulassungsdatum außerhalb des Berichtsjahres', count(*),
           'Dr muss im Jahr liegen, das die Tabelle abdeckt'
    FROM raw.v_co2cars_alle
    WHERE dr ~ '^\d{4}-\d{2}-\d{2}' AND left(dr, 4) <> jahr
    UNION ALL
    SELECT 'r_count', 'r_count <> 1', count(*),
           'Falls die EEA Sätze aggregiert liefert, muss beim Zählen gewichtet werden'
    FROM raw.v_co2cars_alle
    WHERE r_count IS NOT NULL AND r_count <> '' AND r_count <> '1'
) q;

-- -----------------------------------------------------------------------------
-- P5 — Duplikate: identischer Satz, verschiedene ID
-- -----------------------------------------------------------------------------
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, schwelle, bewertung, kommentar)
SELECT 'raw', 'co2cars_alle', NULL,
       'Fachlich identische Sätze (ohne ID) mit mehr als einem Vorkommen',
       count(*), 'Gruppen', NULL,
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'auffaellig' END,
       'Erwartbar: gleiche Fahrzeugvariante, gleicher Tag, gleiches Land. Keine Bereinigung — jede Zulassung ist ein eigener Vorgang.'
FROM (
    SELECT ms, tan, typ, va, ve, dr, ewltp, m_kg
    FROM raw.v_co2cars_alle
    GROUP BY 1,2,3,4,5,6,7,8
    HAVING count(*) > 1
) d;

-- -----------------------------------------------------------------------------
-- P6 — Wertelisten der kategorialen Spalten (Vollständigkeit prüfen)
-- -----------------------------------------------------------------------------
INSERT INTO meta.dq_befund (schicht, objekt, spalte, pruefung, ergebnis, einheit, bewertung, kommentar)
SELECT 'raw', 'co2cars_alle', spalte, 'Anzahl unterschiedlicher Ausprägungen',
       n_distinct, 'Werte', 'ok', beispiele
FROM (
    SELECT 'ft' AS spalte, count(DISTINCT ft) AS n_distinct,
           string_agg(DISTINCT ft, ', ' ORDER BY ft) AS beispiele FROM raw.v_co2cars_alle
    UNION ALL
    SELECT 'fm', count(DISTINCT fm), string_agg(DISTINCT fm, ', ' ORDER BY fm) FROM raw.v_co2cars_alle
    UNION ALL
    SELECT 'ct', count(DISTINCT ct), string_agg(DISTINCT ct, ', ' ORDER BY ct) FROM raw.v_co2cars_alle
    UNION ALL
    SELECT 'status', count(DISTINCT status), string_agg(DISTINCT status, ', ' ORDER BY status) FROM raw.v_co2cars_alle
    UNION ALL
    SELECT 'version_file', count(DISTINCT version_file),
           string_agg(DISTINCT version_file, ', ' ORDER BY version_file) FROM raw.v_co2cars_alle
) q;

-- =============================================================================
-- Auswertung
-- =============================================================================
\echo ''
\echo '--- Befunde nach Bewertung -------------------------------------------------'
SELECT bewertung, count(*) AS anzahl
FROM meta.dq_befund GROUP BY bewertung ORDER BY 1;

\echo ''
\echo '--- Kritische Befunde ------------------------------------------------------'
SELECT objekt, spalte, pruefung, ergebnis, einheit, kommentar
FROM meta.dq_befund WHERE bewertung = 'kritisch' ORDER BY objekt, spalte;

\echo ''
\echo '--- Fehlende Werte, die 90 % übersteigen ----------------------------------'
SELECT objekt, spalte, ergebnis AS prozent_fehlend
FROM meta.dq_befund
WHERE pruefung LIKE 'Anteil ohne Wert%' AND ergebnis > 90
ORDER BY objekt, spalte;
