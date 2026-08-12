# Datenlandkarte

Wo liegt was, was bedeutet jede Variable, und wie wird daraus das Sternschema.
Alle Verteilungen aus dem Jahrgang **2025** (`co2cars_2025Pv31`, 10.833.597 Zeilen,
EU-27 + IS + NO), abgefragt am 10.08.2026.

---

## 1 · Wo sehe ich die Daten?

Es gibt drei Orte, und sie haben unterschiedliche Zwecke.

| Ort | Was liegt dort | Womit ansehen | Wofür |
|---|---|---|---|
| `01_daten\referenz\` | Stichprobe (500 Zeilen), Verteilungen, Nullquoten, Kreuztabellen | **Excel** — Semikolon-getrennt, öffnet sich ohne Importdialog | Variablen verstehen, Werte prüfen |
| `01_daten\raw\` | die vollen CSVs, `co2cars_2025.csv` allein ~7,8 Mio. Zeilen | **nicht mit Excel** | Input für den `COPY`-Load |
| PostgreSQL `bd_co2` | alle Schichten `raw` → `core` → `star` → `mart` | **pgAdmin 4** | die eigentliche Arbeit |

> ⚠ **Excel hat ein hartes Limit von 1.048.576 Zeilen.** `co2cars_2025.csv` hat rund
> 7,8 Mio. Zeilen. Excel öffnet die Datei, schneidet sie stillschweigend ab und zeigt dir
> ein falsches Bild. Deshalb ist das Stichproben-Skript da:
> `.\03_skripte\04_stichprobe.ps1` schreibt echte Auszüge in Excel-tauglicher Größe.

**In pgAdmin die Daten ansehen** (nach dem Load):

```sql
-- 20 echte Zeilen
SELECT * FROM raw.co2cars_2025 LIMIT 20;

-- Wie viele Zeilen sind drin?
SELECT count(*) FROM raw.co2cars_2025;

-- Was steht in einer Spalte an Werten?
SELECT ft, fm, count(*) AS n
FROM raw.co2cars_2025
GROUP BY ft, fm ORDER BY n DESC;
```

---

## 2 · Die Quellspalten im Einzelnen

Beispielzeile aus der Quelle (Hyundai i20, DE, Benzin, 2025):

```json
{"ID":176215821,"MS":"DE","Mp":"HYUNDAI MOTOR EUROPE","Mh":"HYUNDAI TURKIYE",
 "Man":"HYUNDAI MOTOR TURKIYE OTOMOTIV AS","TAN":"E5*2007/46*0121*06",
 "T":"BC3","Va":"B5P51","Ve":"M62CZ1","Mk":"HYUNDAI","Cn":"I20","Ct":"M1",
 "M (kg)":1140,"Mt":1237,"Enedc (g/km)":null,"Ewltp (g/km)":119,
 "W (mm)":null,"Ft":"petrol","Fm":"M","Ec (cm3)":998,"Ep (KW)":74,
 "Z (Wh/km)":null,"IT":"","Erwltp (g/km)":null,"Dr":"2025-08-13","Fc":5.2,
 "R":1,"Year":2025,"Status":"P","Version_file":"v31"}
```

### 2.1 Identität und Herkunft

| Spalte | Bedeutung | Beispiel | Belegt | Ziel im Modell |
|---|---|---|---|---|
| `ID` | Satz-ID, je Jahrgang aufsteigend | 176215821 | 100 % | `core.registration.src_id` — Basis der Keyset-Paginierung beim Download |
| `MS` | Mitgliedstaat der Zulassung | `DE` | 100 % | `dim_country` |
| `Year` | Berichtsjahr | 2025 | 100 % | Partitionsschlüssel `fact_registration` |
| `Dr` | **Zulassungsdatum, tagesgenau** | `2025-08-13` | hoch | `dim_date` |
| `Status` | `F` final / `P` provisional | `P` | 100 % | `fact_registration.data_status` — **muss mitgeführt werden** |
| `Version_file` | Dateiversion der EEA | `v31` | 100 % | `fact_registration.source_version` |
| `R` | Anzahl Zulassungen je Satz | 1 | **durchgehend 1** | wird **nicht** gebraucht — `COUNT(*)` ist korrekt |

### 2.2 Hersteller — drei Ebenen, und das ist Absicht

| Spalte | Ebene | Beispiel | Wofür |
|---|---|---|---|
| `Mp` | **Pool** | `HYUNDAI MOTOR EUROPE` | **H5** — Abrechnungsebene der EU, **nur bei 38,4 % gefüllt** |
| `Mh` | Hersteller, harmonisiert | `HYUNDAI TURKIYE` | Rückfallebene, immer gefüllt |
| `Man` | Hersteller, Rechtsname | `HYUNDAI MOTOR TURKIYE OTOMOTIV AS` | Rohform, uneinheitlich geschrieben |
| `MMS` | Name laut Mitgliedstaat | **0 % gefüllt in 2025** | nicht verwendbar |

> ⚠ **Falle:** `COUNT(Mp)` meldet 100 % Belegung — aber **6.677.964 Sätze (61,64 %)
> enthalten einen Leerstring**, kein NULL. Dieselbe Falle wie bei `IT`.

Ein Pool entsteht nur, wenn Hersteller ihre CO₂-Bilanz freiwillig gemeinsam abrechnen.
Wer allein antritt, hat kein `Mp`. Die **Pools 2025**:

| Pool | Zulassungen | Anteil |
|---|---:|---:|
| *(kein Pool — Hersteller rechnet allein ab)* | 6.677.964 | 61,64 % |
| TESLA | 1.711.929 | 15,80 % |
| MERCEDES-BENZ, VOLVO CARS, POLESTAR AND SMART | 861.580 | 7,95 % |
| BMW | 761.099 | 7,03 % |
| HYUNDAI MOTOR EUROPE | 425.493 | 3,93 % |
| NISSAN-BYD | 328.460 | 3,03 % |
| KG MOBILITY XPENG | 40.899 | 0,38 % |
| MAZDA | 26.173 | 0,24 % |

Der Tesla-Pool mit 15,8 % ist der interessanteste Fund: Tesla verkauft in der EU selbst
weit weniger — der Pool enthält also Hersteller, die sich Teslas Nullemissionen anrechnen
lassen. **Das ist H5 in einer einzigen Zeile.** Welche Hersteller genau, klärt der Blick auf
`Mh` innerhalb des Pools nach dem Load.

**Konsequenz für das Modell:** `dim_manufacturer` bekommt zwei abgeleitete Spalten —
`hersteller_gruppe = coalesce(mp_pool, mh_name, man_name)` als tatsächliche
Abrechnungseinheit und `ist_gepoolt` als direkten Test für H5.

### 2.3 Modell und Typgenehmigung

| Spalte | Bedeutung | Beispiel | Anmerkung |
|---|---|---|---|
| `Mk` | Marke | `HYUNDAI` | schreibweise-uneinheitlich → Normalisierung in `core` |
| `Cn` | Handelsname | `I20` | Grundlage `dim_model`; ebenfalls uneinheitlich (`I20`, `i20`, `i 20`) |
| `TAN` | Typgenehmigungsnummer | `E5*2007/46*0121*06` | **Join-Kandidat zu OBFCM** |
| `T` / `Va` / `Ve` | Typ / Variante / Version | `BC3` / `B5P51` / `M62CZ1` | zusammen mit `TAN` die eindeutige Fahrzeugvariante |
| `Ct` | Fahrzeugklasse | `M1` | siehe unten — **Filterspalte** |
| `Cr` | Fahrzeugkategorie | `M1` | redundant zu `Ct` |

**Verteilung `Ct` (2025):**

| Wert | n | Anteil | Entscheidung |
|---|---:|---:|---|
| M1 | 10.797.713 | 99,668 % | behalten |
| M1G | 35.193 | 0,325 % | behalten (Pkw mit Geländeeigenschaften) |
| N1 | 503 | 0,005 % | **ausschließen** — leichtes Nutzfahrzeug |
| N2 | 3 | — | **ausschließen** |
| M2 | 1 | — | **ausschließen** (Bus) |
| *(leer)* | 184 | 0,002 % | **ausschließen** — Klasse nicht gemeldet |

→ Filter `Ct IN ('M1','M1G')`, **691 Zeilen fallen weg**. Zahl wird protokolliert.

### 2.4 Antrieb — `Ft` und `Fm`, die wichtigsten zwei Spalten

**`Ft` (Kraftstoffart), 2025:**

| `Ft` | n | Anteil |
|---|---:|---:|
| petrol | 6.075.402 | 56,08 % |
| electric | 2.055.863 | 18,98 % |
| diesel | 1.279.640 | 11,81 % |
| petrol/electric | 1.009.882 | 9,32 % |
| lpg | 352.268 | 3,25 % |
| diesel/electric | 47.590 | 0,44 % |
| e85 | 12.384 | 0,11 % |
| hydrogen | 451 | 0,004 % |
| ng | 108 | 0,001 % |
| unknown | 9 | — |

**`Fm` (Fuel Mode), 2025:**

| `Fm` | Bedeutung | n | Anteil |
|---|---|---:|---:|
| M | mono-fuel — ein Kraftstoff, kein Elektroantrieb | 3.658.511 | 33,77 % |
| **H** | **Hybrid, nicht extern ladbar** (Mild-/Vollhybrid) | **3.707.121** | **34,22 %** |
| E | rein elektrisch | 2.055.863 | 18,98 % |
| P | Plug-in-Hybrid | 1.057.549 | 9,76 % |
| B | bi-fuel (z. B. Benzin + LPG) | 353.860 | 3,27 % |
| F | flex-fuel (E85) | 684 | 0,01 % |
| UNKNOWN | — | 9 | — |

#### Warum beide Spalten gebraucht werden

`Ft = 'petrol'` sind 6,08 Mio. Fahrzeuge. Darin stecken aber **3,7 Mio. Hybride**, die
`Fm = 'H'` tragen — Autos mit Elektromotor, aber ohne Ladestecker.

H2 lautet: *„Ein moderner Diesel oder Benziner ist real ehrlicher als ein PHEV."*
Würde „Benziner" als `Ft = 'petrol'` definiert, wären zu einem Drittel Hybride im Vergleich —
die Hypothese würde etwas anderes messen, als sie behauptet.

**Konsistenzprüfungen zwischen `Ft` und `Fm`:**

| Prüfung | erwartet | ist | Differenz |
|---|---:|---:|---:|
| `Fm='E'` ↔ `Ft='electric'` | 2.055.863 | 2.055.863 | **0 ✅** |
| `Fm='P'` ↔ `Ft ∈ {petrol/electric, diesel/electric}` | 1.057.472 | 1.057.549 | +77 |
| `Fm='F'` ↔ `Ft='e85'` | 12.384 | 684 | **−11.700 ⚠** |

Nur 684 von 12.384 E85-Fahrzeugen sind als flex-fuel gekennzeichnet. `Ft` und `Fm` sind also
weder redundant noch widerspruchsfrei. **Für die Antriebsklasse führt `Fm`**, weil sie die
Ladefähigkeit beschreibt — und genau darum dreht sich die Realverbrauchslücke.

#### Die Kreuztabelle `Ft` × `Fm` (2025) — hier steht H2 schon halb drin

Quelle: `01_daten\referenz\kreuztabelle_ft_fm_2025.csv`

| `Ft` | `Fm` | Fahrzeuge | Anteil | ⌀ CO₂ WLTP | ⌀ Masse |
|---|---|---:|---:|---:|---:|
| petrol | **H** | 3.318.073 | 30,63 % | 120,9 | 1465 kg |
| petrol | **M** | 2.755.601 | 25,44 % | **136,6** | 1315 kg |
| electric | E | 2.055.863 | 18,98 % | 0,0 | 1970 kg |
| petrol/electric | **P** | 1.009.870 | 9,32 % | **31,8** | 1981 kg |
| diesel | **M** | 902.233 | 8,33 % | **150,1** | 1712 kg |
| diesel | H | 377.341 | 3,48 % | 155,9 | 1983 kg |
| lpg | B | 352.153 | 3,25 % | 119,8 | 1283 kg |
| diesel/electric | P | 47.590 | 0,44 % | 36,3 | 2386 kg |
| e85 | H | 11.705 | 0,11 % | 123,9 | 1682 kg |
| petrol | B | 1.705 | 0,02 % | 136,2 | 1300 kg |
| e85 | F | 679 | 0,01 % | 208,2 | 1848 kg |
| hydrogen | M | 451 | 0,004 % | 0,0 | 1993 kg |
| *(11 weitere Kombinationen mit < 500 Fahrzeugen)* | | 316 | — | | |

**Drei Dinge, die hier sichtbar werden:**

1. **Der PHEV steht auf dem Papier bei 31,8 g/km, der reine Benziner bei 136,6.**
   Faktor 4,3 zugunsten des PHEV — offiziell. Beziffert Transport & Environment die reale
   PHEV-Lücke auf Faktor ~5, landet der PHEV real bei rund 160 g/km und damit **über** dem
   reinen Benziner. Genau diese Umkehr behauptet H2. Beweisen kann sie nur der
   OBFCM-Datensatz — aber die Ausgangslage steht.
2. **Der Diesel-Hybrid stößt mehr aus als der reine Diesel** (155,9 gegen 150,1 g/km).
   Kontraintuitiv, bis man auf die Masse sieht: 1983 gegen 1712 kg. Hybridisierung landet
   im Diesel fast nur in schweren SUVs und Oberklassewagen. Das ist H4 im Kleinen.
3. **Der PHEV ist mit 1981 kg schwerer als das durchschnittliche BEV (1970 kg)** — er
   schleppt zwei komplette Antriebsstränge mit. Ein Argument, das im NvS in die Diskussion
   gehört.

Die E85-Diskrepanz löst sich hier ebenfalls auf: 11.705 der 12.384 E85-Fahrzeuge tragen
`Fm = 'H'`, sind also Hybride — nur 679 sind als flex-fuel gemeldet.

### 2.5 Emissionen, Verbrauch, Masse

Gemessene Belegung im Jahrgang 2025 (`nullquoten_2025.csv`), Wertebereiche aus
`wertebereiche_2025.csv`:

| Spalte | Bedeutung | Belegt | Min – Max | Mittel | Verwendung |
|---|---|---:|---|---:|---|
| `M (kg)` | Masse fahrbereit | 99,997 % | 393 – **4638** | 1608 | **H4**, A6 |
| `Ewltp (g/km)` | **CO₂ nach WLTP** | 99,940 % | 0 – 500 | 96,88 | **Kernmetrik**, A2–A6 |
| `Mt` | Prüfmasse WLTP | 97,230 % | 511 – 4308 | 1716 | Zielwertformel A3 |
| `Ep (KW)` | Nennleistung | 95,761 % | **8** – 1177 | 120,2 | Feature KNIME |
| `Ec (cm3)` | Hubraum | 81,019 % | 658 – 7993 | 1550 | Feature; fehlt bei BEV |
| `Fc` | Verbrauch im Labor | 78,632 % | 0,1 – 21,8 | 5,19 | Gegenprobe zu `Ewltp` |
| `Erwltp (g/km)` | Öko-Gutschrift | 51,593 % | 0,5 – 6,4 | 1,50 | **H5** |
| `Z (Wh/km)` | **Stromverbrauch** | 27,214 % | 11 – 570 | 173,4 | **Well-to-Wheel mit SMARD** |
| `Enedc (g/km)` | CO₂ nach NEDC | **0 %** | — | — | in 2025 leer → nur Zeitreihe vor 2021 |
| `Ernedc (g/km)` | Gutschrift NEDC | **0 %** | — | — | **unbrauchbar** |
| `W (mm)`, `At1 (mm)` | Radstand, Spurweite | **0 %** | — | — | **unbrauchbar** |
| `MMS` | Herstellername des MS | **0 %** | — | — | **unbrauchbar** |

Vier Spalten sind in 2025 **vollständig leer** — `Enedc`, `Ernedc`, `W (mm)`, `At1 (mm)`,
`MMS`. Sie werden zwar geladen (Staging ist 1:1), fallen aber aus jeder Analyse heraus.
Das ist eine dokumentierte Feststellung, keine Annahme.

Zwei Wertebereiche verletzen die Plausibilität und werden von `15_qualitaet_raw.sql` (P4)
gezählt: **Masse bis 4638 kg** liegt über der M1-Grenze von 3500 kg, **Leistung ab 8 kW**
unter der Pkw-Untergrenze.

**Befund zu `Z (Wh/km)`:** Elektrifizierte Fahrzeuge 2025 sind
2.055.863 + 1.009.882 + 47.590 = **3.113.335**. Belegt ist der Stromverbrauch aber nur bei
2.948.208 → **165.127 Fahrzeuge (5,3 %) ohne Wert.** Der Well-to-Wheel-Vergleich läuft
deshalb auf einer um 5,3 % reduzierten Grundgesamtheit. Wird offengelegt, nicht imputiert.

### 2.6 Öko-Innovationen — `IT` und `Erwltp`

| `IT`-Zustand | n | Anteil |
|---|---:|---:|
| Leerstring (keine Öko-Innovation) | 5.172.369 | 47,7 % |
| Code vorhanden | **5.661.228** | **52,3 %** |

`IT` ist zusammengesetzt aus **Genehmigungsbehörde + Technologienummer(n)**:

```
e1 29 37   →  e1 = Deutschland (KBA),  Technologien 29 und 37
e5 29      →  e5 = Schweden,           Technologie 29
e9 29 37   →  e9 = Spanien,            Technologien 29 und 37
```

Häufigste Ausprägungen 2025: `e2 29 37` (610.012), `e9 29 37` (535.483),
`e6 37` (488.905), `e2 37` (438.671), `e2 32 37` (417.794), `e5 29` (403.948).

> ⚠ **Das Feld ist nicht normalisiert.** Dieselbe Kombination erscheint als
> `e5 29 37`, `e5 2937`, `e529  37` und `e5 29  37`. Auch Mehrfachnennungen der Behörde
> kommen vor (`e5  e5 29`, `e24 2e24 29`). Für **H5** muss `IT` tokenisiert werden:
> Behördenpräfix abtrennen, Zahlen extrahieren, Duplikate entfernen. Ein simples
> `GROUP BY IT` würde dieselbe Technik über Dutzende Schreibweisen verteilen und H5
> systematisch falsch beantworten.

`Erwltp (g/km)` ist die **Gutschrift in g/km**, die dem Hersteller auf den Flottenwert
angerechnet wird. Zusammen mit `Mp` ist das der direkte Test für H5: Wie viele Hersteller
erreichen ihr Ziel nur mit dieser Gutschrift?

---

## 3 · Vom Rohtext zum Sternschema

```
raw.co2cars_2021..2025          alle Spalten TEXT, 1:1 aus der Quelle, UNLOGGED
        │  Typisierung, Filter Ct IN ('M1','M1G'), IT-Leerstring → NULL
        ▼
core.registration               typisiert, bereinigt, mit Herkunftsspalten
        │  Schlüsselbildung
        ▼
star.dim_country ─┐
star.dim_manufacturer ─┤
star.dim_model ─┼──►  star.fact_registration   PARTITION BY RANGE (jahr)
star.dim_powertrain ─┤
star.dim_date ─┘
        │  Vorberechnung
        ▼
mart.*                          fertige Aggregate für Streamlit
```

### 3.1 `dim_powertrain` — die Regel im Klartext

Reihenfolge ist bindend, die erste zutreffende Regel gewinnt:

| # | Bedingung | `antriebsklasse` | Klartext | n (2025) |
|---|---|---|---|---:|
| 1 | `Ft = 'hydrogen'` | `FCEV` | Brennstoffzelle | 451 |
| 2 | `Fm = 'E'` | `BEV` | rein batterieelektrisch | 2.055.863 |
| 3 | `Fm = 'P'` | `PHEV` | Plug-in-Hybrid — **Kern von H1/H2** | 1.057.549 |
| 4 | `Fm = 'H'` | `HEV` | Hybrid ohne Stecker | 3.707.121 |
| 5 | `Fm = 'B'` | `BIFUEL` | zwei Kraftstoffe (LPG/Erdgas) | ~353.860 |
| 6 | `Fm = 'F'` | `FLEX` | flex-fuel E85 | 684 |
| 7 | `Fm = 'M'` und `Ft = 'diesel'` | `ICE_DIESEL` | reiner Diesel | Teilmenge von 3.658.511 |
| 8 | `Fm = 'M'` und `Ft = 'petrol'` | `ICE_BENZIN` | reiner Benziner | Teilmenge von 3.658.511 |
| 9 | sonst | `UNBEKANNT` | zu protokollieren | 9 + Rest |

Zusätzliche Spalten in `dim_powertrain`:
`ft_raw`, `fm_raw` (unverändert aus der Quelle, für die Nachvollziehbarkeit),
`ist_elektrifiziert` (`antriebsklasse IN ('BEV','PHEV','HEV','FCEV')`),
`ist_extern_ladbar` (`antriebsklasse IN ('BEV','PHEV')`).

> Die Zuordnung der 451 Wasserstofffahrzeuge zu einem `Fm`-Wert ist noch offen — sie
> liegen nicht in `Fm='E'` (das deckt sich exakt mit `Ft='electric'`). Wird nach dem
> Staging-Load geprüft und hier nachgetragen.

### 3.2 Die übrigen Dimensionen

| Dimension | Schlüssel | Attribute | Quellspalten |
|---|---|---|---|
| `dim_country` | `country_sk` | `ms_code`, `land_name`, `ist_fokusland`, `region` | `MS` |
| `dim_manufacturer` | `manufacturer_sk` | `mp_pool`, `mh_name`, `man_name` | `Mp`, `Mh`, `Man` |
| `dim_model` | `model_sk` | `marke`, `handelsname`, `marke_norm`, `handelsname_norm` | `Mk`, `Cn` |
| `dim_powertrain` | `powertrain_sk` | siehe 3.1 | `Ft`, `Fm` |
| `dim_date` | `date_sk` | `datum`, `jahr`, `quartal`, `monat`, `kw` | `Dr` |

`fact_registration` trägt die Kennzahlen `masse_kg`, `pruefmasse_kg`, `co2_wltp`,
`co2_nedc`, `hubraum_cm3`, `leistung_kw`, `strom_wh_km`, `oeko_gutschrift`, `verbrauch_l`
sowie die Herkunftsspalten `data_status`, `source_version`, `src_id`.

### 3.3 Welche Variable beantwortet welche Hypothese

| Hypothese | Analyse | entscheidende Spalten |
|---|---|---|
| H1 — PHEV-Lücke größer als bei Verbrennern | A4 | OBFCM Verbrauch + Strecke, `Fm`, `Ewltp` |
| H2 — Rangfolgen-Umkehr *(Kern)* | A5 | `Fm` (**nicht** `Ft` allein), `Ewltp`, OBFCM-Realwert |
| H3 — DE elektrifiziert langsamer | A1, A2 | `MS`, `Dr`, `Fm` |
| H4 — Gewichtsspirale | A6 | `M (kg)`, `Year`, historisches Massenhistogramm |
| H5 — Ziele nur über Pooling/Öko-Innovation | A3 | `Mp`, `IT` (tokenisiert!), `Erwltp`, `Mt` |

---

## 4 · Was du dir zuerst ansehen solltest

1. `01_daten\referenz\kreuztabelle_ft_fm_2025.csv` — `Ft` × `Fm` mit Durchschnitts-CO₂ und
   -Masse je Kombination. Hier siehst du in einer Tabelle, warum `Fm` gebraucht wird.
2. `01_daten\referenz\stichprobe_co2cars_2025_DE.csv` — 500 echte deutsche Zulassungen mit
   allen Spalten.
3. `01_daten\referenz\nullquoten_2025.csv` — welche Spalten überhaupt brauchbar sind.
4. `01_daten\referenz\verteilung_it_2025.csv` — die 300 häufigsten Öko-Innovationscodes,
   inklusive der Schreibvarianten.
