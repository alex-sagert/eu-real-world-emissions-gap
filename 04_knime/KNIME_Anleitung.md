# KNIME-Workflow — Anleitung Knoten für Knoten

Workflow-Name: **`Papier_gegen_Strasse`**
KNIME 5.12, PostgreSQL-JDBC-Treiber 42.7.3 ist im Bundle enthalten — keine Zusatzinstallation.

**Zeitbudget: 2 bis 3 Stunden.** Wenn es um 15:00 nicht steht, spring zu Abschnitt 7
(Minimalvariante) — die erfüllt den Kursbezug, alles darüber ist Kür.

Die Arbeitsteilung ist der eigentliche Punkt dieses Workflows und gehört so ins NvS:
**Die schwere Aggregation läuft in der Datenbank, KNIME holt nur Ergebniszeilen.**
Das ist die Antwort auf die Frage „wozu beides?" — nicht KNIME *gegen* SQL, sondern
KNIME *auf* SQL.

---

## 1 · Verbindung herstellen

**Knoten: `PostgreSQL Connector`**

| Feld | Wert |
|---|---|
| Hostname | `localhost` |
| Port | `5432` |
| Database Name | `bd_co2` |
| Authentication | Username & password |
| Username | `postgres` |
| Passwort | dein Passwort |

Rechtsklick → *Execute*. Grüne Ampel = Verbindung steht. Falls rot: läuft der
PostgreSQL-Dienst? (`services.msc` → *postgresql-x64-18*)

> **Screenshot machen.** Der gehört ins NvS, Kapitel „Dokumentation des Workflows".

---

## 2 · Daten holen — die Aggregation bleibt in der Datenbank

**Knoten: `DB Query Reader`** (Eingang vom Connector)

Vier Stück, je einer pro Auswertung. Alle Abfragen lesen aus den `mart`-Tabellen, die
die SQL-Kette bereits berechnet hat — KNIME holt also fertige Zeilen, keine Rohdaten.

### 2.1 Antriebsmix (für die Visualisierung)

```sql
SELECT ms_code, land_name, jahr, antrieb_label,
       zulassungen, anteil_prozent, delta_prozentpunkte,
       avg_co2_wltp, avg_masse_kg
FROM mart.a1_antriebsmix
ORDER BY ms_code, jahr, zulassungen DESC
```

### 2.2 Realverbrauchslücke (für Scatter und Balken)

```sql
SELECT land, antriebsklasse, jahr, fahrzeuge,
       median_real_l, median_wltp_l, median_gap_pct, p90_gap_pct,
       median_e_anteil_pct, median_laufleistung
FROM mart.a4_luecke
WHERE fahrzeuge >= 500
ORDER BY median_gap_pct DESC
```

### 2.3 Trainingsdaten für das Regressionsmodell

Das ist die einzige Abfrage, die auf Fahrzeugebene geht. Eine Stichprobe von 200.000
Fahrzeugen reicht völlig und hält KNIME flüssig.

```sql
SELECT r.antriebsklasse,
       r.masse_kg,
       r.leistung_kw,
       r.hubraum_cm3,
       r.e_reichweite_km,
       r.fc_wltp,
       r.co2_wltp,
       r.dist_total_km,
       r.land,
       r.jahr,
       r.gap_pct
FROM core.realworld r
WHERE r.eea_verwendbar
  AND r.hat_mindestlauf
  AND r.gap_pct IS NOT NULL
  AND r.gap_pct BETWEEN -50 AND 900
ORDER BY random()
LIMIT 200000
```

> **Warum `gap_pct BETWEEN -50 AND 900`:** Ein Regressionsmodell auf einer Zielgröße mit
> extremen Ausreißern lernt die Ausreißer statt den Zusammenhang. Die Grenze schneidet
> weniger als ein Prozent der Sätze ab und wird im NvS genannt. **Nicht stillschweigend
> filtern.**

### 2.4 Zielerreichung je Hersteller

```sql
SELECT hersteller_gruppe, ist_gepoolt, jahr, zulassungen,
       flottenmittel_vor_oeko, flottenmittel_nach_oeko,
       flottenziel_naeherung, abweichung_g_km,
       anteil_bev_prozent, anteil_phev_prozent, anteil_oeko_prozent
FROM mart.a3_flottenziele
WHERE jahr = 2025 AND zulassungen >= 10000
ORDER BY zulassungen DESC
```

---

## 3 · Zusatzquelle über REST — der Gegencheck

**Knoten: `GET Request`**

Zeigt, dass die Daten aus einer echten API stammen und nicht aus einer abgelegten Datei.

- **URL** (als Konstante eintragen):
  ```
  https://discodata.eea.europa.eu/sql?query=SELECT Ft AS ft,COUNT(*) AS n FROM [CO2Emission].[latest].[co2cars_2025Pv31] GROUP BY Ft&p=1&nrOfHits=50
  ```
- Danach **`JSON Path`**: `$.results[*]` extrahieren
- Danach **`JSON to Table`** oder **`Ungroup`**

**Prüfung:** Die Zeilenzahl je Kraftstoffart muss zu dem passen, was in der eigenen
Datenbank steht. Ein `Joiner` gegen eine `DB Query Reader`-Abfrage auf
`star.fact_registration` macht das sichtbar — und ist ein starker Beleg im NvS, dass
der Ladeweg nichts verloren hat.

---

## 4 · Aufbereitung

| Knoten | Einstellung | Zweck |
|---|---|---|
| `Missing Value` | Numerisch → *Median*, String → *Fixed value* `unbekannt` | Fehlwerte in Modellfeatures |
| `Rule Engine` | siehe unten | Ausreißerkennzeichnung |
| `Math Formula` | `$median_real_l$ - $median_wltp_l$` → neue Spalte `gap_abs_l` | absolute Lücke |
| `Category To Number` | Spalten `antriebsklasse`, `land` | für die Regression |
| `Normalizer` | Min-Max auf `masse_kg`, `leistung_kw`, `hubraum_cm3` | Skalen angleichen |
| `Partitioning` | 70 / 30, *Stratified* auf `antriebsklasse`, Seed **1234** | reproduzierbare Aufteilung |

**Rule Engine — Regel zum Kopieren:**

```
$dist_total_km$ < 5000 => "kurze Laufleistung"
$gap_pct$ > 500 => "extreme Luecke"
TRUE => "normal"
```

> Seed festhalten. Ohne festen Seed ist die Modellgüte bei jedem Lauf leicht anders und
> die Zahl im NvS nicht reproduzierbar.

---

## 5 · Modelle

**Zielgröße: `gap_pct`** — „Wie groß ist die zu erwartende Realverbrauchslücke für ein
Fahrzeug mit gegebener Masse, Leistung, Reichweite und Antriebsart?"

| Knoten | Einstellung |
|---|---|
| `Linear Regression Learner` | Target `gap_pct`; Prädiktoren: `masse_kg`, `leistung_kw`, `hubraum_cm3`, `e_reichweite_km`, `fc_wltp`, `antriebsklasse`, `land` |
| `Regression Predictor` | an Testpartition |
| `XGBoost Tree Ensemble Learner` | Target `gap_pct`, Rest Standard; falls nicht vorhanden: `Random Forest Learner (Regression)` |
| `XGBoost Predictor` | an Testpartition |
| `Numeric Scorer` | je Modell einer — liefert R², MAE, RMSE |

**Diese drei Zahlen je Modell notieren** — sie gehören ins NvS unter „Ergebnisse" und
in die Präsentation:

| Modell | R² | MAE | RMSE |
|---|---|---|---|
| Linear Regression | | | |
| XGBoost | | | |

> **Erwartung, damit du das Ergebnis einordnen kannst:** Die Lücke hängt sehr stark von
> der Antriebsart ab (PHEV gegen Verbrenner sind Größenordnungen). Ein hohes R² wäre
> also wenig überraschend und vor allem ein Verdienst dieser einen Variable. Interessant
> ist die Frage *innerhalb* der PHEV-Gruppe — dort erklärt vermutlich die elektrische
> Reichweite am meisten. **Falls Zeit bleibt:** dasselbe Modell nur auf
> `antriebsklasse = 'PHEV'` filtern und die Gütemaße vergleichen. Das ist die deutlich
> stärkere Aussage.

---

## 6 · Visualisierung und Dashboard

| Knoten | Inhalt |
|---|---|
| `Bar Chart` | Lücke in % je Antriebsklasse — **die Kernabbildung des Projekts** |
| `Scatter Plot` | x `median_wltp_l`, y `median_real_l`, Farbe `antriebsklasse`; eine 45-Grad-Linie zeigt, wie weit die PHEV danebenliegen |
| `Line Plot` | Antriebsmix Deutschland über die Jahre |
| `Stacked Area Chart` | Anteil je Antrieb, Deutschland gegen Norwegen |

Alles in eine **`Component`** packen (mehrere Knoten markieren → Rechtsklick →
*Create Component*), darin `Value Selection Widget` auf `land`, `jahr` und
`antriebsklasse`. Das ergibt das interaktive Dashboard.

> **Screenshots von jedem Diagramm** in `07_grafiken/` ablegen — sie werden in NvS und
> Präsentation gebraucht.

---

## 7 · Minimalvariante, wenn die Zeit knapp wird

Reihenfolge nach Wichtigkeit. Wenn um 15:00 nur Punkt 1 bis 3 stehen, ist der Kursbezug
erfüllt:

1. `PostgreSQL Connector` → `DB Query Reader` (Abfrage 2.2) → `Bar Chart`
2. `GET Request` gegen DiscoData → `JSON Path` → Tabelle
3. `Linear Regression Learner` → `Regression Predictor` → `Numeric Scorer`
4. XGBoost dazu
5. Component mit Filtern

---

## 8 · Speichern und exportieren

1. Workflow speichern unter `04_knime/Papier_gegen_Strasse`
2. Rechtsklick auf den Workflow im Explorer → *Export KNIME Workflow* →
   `04_knime/Papier_gegen_Strasse.knwf`
3. **Ohne Zugangsdaten exportieren** — im Export-Dialog *Reset Workflow* anhaken.
   Sonst liegt dein Datenbankpasswort im Repo.

---

## Was davon ins NvS gehört

- Screenshot des gesamten Workflows
- Begründung der Arbeitsteilung: schwere Aggregation in der Datenbank, KNIME holt
  Ergebniszeilen — mit dem Hinweis, dass `DB Query Reader` genau dafür da ist
- Die drei Gütemaße je Modell, inklusive ehrlicher Einordnung
- Der Ausreißerfilter `gap_pct BETWEEN -50 AND 900` mit Begründung
- Der Seed 1234 für die Reproduzierbarkeit
- Der REST-Gegencheck als Beleg, dass der Ladeweg nichts verloren hat

---

# NACHTRAG 12.08.2026 — Die vier Diagramme, konkret

Der generierte Workflow (`Papier_gegen_Strasse_v4.knwf`) enthält 16 Knoten und rechnet.
Was fehlt, sind die Visualisierungen. Sie werden von Hand ergänzt, weil die
Einstellungsschemata der KNIME-5-View-Knoten umfangreich sind und ich sie nicht raten
wollte — geratene Kennungen haben in diesem Projekt schon dreimal Zeit gekostet.

**Knotennummern im Workflow:**
Knoten 2 = `A1 Antriebsmix` · Knoten 3 = `A4 Realverbrauchsluecke` · Knoten 4 = `A3 Flottenziele`

Knoten findest du am schnellsten über das Suchfeld im Node Repository (oben links).
Die Kategoriepfade haben sich in KNIME 5 mehrfach geändert, der Name ist stabil.

---

## Vorbereitung: ein Row Filter für Deutschland

`mart.a4_luecke` enthält 27 Länder. Ohne Filter mischt jedes Diagramm sie zusammen.

1. **Row Filter** einfügen, Eingang von **Knoten 3 (A4 Realverbrauchsluecke)**.
2. Konfiguration: Spalte `land`, Operator `=`, Wert `DE`, Modus *Include*.
3. Beschriftung: `nur Deutschland`.

Alle drei Diagramme unten hängen an diesem einen Filter.

---

## Diagramm 1 · Bar Chart — Die Lücke je Antriebsklasse

Das ist die Kernaussage von H1 in einem Bild.

- **Knoten:** `Bar Chart`
- **Eingang:** Row Filter (`nur Deutschland`)
- **Category column:** `antriebsklasse`
- **Aggregation:** `Average`
- **Frequency column:** `median_gap_pct`
- **Titel:** `Realverbrauchsluecke je Antrieb, Deutschland`
- **Achsentitel Y:** `Abweichung real gegen WLTP in Prozent`

Erwartetes Bild: drei Balken um 16 bis 19 Prozent, ein Balken bei über 350. Der PHEV-Balken
sprengt die Skala — genau das ist die Aussage, nicht ein Darstellungsproblem.

## Diagramm 2 · Scatter Plot — Papier gegen Straße

Der Titel des Projekts als Streudiagramm.

- **Knoten:** `Scatter Plot`
- **Eingang:** derselbe Row Filter
- **X:** `median_wltp_l`   (Laborwert)
- **Y:** `median_real_l`   (gemessener Wert)
- **Color:** `antriebsklasse`
- **Size:** `fahrzeuge` (optional)
- **Titel:** `Laborwert gegen gemessenen Verbrauch`

Erwartetes Bild: Verbrenner liegen als Wolke leicht oberhalb der Winkelhalbierenden, die
PHEV-Punkte weit links oben — kleiner Laborwert, großer Realwert. Der Abstand zur Diagonalen
**ist** die Lücke.

## Diagramm 3 · Line Plot — Antriebsmix Deutschland über die Jahre

Hier ist ein Zwischenschritt nötig: Der Line Plot braucht die Jahre als Zeilen und die
Antriebe als **Spalten**, die Abfrage liefert aber Langformat.

1. **Row Filter** an **Knoten 2 (A1 Antriebsmix)**: `ms_code` = `DE`.
2. **Pivoting** dahinter:
   - *Groups:* `jahr`
   - *Pivots:* `antrieb_label`
   - *Manual Aggregation:* Spalte `anteil_prozent`, Methode `Sum`
3. **Line Plot** dahinter:
   - *X:* `jahr`
   - *Y:* die erzeugten Spalten `Batterieelektrisch+Sum(anteil_prozent)`,
     `Benzin (rein)+Sum(...)`, `Diesel (rein)+Sum(...)`, `Plug-in-Hybrid+Sum(...)`
   - *Titel:* `Antriebsmix Deutschland 2021 bis 2025`

Die Spaltennamen entstehen erst beim Ausführen des Pivoting-Knotens — erst ausführen, dann
den Line Plot konfigurieren.

## Diagramm 4 · Bar Chart — Well-to-Wheel (das Bild für H2)

Braucht einen neuen Lesekopf, weil `mart.wtw_vergleich` bisher nicht im Workflow steckt.

1. Einen vorhandenen **DB Query Reader** kopieren (Strg+C, Strg+V) und den Eingang mit dem
   **PostgreSQL Connector** verbinden.
2. Beschriftung: `WTW Vergleich`. Abfrage:

```sql
SELECT antriebsklasse, quelle_real, co2_offiziell,
       co2_auspuff_real,
       CASE WHEN antriebsklasse = 'BEV' THEN co2_strom_bev
            ELSE co2_strom_phev END AS co2_strom,
       co2_wtw_gesamt
FROM mart.wtw_vergleich
WHERE bev_szenario = 'mittel'
ORDER BY co2_wtw_gesamt
```

3. **Bar Chart** dahinter:
   - *Category column:* `antriebsklasse`
   - *Aggregation:* `Sum`
   - *Frequency columns:* `co2_offiziell` **und** `co2_wtw_gesamt`
   - *Titel:* `Offiziell gegen Well-to-Wheel, Deutschland`

Erwartetes Bild: Beim BEV steht der offizielle Balken auf null und der reale auf 66,7. Beim
PHEV steht 31 gegen 161. Das ist die Folie, die der Vortrag braucht.

---

## Component bauen

1. Die Knoten markieren, die hineinsollen (Row Filter, Pivoting, alle vier Diagramme —
   **nicht** den Connector und nicht die Reader).
2. Rechtsklick → **Create Component…**, Name: `Diagramme`.
3. Doppelklick öffnet die Component. Über **Open View** entsteht die kombinierte Ansicht.

### Optional: Value Selection Widget

Nur wenn Zeit bleibt — es kostet mehr Fummelei, als es aussieht.

1. In der Component: **Value Selection Widget** einfügen, Eingang vom Reader.
2. *Column:* `land`, *Variable Name:* `v_land`.
3. Im Row Filter den Vergleichswert per **Flow Variable** auf `v_land` setzen
   (Zahnradsymbol oben rechts im Konfigurationsdialog).

Ohne dieses Widget ist der Workflow vollständig und vorführbar. Es ist Kür, nicht Pflicht.

---

## Reihenfolge, wenn die Zeit knapp wird

1. Diagramm 1 (Bar Chart Lücke) — belegt H1
2. Diagramm 4 (Bar Chart WTW) — belegt H2
3. Diagramm 2 (Scatter) — der Projekttitel als Bild
4. Diagramm 3 (Line Plot) — Kontext, verzichtbar
5. Component — Verpackung
6. Value Selection — Kür
