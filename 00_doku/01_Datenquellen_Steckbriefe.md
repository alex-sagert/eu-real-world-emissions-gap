# Datenquellen — Steckbriefe

Stand 10.08.2026. Alle URLs am selben Tag geprüft.

---

## Q1 · EEA co2cars — Typprüfwerte je Neuzulassung

**Rechtsgrundlage:** VO (EU) 2019/631, Artikel 7
**Inhalt:** Jede einzelne Neuzulassung in EU-27 + Island + Norwegen, Fahrzeugebene.
**Umfang im Projekt:** 37.139.598 Zeilen (DE, FR, IT, ES, NL, NO · 2021–2025)
**Lizenz:** EEA Data Policy, freie Nutzung mit Quellenangabe, DOI-zitierbar

| | |
|---|---|
| Portal | https://www.eea.europa.eu/en/datahub/datahubitem-view/fa8b1229-3db6-495d-b18e-9c9b3267c02b |
| REST-Endpunkt | `https://discodata.eea.europa.eu/sql?query=<T-SQL>&p=1&nrOfHits=<n>` |
| Endpunkt-Hilfe | https://discodata.eea.europa.eu/Help.html |
| Tabellen | `[CO2Emission].[latest].[co2cars_2021Fv24 / 2022Fv26 / 2023Fv28 / 2024Pv29 / 2025Pv31]` |
| Bulk-CSV | **existiert nicht** (siehe Verifikationsprotokoll §6) |

### Feldkatalog

| Feld | Bedeutung | Typ core | Anmerkung |
|---|---|---|---|
| `ID` | Satz-ID, je Jahrgang aufsteigend | bigint | Basis der Keyset-Paginierung |
| `MS` | Mitgliedstaat | char(2) | Filterspalte |
| `Mp` | Herstellergruppe (Pool) | text | Ebene der Flottenzielrechnung → H5 |
| `Mh` | Hersteller (harmonisiert) | text | |
| `Man` | Hersteller (Rechtsname) | text | |
| `MMS` | Herstellername laut Mitgliedstaat | text | oft NULL |
| `TAN` | Typgenehmigungsnummer | text | Join-Kandidat zu OBFCM |
| `T` / `Va` / `Ve` | Typ / Variante / Version | text | zusammen mit TAN eindeutige Fahrzeugvariante |
| `Mk` | Marke | text | |
| `Cn` | Handelsname | text | Grundlage `dim_model` |
| `Ct` / `Cr` | Fahrzeugklasse / -kategorie | text | M1 = Pkw |
| `M (kg)` | Masse in fahrbereitem Zustand | numeric(7,1) | **H4** |
| `Mt` | Prüfmasse WLTP | numeric(7,1) | Grundlage Zielwertformel |
| `Enedc (g/km)` | CO₂ nach NEDC | numeric(6,1) | ab 2021 durchgehend NULL |
| `Ewltp (g/km)` | CO₂ nach WLTP | numeric(6,1) | **Kernmetrik** |
| `W (mm)` | Radstand | numeric | häufig NULL |
| `At1` / `At2 (mm)` | Spurweite vorn/hinten | numeric | häufig NULL |
| `Ft` | Kraftstoffart | text | petrol, diesel, electric, petrol/electric, diesel/electric, lpg, e85, ng, hydrogen, unknown |
| `Fm` | Fuel Mode | char(1) | M mono, B bi, H hybrid, P PHEV, F flex |
| `Ec (cm3)` | Hubraum | int | |
| `Ep (KW)` | Nennleistung | numeric(6,1) | |
| `Z (Wh/km)` | Stromverbrauch | numeric(7,2) | nur elektrifiziert |
| `IT` | Öko-Innovationscode | text | **Leerstring statt NULL** |
| `Ernedc` / `Erwltp (g/km)` | Gutschrift Öko-Innovation | numeric(5,2) | **H5** |
| `Dr` | Zulassungsdatum | date | tagesgenau, Grundlage `dim_date` |
| `Fc` | Verbrauch l/100 km | numeric(5,2) | Laborwert |
| `r` | Anzahl Zulassungen des Satzes | int | in der Stichprobe 1 — **vor der Aggregation prüfen** |
| `Year` | Berichtsjahr | int | Partitionsschlüssel |
| `Status` | F final / P provisional | char(1) | **muss mitgeführt werden** |
| `Version_file` | Dateiversion (v24…v31) | text | Reproduzierbarkeit |
| `Ech`, `RLFI`, `De`, `Vf`, `E`, `Er`, `Zr` | weitere Felder | text | überwiegend NULL, nicht im Scope |

### Fallstricke

- Erste Spalte der Query braucht einen Alias, sonst Fehler 10004.
- Spaltennamen mit Leerzeichen/Klammern in eckige Klammern setzen: `[M (kg)]`.
- `WITH`/CTE ist am Endpunkt gesperrt — Analysen laufen lokal.
- 2024 und 2025 sind provisional.

---

## Q2 · EEA Real-world CO₂ (OBFCM) — Realverbrauch je Fahrzeug

**Rechtsgrundlage:** VO (EU) 2019/631, Artikel 12
**Inhalt:** Lebensdauer-Kraftstoffverbrauch und -Strecke je Fahrzeug aus dem
Bordverbrauchszähler; bei PHEV zusätzlich Strecke und Verbrauch getrennt nach
Charge-Depleting/Charge-Increasing sowie Netzstrom in die Batterie.
**Entscheidend:** Der zugehörige **WLTP-Laborwert liegt im selben Datensatz je Fahrzeug**.
Die VIN-Verknüpfung hat die EEA bereits vorgenommen und anonymisiert — kein Record Linkage.

| | |
|---|---|
| Portal | https://www.eea.europa.eu/en/datahub/datahubitem-view/1c1ffad2-34c3-471b-bd69-dd013cdd7b80 |
| Direktdownload v03 (primär) | https://sdi.eea.europa.eu/datashare/s/N4FtpL8zDMy9pxP/download |
| Direktdownload v01 (Vergleich) | https://sdi.eea.europa.eu/datashare/s/rdowHtqPXRAFDzL/download |
| Metadaten-PDF | https://sdi.eea.europa.eu/catalogue/srv/api/records/7472e340-2766-4461-b83f-d63e2d81edc7/attachments/Real%20world%20emissions%20for%20cars%20and%20vans-Statistical%20metadata_2024.pdf |
| DOI | 10.2909/7472e340-2766-4461-b83f-d63e2d81edc7 |
| Umfang | ~1,5 GB je Share |
| Berichtsjahr / Abdeckung | 2024 / Zulassungen 2021–2023 |
| Lizenz | CC-BY-4.0 |

Es existieren zwei Fassungen desselben Berichtsjahres:
`eea_t_real-world-co2-emission_p_2024_v03_r00` (primär, veröffentlicht 11.07.2025) und
`…_v01_r00` (19.08.2025). Beide werden geladen, die Differenz wird geprüft und dokumentiert.

**Alternative Quelle (JRC, M1, 2021–2023 konsolidiert):**
https://data.jrc.ec.europa.eu/dataset/9528c82b-37fa-4da3-9b6b-b54eaf0ba4ac

---

## Q3 · KBA — Bestand und Neuzulassungen Deutschland

Rolle: unabhängige amtliche Validierungsebene für die deutschen Zulassungszahlen aus Q1.
Format XLSX, aggregiert.
https://www.kba.de/DE/Statistik/Fahrzeuge/Downloadbereich/Downloadbereich_Fahrzeuge_node.html

---

## Q4 · SMARD — deutscher Strommix

Rolle: Well-to-Wheel-Gegencheck zu H2. Der OBFCM-Wert eines Elektroautos ist per Definition
0 g/km, weil nur der Auspuff zählt. Ohne Strommix ist der Vergleich Verbrenner ↔ BEV nicht
fair.
15-Minuten-Zeitreihen der Erzeugung je Energieträger → CO₂-Intensität in g/kWh.

- https://www.smard.de/en/datennutzung
- API: https://smard.api.bund.dev/
- Alternativ: Fraunhofer ISE energy-charts

---

## Kontext zum Stand der Forschung

Nicht als Datenquelle, sondern zur Einordnung und als Referenz für den Plausibilitätscheck
der eigenen Ergebnisse:

- Transport & Environment (09/2025): reale PHEV-Lücke Faktor ~5, Basis >800.000 Fahrzeuge
  der Jahrgänge 2021–2023 —
  https://uploads.transportenvironment.org/production/files/2025_09_TE_briefing_PHEV_gap_growing.pdf
- Ariadne (10/2025): Realverbrauch von PHEV in Europa —
  https://ariadneprojekt.de/media/2025/11/Ariadne-Analysis_PHEV_October2025.pdf
- EU-Kommission zu Real-world CO₂ —
  https://climate.ec.europa.eu/news-other-reads/news/publication-real-world-co2-emissions-and-fuel-consumption-cars-and-vans-collected-2022-2024-07-26_en
- Utility Factor: Absenkung von 84 % auf rund 34 % bis 2027/28
