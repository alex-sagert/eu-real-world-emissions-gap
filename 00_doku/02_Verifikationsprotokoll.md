# Verifikationsprotokoll — Tag 1

Alle Zahlen in diesem Dokument stammen aus Queries, die am **10.08.2026** tatsächlich gegen
den EEA-DiscoData-REST-Endpunkt abgesetzt wurden. Keine Schätzungen.

Endpunkt: `https://discodata.eea.europa.eu/sql?query=<T-SQL>&p=<seite>&nrOfHits=<n>`

---

## 1 — Tabellennamen je Jahrgang (durch Probing ermittelt)

Der Datahub nennt nur die Tabelle des laufenden Jahrgangs. Die Namen der übrigen Jahrgänge
sind nicht dokumentiert und wurden durch systematisches Probing gefunden:

| Jahr | Tabelle in `[CO2Emission].[latest]` | Status | Verifikation |
|---|---|---|---|
| 2021 | `co2cars_2021Fv24` | **F**inal | ✅ `SELECT TOP 1 Year` → 2021 |
| 2022 | `co2cars_2022Fv26` | **F**inal | ✅ → 2022 |
| 2023 | `co2cars_2023Fv28` | **F**inal | ✅ → 2023 |
| 2024 | `co2cars_2024Pv29` | **P**rovisional | ✅ → 2024 |
| 2025 | `co2cars_2025Pv31` | **P**rovisional | ✅ → 2025 |

Nicht existent und damit ausgeschlossen: `co2cars_2021Fv23`, `co2cars_2021Fv25`,
`co2cars_2023Fv27`, `co2cars_2010Fv1` (jeweils Fehler 10003 „Invalid object name").

Die Versionsnummer steigt nicht gleichmäßig (24 → 26 → 28 → 29 → 31). Für die Jahrgänge
ab 2010 (H4) muss dasselbe Probing wiederholt werden; das Ladeskript bringt dafür einen
Auto-Discovery-Modus mit.

## 2 — Zeilenzahlen je Land und Jahr

Query-Muster:
```sql
SELECT MS AS c, COUNT(*) AS n
FROM [CO2Emission].[latest].[co2cars_<JAHR><V>]
GROUP BY MS
```

### Fokusländer (Ladeumfang des Projekts)

| Land | 2021 | 2022 | 2023 | 2024 P | 2025 P |
|---|---:|---:|---:|---:|---:|
| DE | 2.530.135 | 2.571.033 | 2.765.152 | 2.728.237 | 2.772.367 |
| FR | 1.777.879 | 1.638.878 | 1.889.602 | 1.820.622 | 1.731.737 |
| IT | 1.456.503 | 1.312.635 | 1.564.369 | 1.555.384 | 1.505.912 |
| ES | 908.449 | 851.105 | 974.231 | 1.055.935 | 1.196.466 |
| NL | 315.471 | 305.890 | 364.769 | 377.394 | 384.556 |
| NO | 175.852 | 174.107 | 126.932 | 128.602 | 179.394 |
| **Summe 6** | **7.164.289** | **6.853.648** | **7.685.055** | **7.666.174** | **7.770.432** |
| EU-27+IS+NO | 9.920.521 | 9.479.544 | 10.734.898 | 10.779.681 | 10.833.597 |
| Anteil der 6 | 72,2 % | 72,3 % | 71,6 % | 71,1 % | 71,7 % |

**Ladeumfang gesamt: 37.139.598 Zeilen** (von 51.748.241 EU-weit, 71,8 %).

## 3 — Abweichung zum Projektplan (Meldepflicht)

Der Start-Prompt nennt für 2025 **10.833.406** Zeilen. Die heutige Zählung ergibt
**10.833.597** — also **191 Zeilen mehr**. Die Kontrollrechnung über den Antriebsmix
bestätigt den neuen Wert:

| Antrieb (`Ft`) | n |
|---|---:|
| petrol | 6.075.402 |
| electric | 2.055.863 |
| diesel | 1.279.640 |
| petrol/electric (PHEV) | 1.009.882 |
| lpg | 352.268 |
| diesel/electric (PHEV) | 47.590 |
| e85 | 12.384 |
| hydrogen | 451 |
| ng | 108 |
| **unknown** | **9** |
| **Summe** | **10.833.597** |

Zwei Ursachen, beide relevant für die Dokumentation:

1. Der Jahrgang 2025 ist **provisional** und wird laufend nachgemeldet. Die Datahub-Seite
   wies beim ersten Abruf „Last modified 04 Aug 2026" aus, beim zweiten Abruf am selben Tag
   „10 Aug 2026".
2. Die Kategorie `unknown` (9 Zeilen) fehlte in der Aufstellung des Start-Prompts.

**Konsequenz für die Arbeit:** Der Ladezeitpunkt wird protokolliert und im Bericht genannt.
Alle Zahlen im CAT/Bericht beziehen sich auf den Stand des tatsächlichen Ladelaufs, nicht auf
den Stand der Vorbereitung. Zusätzlich wird die Tabellenversion (`v24`…`v31`) mitgeführt.

## 4 — Erste Auffälligkeiten in den Rohdaten

### 4.1 Final gegen Provisional

2021–2023 sind **final**, 2024 und 2025 sind **provisional**. Das ist kein Fehler, aber ein
struktureller Bruch: Provisorische Jahrgänge sind unvollständig und werden nachträglich
korrigiert. Jede Aussage, die 2024/2025 mit 2021–2023 vergleicht, muss das kennzeichnen.
→ `core_registration` bekommt eine Spalte `data_status CHAR(1)` und `source_version TEXT`.

### 4.2 Verdächtige Einbrüche kleiner Märkte 2025

| Land | 2024 | 2025 | Veränderung |
|---|---:|---:|---:|
| Estland | 25.396 | 12.942 | −49,0 % |
| Finnland | 71.810 | 48.818 | −32,0 % |

Ein Rückgang um die Hälfte innerhalb eines Jahres ist bei EE unplausibel als Marktbewegung
und deutet auf **unvollständige Nachmeldung** im provisorischen Jahrgang hin.
Beide Länder gehören nicht zur Vergleichsgruppe, die Beobachtung ist aber ein Beleg dafür,
dass provisorische Jahrgänge nicht ohne Vorbehalt verwendet werden dürfen.

### 4.3 Norwegen 2023/2024

NO fällt von 174.107 (2022) auf 126.932 (2023) und steigt 2025 wieder auf 179.394.
Das ist **kein** Datenfehler, sondern die bekannte Reaktion auf die Änderung der
norwegischen Fahrzeugbesteuerung. Wird im Bericht als Kontextinformation eingeordnet, nicht
als Ausreißer behandelt.

### 4.4 Fehlende Werte in der Stichprobe

`SELECT TOP 1 * FROM [CO2Emission].[latest].[co2cars_2025Pv31]` liefert für einen
Hyundai i20 (DE, Benzin):

```
Enedc (g/km) = null      W (mm) = null       At1/At2 (mm) = null
Z (Wh/km)    = null      IT = ""             Ernedc/Erwltp = null
MMS = null               De = null           Vf = null
Ewltp (g/km) = 119       M (kg) = 1140       Mt = 1237      Fc = 5,2
```

Erwartungskonform: `Enedc` ist ab 2021 leer (NEDC ausgelaufen), `Z (Wh/km)` nur bei
elektrifizierten Antrieben belegt, `Erwltp` nur bei Öko-Innovationen. `IT` ist ein
**Leerstring**, kein NULL — beim `COPY` muss deshalb `NULL ''` gesetzt und in der
`core`-Schicht sauber auf NULL normalisiert werden. Die NULL-Quoten je Spalte werden nach
dem Staging-Load systematisch gemessen (`02_sql/15_qualitaet_raw.sql`).

## 5 — Technische Randbedingungen des DiscoData-Endpunkts

Am 10.08.2026 verifiziert:

| Beobachtung | Bedeutung fürs Laden |
|---|---|
| Backend ist **MS SQL Server**, Sprache T-SQL | `LIMIT` gibt es nicht, es heißt `TOP n` |
| **`WITH` / CTEs sind gesperrt** (laut Help-Seite) | Alle CTE-Analysen laufen erst lokal in PostgreSQL |
| DDL ist gesperrt, Systemtabellen sind gesperrt | Tabellenliste nur durch Probing ermittelbar |
| Die erste Spalte **braucht einen Alias** (Fehler 10004) | `SELECT MS AS c, …` statt `SELECT MS, …` |
| Aggregate brauchen einen Alias | `COUNT(*) AS n` |
| `ID` ist über den Jahrgang aufsteigend: 2025 reicht von **162.744.190** bis **184.519.240** bei 10.833.597 Zeilen (Dichte ≈ 50 %) | **Keyset-Paginierung über `ID`** statt `OFFSET`. Ein ID-Fenster von 100.000 liefert ~50.000 Zeilen. Deep Paging mit `p=500` würde in SQL Server über `OFFSET` laufen und wäre unbrauchbar langsam. |

Daraus folgt die Downloadstrategie in `03_skripte/01_download_co2cars.ps1`:
ID-Fenster statt Seitenzahlen, Fenstergröße halbiert sich automatisch, wenn eine Antwort
das Zeilenlimit erreicht, und der Fortschritt wird je Fenster als CSV-Teil geschrieben,
sodass ein Abbruch nicht den ganzen Lauf kostet.

## 6 — Keine Bulk-CSV für co2cars

Recherchiert und bestätigt: Der Datahub-Eintrag für co2cars bietet **keinen
CSV-Direktdownload** mehr. Angeboten werden nur:

- „Table definitions" (Feldbeschreibung)
- „CO2 from cars and vans — statistical metadata 2025P"
- „CO2 passenger cars (elastic data viewer)" — Stand der App: 13.12.2024, enthält 2025 nicht
- SQL-REST-Endpunkt
- DOI

Die alte URL `eea.europa.eu/data-and-maps/data/co2-cars-emission-22` leitet auf den
Datahub-Eintrag um. Der REST-Endpunkt ist damit **nicht die bequeme, sondern die einzige**
Bezugsquelle für Rohdaten auf Fahrzeugebene — was den Aufbau der Ladepipeline zur
eigentlichen Data-Engineering-Leistung des Projekts macht und im Bericht so beschrieben wird.

Für OBFCM (Art. 12) gilt das Gegenteil: Dort gibt es einen echten Direktdownload
(Nextcloud-Share der EEA, ~1,5 GB), siehe Steckbrief.
