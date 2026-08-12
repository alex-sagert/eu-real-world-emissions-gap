# Datenqualität an der Quelle — vor dem Laden

Stichprobenjahr **2025** (`co2cars_2025Pv31`, provisional), Grundgesamtheit
**10.833.597** Zeilen EU-27 + IS + NO. Alle Zahlen aus Queries vom 10.08.2026.

Diese Prüfung läuft **vor** dem Staging-Load, damit klar ist, worauf beim Laden zu achten
ist. Die vollständige Prüfung über alle Jahrgänge und Spalten läuft danach in PostgreSQL
(`02_sql/15_qualitaet_raw.sql`).

---

## B1 · Fehlende Werte in den Kernspalten

```sql
SELECT COUNT([Ewltp (g/km)]) AS a, COUNT(*) AS n FROM [CO2Emission].[latest].[co2cars_2025Pv31]
SELECT COUNT([M (kg)]) AS a, COUNT([Z (Wh/km)]) AS b FROM [CO2Emission].[latest].[co2cars_2025Pv31]
```

| Spalte | belegt | fehlt | Anteil fehlend | Bewertung |
|---|---:|---:|---:|---|
| `Ewltp (g/km)` | 10.827.071 | 6.526 | 0,060 % | unkritisch, aber **nicht** null-frei |
| `M (kg)` | 10.833.268 | 329 | 0,003 % | unkritisch |
| `Z (Wh/km)` | 2.948.208 | 7.885.389 | 72,8 % | erwartet — nur elektrifizierte Fahrzeuge |

**Befund zu `Z (Wh/km)`:** Elektrifizierte Fahrzeuge insgesamt (electric + beide PHEV-Arten)
sind 2.055.863 + 1.009.882 + 47.590 = **3.113.335**. Belegt ist der Stromverbrauch aber nur
bei 2.948.208 — es fehlen **165.127 Fahrzeuge (5,3 % der elektrifizierten Flotte)**.

Das ist relevant, weil `Z (Wh/km)` die Eingangsgröße für den Well-to-Wheel-Vergleich mit dem
SMARD-Strommix ist. Konsequenz: Der Well-to-Wheel-Teil läuft auf einer um 5,3 % reduzierten
Grundgesamtheit. Wird im Bericht offengelegt, statt die Lücke zu imputieren.

## B2 · Fahrzeugklasse `Ct` — Fremdkörper im Pkw-Datensatz

```sql
SELECT Ct AS ct, COUNT(*) AS n FROM [CO2Emission].[latest].[co2cars_2025Pv31] GROUP BY Ct
```

| `Ct` | n | Anteil | Bedeutung |
|---|---:|---:|---|
| M1 | 10.797.713 | 99,668 % | Pkw — Zielmenge |
| M1G | 35.193 | 0,325 % | Pkw mit Geländeeigenschaften |
| **N1** | **503** | 0,005 % | **leichtes Nutzfahrzeug — gehört nicht in diesen Datensatz** |
| **N2** | **3** | — | **Nutzfahrzeug > 3,5 t** |
| **M2** | **1** | — | **Bus** |
| *(leer)* | **184** | 0,002 % | **Klasse nicht gemeldet** |

**Filterentscheidung:** `Ct IN ('M1','M1G')`. Damit fallen **691 Zeilen** heraus.
M1G bleibt drin, weil es fachlich Pkw sind und die Ausschlussgrenze sonst willkürlich wird.
Die 691 ausgeschlossenen Zeilen werden gezählt und im Bericht genannt — nicht kommentarlos
weggefiltert.

## B3 · `R` — keine Aggregation in der Quelle

```sql
SELECT R AS r, COUNT(*) AS n FROM [CO2Emission].[latest].[co2cars_2025Pv31] GROUP BY R
```

Ergebnis: **ein einziger Wert, `R = 1`, für alle 10.833.597 Zeilen.**

Damit ist eine wichtige Unsicherheit ausgeräumt: Die EEA liefert echte Einzelsätze, keine
verdichteten Zeilen mit Mengenangabe. `COUNT(*)` ist die korrekte Zählung, eine Gewichtung
mit `R` ist nicht nötig. Die Prüfung wird für die übrigen Jahrgänge nach dem Load in
`15_qualitaet_raw.sql` (P4) wiederholt.

## B4 · `Fm` gegen `Ft` — die wichtigste Erkenntnis des Tages

```sql
SELECT Fm AS fm, COUNT(*) AS n FROM [CO2Emission].[latest].[co2cars_2025Pv31] GROUP BY Fm
```

| `Fm` | Bedeutung | n | Anteil |
|---|---|---:|---:|
| M | mono-fuel | 3.658.511 | 33,77 % |
| **H** | **Hybrid (nicht extern ladbar)** | **3.707.121** | **34,22 %** |
| E | rein elektrisch | 2.055.863 | 18,98 % |
| P | Plug-in-Hybrid | 1.057.549 | 9,76 % |
| B | bi-fuel | 353.860 | 3,27 % |
| F | flex-fuel | 684 | 0,01 % |
| UNKNOWN | — | 9 | — |

### Warum das die Analyse verändert

`Ft = 'petrol'` umfasst 6.075.402 Fahrzeuge. Darin stecken aber **3,7 Mio. Hybride**
(`Fm = 'H'`) — Mild- und Vollhybride, die nicht an die Steckdose kommen und deshalb nicht
als „PHEV" gezählt werden, aber eben auch kein reiner Verbrenner sind.

**H2 lautet: „Ein moderner Diesel oder Benziner ist real ehrlicher als ein PHEV."**
Wenn „Benziner" ungeprüft als `Ft = 'petrol'` definiert wird, vergleicht die Analyse zu
einem Drittel Hybride mit Plug-in-Hybriden — und misst damit etwas anderes als
beabsichtigt. Der Befund muss sauber getrennt werden nach:

1. reiner Verbrenner (`Ft` petrol/diesel **und** `Fm = 'M'`)
2. Hybrid ohne Stecker (`Fm = 'H'`)
3. Plug-in-Hybrid (`Fm = 'P'`)
4. rein elektrisch (`Fm = 'E'`)

**Konsequenz für das Sternschema:** `dim_powertrain` wird nicht über `Ft` allein
gebildet, sondern über die Kombination `Ft × Fm`, mit einer abgeleiteten Spalte
`antriebsklasse` in genau diesen vier (plus bi-/flex-fuel) Ausprägungen. Das ist eine
Änderung gegenüber dem ursprünglichen Entwurf im Projektplan und wird dort nachgezogen.

### Zwei Inkonsistenzen zwischen `Ft` und `Fm`

| Beobachtung | Erwartung | Ist | Differenz |
|---|---:|---:|---:|
| `Fm = 'P'` gegen `Ft ∈ {petrol/electric, diesel/electric}` | 1.057.472 | 1.057.549 | **+77** |
| `Fm = 'F'` gegen `Ft = 'e85'` | 12.384 | 684 | **−11.700** |
| `Fm = 'E'` gegen `Ft = 'electric'` | 2.055.863 | 2.055.863 | 0 ✅ |

Die E85-Diskrepanz ist deutlich: Nur 684 von 12.384 E85-Fahrzeugen sind auch als flex-fuel
gekennzeichnet. Die übrigen tragen `Fm = 'M'` oder `'B'`. E85 spielt für die Leitfrage keine
Rolle (0,1 % der Flotte), aber der Befund zeigt: **`Ft` und `Fm` sind nicht redundant und
nicht widerspruchsfrei.** Bei jeder Klassifizierung wird festgelegt und dokumentiert, welche
der beiden Spalten führt. Für die Antriebsklasse führt `Fm`, weil sie die Ladefähigkeit
beschreibt — genau das, worum es bei der Realverbrauchslücke geht.

---

## Was daraus für den Ladelauf folgt

| Befund | Maßnahme |
|---|---|
| `Ewltp` und `M (kg)` sind nicht null-frei | Staging-Spalten bleiben TEXT, `NULL ''` beim `COPY`; Nullbehandlung erst in `core` |
| `IT` ist Leerstring statt NULL | in `core` explizit auf NULL normalisieren |
| `Z (Wh/km)` fehlt bei 5,3 % der elektrifizierten Fahrzeuge | Well-to-Wheel auf reduzierter Grundgesamtheit, Anteil im Bericht nennen |
| 691 Zeilen mit falscher Fahrzeugklasse | Filter `Ct IN ('M1','M1G')` in `core`, Ausschlusszahl protokollieren |
| `R = 1` durchgehend | keine Gewichtung nötig, Prüfung je Jahrgang wiederholen |
| `Fm` trennt Hybrid von PHEV, `Ft` nicht | `dim_powertrain` über `Ft × Fm`, Antriebsklasse mit fünf Ausprägungen |
| 2024/2025 provisional | `data_status` und `source_version` bis in die Faktentabelle mitführen |
