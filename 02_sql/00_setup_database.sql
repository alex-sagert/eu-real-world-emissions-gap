-- =============================================================================
-- 00_setup_database.sql
-- Papier gegen Straße · Alexander Sagert · 2026
--
-- Läuft gegen die Wartungsdatenbank "postgres", NICHT gegen bd_co2.
--   psql -U postgres -d postgres -f 02_sql\00_setup_database.sql
--
-- CREATE DATABASE darf nicht in einem Transaktionsblock stehen, deshalb ist
-- dieses Skript bewusst von 01_schemas.sql getrennt.
-- =============================================================================

\set ON_ERROR_STOP on

SELECT 'PostgreSQL-Version' AS pruefung, version() AS wert;

-- UTF8 und deterministische Sortierung. C-Collation ist für die
-- Massenverarbeitung deutlich schneller als eine lokalisierte Collation und
-- reicht hier, weil sortierte Ausgabe erst in der Auswertungsschicht entsteht.
CREATE DATABASE bd_co2
    WITH ENCODING     = 'UTF8'
         LC_COLLATE   = 'C'
         LC_CTYPE     = 'C'
         TEMPLATE     = template0
         CONNECTION LIMIT = -1;

COMMENT ON DATABASE bd_co2 IS 'Papier gegen Straße — EEA co2cars (VO 2019/631 Art. 7) und OBFCM-Realverbrauch (Art. 12), Fokusländer DE/FR/IT/ES/NL/NO, Jahrgänge 2021–2025. Stand 08/2026.';
