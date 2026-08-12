# Nachvollziehbare Schritte

**Projekt:** Papier gegen Straße — Die Realverbrauchslücke der EU-Neuwagenflotte
**Verfasser:** Alexander Sagert
**Kurs:** Big Data, educX GmbH · Projektwoche 10.–13.08.2026
**Datenstand:** 12.08.2026

---

## 1 · Datenquellen

| Quelle | Inhalt | Zugang | Lizenz |
|---|---|---|---|
| EEA co2cars, VO (EU) 2019/631 Art. 7 | jede Neuzulassung auf Fahrzeugebene | DiscoData SQL-REST | EEA Data Policy |
| EEA Real-world CO₂ (OBFCM), Art. 12 | Lebensdauer-Verbrauch je Fahrzeug inkl. WLTP-Referenz | CSV-Direktdownload | CC-BY-4.0 |
| EEA Aggregatdatei OBFCM | Verbrauchslücke je Hersteller und Kraftstoff, fertig gerechnet | CSV | CC-BY-4.0 |
| SMARD, Bundesnetzagentur | realisierte Stromerzeugung je Energieträger, stündlich | JSON-API | CC-BY-4.0 |

Vollständige Steckbriefe mit URLs, Tabellennamen und Feldlisten:
`00_doku/01_Datenquellen_Steckbriefe.md`

**Die Beschaffung war der erste substanzielle Teil der Arbeit.** Für `co2cars` existiert kein
CSV-Bulkdownload mehr. Der SQL-REST-Endpunkt von DiscoData ist die einzige Quelle für
Rohdaten auf Fahrzeugebene. Er läuft auf MS SQL Server, verbietet CTEs, sperrt die
Systemtabellen und begrenzt die Antwortgröße. Die Ladepipeline musste deshalb selbst gebaut
werden — siehe Abschnitt 7.1.

---

## 2 · Kurze Darstellung des Themas

Seit 2021 hat jedes neue Auto in der EU einen Verbrauchszähler an Bord. Die Hersteller müssen
dessen Werte an die Kommission melden (On-Board Fuel Consumption Meter, OBFCM, Art. 12 der
VO (EU) 2019/631). Zum ersten Mal lässt sich damit für Millionen einzelner Fahrzeuge prüfen,
ob der Wert auf dem Typenschild etwas mit der Straße zu tun hat.

Dieselben Fahrzeuge stehen mit ihrem Zertifizierungswert in der Zulassungsdatenbank nach
Art. 7. Beide Datensätze lassen sich über die Typgenehmigung verbinden. Genau diese
Gegenüberstellung ist der Gegenstand des Projekts.

---

## 3 · Datenbeschreibung

Vollständig in `00_doku/05_Datenlandkarte.md` — jede der 30 geladenen Spalten mit Bedeutung,
Beispielwert, gemessenem Belegungsgrad und Wertebereich.

**Vier Befunde haben das Datenmodell verändert.** Sie stehen hier, weil sie erklären, warum
das Schema so aussieht, wie es aussieht:

- **`Ft` allein taugt nicht als Antriebsdimension.** 34,2 % der Flotte sind Hybride ohne
  Stecker und verstecken sich unter `petrol`. Wer nach `Ft` gruppiert, vergleicht Äpfel mit
  Birnen. Die Antriebsklasse wird deshalb aus `Ft × Fm` gebildet (`core.antriebsklasse`).
- **`Mp` (Pool) ist nur bei 38,4 % gefüllt.** Ein Pool existiert nur bei tatsächlicher
  gemeinsamer Abrechnung. Die Abrechnungseinheit ist deshalb
  `coalesce(mp_pool, mh_name, man_name)`, ergänzt um ein Kennzeichen `ist_gepoolt`.
- **`IT` (Öko-Innovation) ist nicht normalisiert.** Dieselbe Technologie erscheint als
  `e5 29 37`, `e5 2937` und `e529  37`. Ohne Tokenisierung zerfällt sie über Dutzende
  Schreibweisen. `core.oeko_codes` zerlegt den Rohtext gegen eine Positivliste; nicht
  zuordenbare Muster werden verworfen statt geraten.
- **Fünf Spalten sind im Jahrgang 2025 vollständig leer:** `Enedc`, `Ernedc`, `W (mm)`,
  `At1 (mm)`, `MMS`. Der NEDC-Zyklus ist ausgelaufen; das ist kein Datenfehler, sondern
  Regulierungsgeschichte.

---

## 4 · Zielsetzung

Fünf Zielgrößen, jede als ausführbare Abfrage:

1. Realverbrauchslücke je Antriebsklasse, Land und Zulassungsjahr (Median und P90)
2. Der tatsächliche elektrische Fahranteil von Plug-in-Hybriden gegen die 84 %, die die
   WLTP-Regel unterstellt
3. Rangfolgenvergleich offiziell gegen real, auf Klassen- und auf Modellebene
4. Zielerreichung der Hersteller mit und ohne Öko-Innovationsgutschrift
5. Well-to-Wheel-Vergleich aller Antriebsarten mit dem realen deutschen Strommix

---

## 5 · Darstellung der Relevanz

**Die Regulierung reagiert bereits auf genau diesen Befund.** Die EU senkt den Utility Factor
für Plug-in-Hybride bis 2027/28 von 84 % auf rund 34 %. Diese Arbeit quantifiziert, wie groß
die Abweichung tatsächlich war — und liefert mit **25,8 bis 27,0 %** gemessenem elektrischem
Fahranteil in Deutschland einen Wert, der noch unter der abgesenkten Annahme liegt.

**Die Fehlbewertung hat einen Preis, der bezifferbar ist.** Flottenleasing und
B2B-Restwertkalkulation rechnen mit Laborwerten. Bei einem PHEV, dessen zertifizierter Wert
die Realität um den Faktor 5,2 unterschätzt, ist die Kraftstoffkostenrechnung über eine
Haltedauer von drei Jahren falsch — und damit die Restwertprognose.

**Der Verbrennerausstieg wird mit CO₂-Werten begründet, die zu einem erheblichen Teil aus dem
Labor stammen.** Diese Arbeit ersetzt sie, wo es die Datenlage erlaubt, durch gemessene.

---

## 6 · Persönliches Erkenntnisinteresse

Ich komme aus der Automobilbranche — Energiekonzepte im Solarbereich, danach B2B-Handel mit
Gebrauchtfahrzeugen bei Auto1 und CarOnSale, dort unter anderem ein Fahrzeugscanner-Produkt
in Zusammenarbeit mit Herstellern. Wer Restwerte kalkuliert, arbeitet täglich mit
Verbrauchsangaben, die aus der Typprüfung stammen.

Meine Ausgangsfrage war zugespitzt: **Ist der normale Verbrenner vielleicht gar nicht so
schlimm, wie er gemacht wird — und der Plug-in-Hybrid nicht so gut?**

Die Daten haben die erste Hälfte bestätigt und die zweite anders beantwortet, als ich
erwartet hatte. Der Verbrenner ist real 16 bis 19 % schlechter als auf dem Papier, also
schlechter als sein Ruf, aber nicht dramatisch. Der Plug-in-Hybrid ist real um den Faktor 5,2
schlechter als zertifiziert — **und bleibt trotzdem sparsamer als der reine Benziner.** Meine
zugespitzte Hypothese (H2) war auf Flottenebene falsch. Sie stimmt erst auf Modellebene, und
dort in genau 20,9 % der Fälle.

Das ist der eigentliche Ertrag dieser Woche: Eine Hypothese, die sich beim Rechnen ändert,
und der Zwang, das offen zu berichten statt die Zahlen passend zu machen.

---

## 7 · Methodik

### 7.1 Beschaffung

**Keyset-Paginierung auf `ID`** statt Seitenparameter. `OFFSET` ist bei rund 10 Mio. Zeilen je
Jahrgang unbrauchbar, weil der Server für Seite *n* alle vorherigen Zeilen erneut durchläuft.

Das Abfragefenster justiert sich aus der **gemessenen ID-Dichte**. Sie schwankt stark: 2,80
IDs je Zielzeile in 2025 gegen 20,89 in 2021, weil die IDs über alle Mitgliedstaaten hinweg
vergeben werden und wir auf sechs Fokusländer filtern. Ein fest gewähltes Fenster war für
2021 um den Faktor 10 zu klein.

**Wiederaufsetzpunkt nach jedem Fenster.** Beim Wiederaufsetzen wird die CSV auf den
gesicherten Stand zurückgeschnitten. Ohne diesen Schritt entstehen an der Nahtstelle
verschmolzene Zeilen und Dubletten — siehe Fehlerprotokoll Nr. 3 und 5.

**Ergebnis:** 37.139.598 co2cars-Zeilen, jeder Jahrgang exakt auf der an der Quelle
gezählten Sollmenge. Dazu 7.791.120 OBFCM-Zeilen. Zusammen rund 45 Mio. Zeilen und 8,2 GB.

Der PowerShell-Downloader schaffte 900 Zeilen/s. Die spätere Python-Implementierung mit
Session-Wiederverwendung erreichte **11.318 Zeilen/s** — Faktor 12,6. Der Unterschied liegt
nicht in der Sprache, sondern im Verbindungsaufbau je Anfrage.

### 7.2 Architektur

Vier Schichten in PostgreSQL 18:

```
raw    TEXT, UNLOGGED        alles wie geliefert, keine Typprüfung
core   typisiert, gefiltert  Pkw-Filter, Antriebsklasse, Öko-Codes
star   Sternschema           fact_registration + 5 Dimensionen
mart   Auswertungsergebnisse eine Tabelle je Analyse
meta   Ladeprotokoll, DQ-Befunde
```

**`fact_registration` ist `PARTITION BY RANGE (jahr)`.** Jede Analyse filtert auf Jahre;
Partition Pruning schaltet ganze Jahrgänge weg, bevor gelesen wird.

**`COPY` statt Import-Dialog:** gemessene 311.000 Zeilen/s.

**Indizes erst nach dem Laden**, ebenso Primär- und Fremdschlüssel. Während des Ladens
geprüft, hätte jede der 37 Mio. Zeilen fünf Fremdschlüsselprüfungen ausgelöst.

**Fehlertolerante Typkonvertierung.** `core.zu_zahl()` gibt bei einem unbrauchbaren Wert
`NULL` zurück statt eine Ausnahme zu werfen. Ein einziger kaputter Wert in 37 Mio. Zeilen
würde sonst den gesamten `INSERT` abbrechen — nach 40 Minuten Laufzeit.

**Sitzungsparameter statt Serverkonfiguration.** `work_mem = 256MB` für die Ladeläufe. Der
Effekt ist mit `EXPLAIN (ANALYZE, BUFFERS)` belegbar als Wechsel von *external merge Disk* zu
*quicksort Memory*.

### 7.3 Der Engpass, der die Architektur bestimmt hat

Die erste Fassung des Sternschema-Aufbaus verband die Dimensionen mit
`IS NOT DISTINCT FROM`, weil die Schlüsselspalten `NULL` enthalten können. Das ist logisch
korrekt und **praktisch unbrauchbar**: `IS NOT DISTINCT FROM` ist kein hashbarer
Gleichheitsoperator. PostgreSQL kann keinen Hash Join bilden und fällt auf Nested Loops
zurück.

| | vorher | nachher |
|---|---:|---:|
| Schreibrate | 15 MB/min | ~1,3 GB/min |
| Hochrechnung | über 6 Stunden | 10 Minuten 6 Sekunden |

**Die Lösung:** eine zusätzliche Spalte `schluessel text NOT NULL UNIQUE` je Dimension, in der
die Bestandteile verkettet und `NULL` durch Leerstring ersetzt sind. Der Join läuft dann über
einfache Gleichheit und ist hashbar.

Das ist der Kern dessen, was ich in dieser Woche über Big Data gelernt habe: Der Unterschied
zwischen 15 MB/min und 1,3 GB/min war keine Frage der Hardware, sondern eine Eigenschaft
eines Operators.

### 7.4 Analysen

| Analyse | Verfahren |
|---|---|
| A1 Antriebsmix | `SUM() OVER`, `LAG()` für den Vorjahresvergleich |
| A2 Deutschland gegen Referenzgruppe | CTEs, Differenz in Prozentpunkten |
| A3 Flottenziel | parametrisierte Zielfunktion aus `star.ziel_parameter` |
| A4 Realverbrauchslücke | `PERCENTILE_CONT(0.5)` und `(0.9)` |
| A5 Rangfolgenumkehr | `RANK() OVER` auf beiden Werten, Rangdifferenz |
| A6 Gewichtsspirale | rollierendes Mittel über `ROWS BETWEEN 2 PRECEDING` |
| Well-to-Wheel | SMARD-Strommix, Sensitivitätsrechnung über neun Mixwerte |

**Median statt Mittelwert, durchgängig.** Die Verteilung der Lücke ist rechtsschief: Einzelne
Fahrzeuge mit extremer Nutzung verschieben den Mittelwert erheblich. Der Median beschreibt
die Flotte, P90 zeigt das obere Ende.

### 7.5 Bewusst verworfen

**MongoDB und Neo4j.** Die Daten sind durchgängig relational und tabellarisch; es gibt weder
schemalose Dokumente noch eine Graphstruktur, deren Traversierung einen Erkenntnisgewinn
brächte. Ein Einsatz wäre Selbstzweck. Begründung ausführlich im CAT unter (K).

**Kein Spark, kein Hadoop.** 45 Mio. Zeilen laufen auf einem partitionierten PostgreSQL in
Minuten. Ein verteiltes System hätte hier mehr Betriebsaufwand als Nutzen.

---

## 8 · Datenaufbereitung und Filterentscheidungen

Jede Filterentscheidung ist beziffert. Ein Ausschluss ist nur zulässig, wenn bekannt ist, was
er kostet und ob er die Stichprobe verzerrt.

### 8.1 Fachliche Filter

| Filter | Wirkung | Begründung |
|---|---|---|
| Fahrzeugklasse M1/M1G | nur Pkw | Nutzfahrzeuge folgen anderer Regulierung |
| `eea_verwendbar` | wie die EEA in ihrer eigenen Aggregatdatei | Vergleichbarkeit mit der Referenz |
| `hat_mindestlauf` | Mindestlaufleistung | Ein Fahrzeug mit 200 km Lebensdauer liefert keinen belastbaren Durchschnittsverbrauch |
| `gap_pct` zwischen −50 und 900 % | nur für die Regression | Ein Modell auf einer Zielgröße mit extremen Ausreißern lernt die Ausreißer statt den Zusammenhang |

### 8.2 Was die Vollständigkeitsfilter kosten

Abfrage `02_sql/43_knime_trainingsbasis.sql`, ausgeführt 12.08.2026:

| | Sätze | Verlust |
|---|---:|---:|
| Grundgesamtheit | 5.891.869 | — |
| nach Ausreißergrenze | 5.865.872 | 25.997 (0,44 %) |
| Trainingsbasis | 5.857.803 | 8.069 (0,14 %) |
| **erhalten** | | **99,42 %** |

Der gesamte Vollständigkeitsverlust hängt an einer Spalte: `leistung_kw` fehlt in 8.070
Sätzen. `masse_kg`, `fc_wltp`, `co2_wltp` und `dist_total_km` sind lückenlos.

**Der Antriebsmix verschiebt sich nicht:**

| Antrieb | Anteil vorher | Anteil nachher |
|---|---:|---:|
| ICE_BENZIN | 34,02 % | 34,02 % |
| HEV | 31,13 % | 31,12 % |
| ICE_DIESEL | 23,40 % | 23,40 % |
| PHEV | 11,45 % | 11,47 % |

Das war die eigentliche Prüfung. Ein Filter, der 0,58 % entfernt, aber die Struktur verzerrt,
wäre trotzdem unbrauchbar.

### 8.3 Zwei Ersetzungen, die keine sind

`e_reichweite_km` fehlt in 5.215.591 Sätzen (88,5 %), `hubraum_cm3` in 124. Beide werden auf
**0** gesetzt statt die Zeile zu verwerfen. Das ist keine Imputation: Ein reiner Verbrenner
**hat** keine elektrische Reichweite, ein Elektroauto keinen Hubraum. Null ist die Sachlage.

Bei der PHEV-Teilmenge werden `anteil_elektrisch` (3.400 fehlend) und `grid_kwh` (7.474
fehlend) dagegen **verlangt**, nicht ersetzt. Sie sind die Erklärgrößen der Lücke — ein
eingesetzter Median würde genau die Frage beantworten, um die es geht. Kosten: 696.649 →
674.863 Sätze, also 3,1 %.

### 8.4 Datenqualitätsbefunde, die nicht wegfiltert wurden

Alle Befunde stehen in `meta.dq_befund` und in `00_doku/04_Qualitaetsbefunde_Quelle.md`.
Zwei sind bemerkenswert:

**Ein 32-Bit-Zählerüberlauf im Bordmessgerät.** Der größte Wert in den Distanzspalten ist
exakt **429.496.740 km = 2³²/10**. Das ist kein Ausreißer, sondern ein überlaufender
Zähler. Der erste Ladeversuch scheiterte an `numeric(12,1)`; die Spalten sind jetzt
unbegrenzt, und die absurden Werte werden **gezählt** statt entfernt.

**691 Zeilen mit falscher Fahrzeugklasse** und `R = 1` durchgängig — dokumentiert, nicht
korrigiert.

---

## 9 · Ergebnisse

### 9.1 H1 — Realverbrauchslücke (bestätigt)

Deutschland, gepoolter Median über alle Zulassungsjahrgänge, 1.608.112 Fahrzeuge:

| Antrieb | Fahrzeuge | real l/100 km | WLTP l/100 km | Lücke Median | Lücke P90 |
|---|---:|---:|---:|---:|---:|
| ICE Benzin | 564.918 | 7,44 | 6,40 | **+16,0 %** | +34,8 % |
| ICE Diesel | 410.135 | 6,59 | 5,60 | **+16,6 %** | +32,4 % |
| HEV | 409.090 | 7,07 | 5,90 | **+18,8 %** | +37,4 % |
| PHEV | 223.969 | 6,06 | 1,40 | **+320,7 %** | +666,5 % |

**H1 ist bestätigt.**

**Methodenhinweis.** Die Zusammenfassung in `mart.a4_luecke` bildet `avg()` über die
Jahresmediane und liefert deshalb leicht abweichende Werte (+16,5 % bzw. +352,9 %). Dort
zählt jeder Zulassungsjahrgang gleich viel, obwohl 2022 rund 120.000 PHEV enthält und 2023
nur 27.000. **Maßgeblich ist der gepoolte Median oben**, weil er jedes Fahrzeug gleich
gewichtet. Die Differenz wird offengelegt statt angeglichen.

### 9.2 Der Utility Factor in der Praxis

Die WLTP-Regel unterstellt rund **84 %** elektrische Fahrleistung für Plug-in-Hybride.
Gemessen wurde in Deutschland:

| Jahrgang | PHEV | elektrisch gefahren | Netzstrom | Lücke |
|---|---:|---:|---:|---:|
| 2021 | 76.669 | **25,8 %** | 1.744 kWh | +275,7 % |
| 2022 | 120.165 | **27,0 %** | 957 kWh | +331,0 % |
| 2023 | 27.135 | **26,3 %** | 437 kWh | +452,0 % |

**Ein knappes Drittel des unterstellten Werts, stabil über alle 27 Mitgliedstaaten.** Die
Bandbreite reicht von 23,5 % (Dänemark 2022) bis 46,7 % (Zypern 2021) — kein einziges Land
kommt in die Nähe von 84 %.

### 9.3 H2 — auf Flottenebene widerlegt, auf Modellebene bestätigt

> **H2 (ursprünglich):** Ein moderner Diesel oder Benziner ist real ehrlicher als ein PHEV;
> die offizielle Rangfolge kehrt sich teilweise um.

**Auf Klassenebene ist das falsch.** Der Well-to-Wheel-Vergleich mit dem realen deutschen
Strommix (Jahresmittel 355,6 g/kWh):

| Antrieb | Quelle Realwert | Papier | Auspuff real | Strom | **Well-to-Wheel** | vs. Papier |
|---|---|---:|---:|---:|---:|---:|
| BEV | WLTP Laborwert | 0,0 | — | 66,7 | **66,7** | *nicht definiert* |
| PHEV | OBFCM gemessen | 31,0 | 138,9 | 21,9 | **160,8** | +419 % |
| ICE Benzin | OBFCM gemessen | 144,0 | 169,4 | 0 | **169,4** | +18 % |
| HEV | OBFCM gemessen | 141,0 | 171,4 | 0 | **171,4** | +22 % |
| ICE Diesel | OBFCM gemessen | 146,0 | 173,3 | 0 | **173,3** | +19 % |

Der PHEV bleibt vorn. Die Sensitivitätsrechnung zeigt die Kippgrenze bei rund **500 g/kWh**;
der deutsche Mix liegt bei 355,6 und fällt (371,8 in 2021 auf 321,9 in 2025).

**Auf Modellebene stimmt die Hypothese.** Analyse A5c zählt Modellpaare, bei denen der PHEV
auf dem Papier besser dasteht:

> **7.960 Paare. In 1.665 davon (20,9 %) ist der Verbrenner real sparsamer.**

Ein Beispiel aus A5d: BMW 116d, 4,60 l auf dem Papier, **5,44 l** auf der Straße. MG EHS
Plug-in-Hybrid, 1,80 l auf dem Papier, **8,58 l** auf der Straße. Der Diesel, der laut
Typprüfung 2,6-mal schlechter sein sollte, verbraucht real 3,14 l weniger.

**Das ist die präzise Fassung des Befunds:** Die Rangfolge kehrt sich nicht zwischen den
Antriebsarten um, sondern zwischen konkreten Fahrzeugen. Ein sparsamer Kompaktdiesel schlägt
einen schweren Plug-in-Hybrid-SUV — auf dem Papier nie, auf der Straße in jedem fünften Fall.

### 9.4 Der Befund zum Batterieauto

Für das BEV schreibt die Verordnung **0 g/km** vor. Mit dem realen deutschen Strommix sind es
**66,7 g/km**. Die Prozentspalte bleibt leer, weil sich durch null nicht teilen lässt.

Über drei Aufschlagsszenarien (Laborwert, +15 %, +30 %) bewegt sich der Wert zwischen
**58,0 und 75,4 g/km**. Selbst im ungünstigsten Fall liegt das BEV bei 44 % des besten
Verbrenners. **Die Aussage hängt nicht an der Annahme** — das ist der Zweck der
Szenariorechnung.

**Einschränkung.** Die BEV-Zeile stammt aus der WLTP-Typprüfung, alle anderen aus gemessenem
Verbrauch. OBFCM ist ein Kraftstoff-Verbrauchsmesser; ein Batterieauto hat keinen und ist in
dieser Quelle nicht enthalten. Der Vergleich ist **nicht gleichwertig**. Die Ergebnistabelle
führt dafür die Spalte `quelle_real`.

### 9.4a Hersteller: wer hält sein Versprechen? (A7)

**Die methodische Falle zuerst.** Eine Rangliste „Lücke je Hersteller" über die gesamte
Flotte misst nicht die Ehrlichkeit des Herstellers, sondern seinen Antriebsmix. Wer
viele Plug-in-Hybride verkauft, landet automatisch hinten. Die Prüfung belegt das: Die
Korrelation zwischen Plug-in-Hybrid-Anteil und Verzerrung beträgt **0,890**.

Mazda liegt über die gesamte Flotte bei 22,7 % — Mittelfeld. Auf reine Verbrenner
beschränkt bei **11,4 %** — Bestwert. Der Unterschied ist ausschließlich der
32,7-prozentige PHEV-Anteil. Eine unkorrigierte Rangliste bestraft genau die Hersteller,
die früh elektrifiziert haben.

**Zulässig ist deshalb nur der Vergleich innerhalb derselben Antriebsart.**

#### Reine Verbrenner, Deutschland, mindestens 3.000 Fahrzeuge

| Platz | Hersteller | Fahrzeuge | WLTP | real | Lücke | Masse | Leistung |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | Mazda | 8.198 | 6,90 | 7,63 | +11,4 % | 1.555 kg | 135 kW |
| 2 | Porsche | 13.407 | 11,00 | 12,31 | +11,5 % | 1.870 kg | 294 kW |
| 3 | Volvo | 4.586 | 7,30 | 8,14 | +12,2 % | 1.625 kg | 120 kW |
| 6 | Volkswagen | 309.329 | 6,00 | 6,81 | +14,3 % | 1.520 kg | 110 kW |
| 22 | Dacia | 31.220 | 5,60 | 6,93 | +22,2 % | 1.181 kg | 67 kW |
| 23 | Renault | 64.237 | 5,80 | 7,13 | +22,5 % | 1.280 kg | 67 kW |
| 25 | BMW GmbH (M) | 4.866 | 10,70 | 13,46 | +24,5 % | 1.975 kg | 375 kW |

25 Hersteller, Spannweite 13,1 Prozentpunkte, Mittel 17,0 %, Streuung 3,5 Prozentpunkte.

#### Der Befund läuft der Intuition zuwider

Porsche liegt auf Platz 2 — bei 11,0 l Laborwert und 294 kW. Dacia und Renault liegen
auf den Plätzen 22 und 23 — bei den leichtesten Fahrzeugen und den kleinsten Motoren
des Feldes.

Die plausibelste Erklärung ist der **Downsizing-Effekt**: Ein kleiner, aufgeladener
Motor arbeitet im sanften WLTP-Zyklus nahe seinem Bestpunkt und sieht dort hervorragend
aus. Im Alltag — Autobahn, Kaltstart, Zuladung — verlässt er diesen Bereich sofort. Ein
großer Motor ist im Labor nie am Limit und im Alltag ebenfalls nicht.

**Diese Erklärung ist plausibel, aber mit den vorliegenden Daten nicht bewiesen.** Sie
wäre über Motorkennfelder oder Fahrprofile zu prüfen, die hier nicht vorliegen. Das
gehört zur Ehrlichkeit des Befunds dazu.

**Zur Auslegung:** Die Lücke ist eine *relative* Größe. Renault verbraucht real 7,13 l,
Porsche 12,31 l. Der Renault bleibt das sparsamere Auto — er hält sein Versprechen nur
schlechter ein. Beides ist gleichzeitig richtig, und die Verwechslung wäre der
naheliegendste Fehler bei der Interpretation.

#### Plug-in-Hybride: die Batteriegröße erklärt es nicht

| E-Reichweite | Hersteller | Fahrzeuge | Lücke | elektrisch gefahren |
|---|---:|---:|---:|---:|
| 45 bis 60 km | 6 | 56.546 | +274,6 % | 26,8 % |
| über 60 km | 14 | 164.390 | +316,6 % | 29,5 % |

Die naheliegende Vermutung wäre: größere Batterie → mehr elektrische Fahrt → kleinere
Lücke. Die Daten sagen das Gegenteil. Der elektrische Fahranteil steigt mit der
Reichweite kaum (26,8 → 29,5 %), die Lücke dagegen deutlich (274,6 → 316,6 %).

Der Extremfall ist Jaguar Land Rover: **110 km elektrische Reichweite, aber nur 17,4 %
elektrisch gefahren** — die mit Abstand größte Batterie im Feld und der schlechteste
Ladeanteil.

> Eine größere Batterie verbessert den Laborwert, aber nicht das Verhalten. Sie
> vergrößert die Lücke, statt sie zu schließen.

Das ist die konsequenteste Bestätigung des Utility-Factor-Befunds aus Abschnitt 9.2.

### 9.5 H4 — Gewichtsspirale (bestätigt)

Deutschland, Faktentabelle, rollierendes Dreijahresmittel:

| Jahr | Zulassungen | ⌀ Masse | Δ zum Start | ⌀ CO₂ WLTP |
|---|---:|---:|---:|---:|
| 2021 | 2.530.022 | 1.577,1 kg | 0,0 | 113,7 |
| 2023 | 2.765.099 | 1.631,7 kg | +54,6 | 113,1 |
| 2025 | 2.772.126 | **1.701,0 kg** | **+123,9** | 102,6 |

Das durchschnittliche Neufahrzeug ist in fünf Jahren um 124 kg schwerer geworden. Der
zertifizierte CO₂-Wert sank gleichzeitig um 11,1 g/km — überwiegend durch den steigenden
BEV-Anteil, der mit 0 g/km angerechnet wird.

### 9.6 H5 — Pooling und Zielerreichung

| Jahr | Abrechnungseinheiten | Ziel erreicht | verfehlt | nur dank Öko-Gutschrift |
|---|---:|---:|---:|---:|
| 2021 | 18 | 14 | 4 | 0 |
| 2023 | 28 | 22 | 6 | 0 |
| 2025 | 40 | **16** | **24** | 2 |

Der Umschwung in 2025 ist deutlich: Erstmals verfehlt die Mehrheit der Einheiten das Ziel.

Der Tesla-Pool umfasst 2025 **1.711.929 Zulassungen (15,80 %)** — ein Vielfaches dessen, was
Tesla selbst verkauft. Pooling ist damit kein Randphänomen, sondern ein wesentlicher
Mechanismus der Zielerreichung.

### 9.7 Modellgüte (KNIME)

Lineare Regression, 70/30-Aufteilung, Seed 1234, Zielgröße `gap_pct`.

| | Modell 1 — alle Antriebe | Modell 2 — nur PHEV |
|---|---:|---:|
| R² | 0,736 | 0,581 |
| adjustiertes R² | 0,736 | 0,581 |
| MAE | 27,8 PP | 103,8 PP |
| RMSE | 58,3 PP | 147,3 PP |
| mittlere vorzeichenbehaftete Abweichung | −0,128 | +0,954 |

**Modell 1 ist der weniger interessante Fall.** R² = 0,736 über alle Antriebe sagt vor allem:
Die Antriebsklasse allein erklärt die Lücke fast. Das war absehbar.

**Modell 2 ist die Aussage.** Innerhalb der Plug-in-Hybride — kontrolliert für Masse,
Leistung, Hubraum, elektrische Reichweite, geladenen Netzstrom und elektrischen Fahranteil —
bleiben **42 % der Streuung unerklärt**:

> Die PHEV-Lücke ist zu einem erheblichen Teil **keine Fahrzeugeigenschaft**. Was das Modell
> nicht sieht, ist das Ladeverhalten der Halterin oder des Halters — und diese Größe steht in
> keiner Zulassungsdatenbank.

Die mittlere vorzeichenbehaftete Abweichung liegt in beiden Modellen nahe null. Der Fehler
ist Streuung, keine Verzerrung.

**MAPE ist in Modell 1 nicht berechenbar** (`NaN`), weil einzelne Testzeilen eine Lücke von
exakt 0 % haben und die Kennzahl durch den Istwert teilt. Keine Fehlfunktion, sondern eine
Eigenschaft der Kennzahl.

---

## 10 · Verifikation gegen die Quelle

Zwei Annahmen wurden gegen die EEA-Aggregatdatei geprüft — eine hat sich als falsch erwiesen:

| Annahme | Ergebnis | Beleg |
|---|---|---|
| Kraftstofffaktor Benzin 2330 g/l | **widerlegt → 2278** | EEA rechnet über 94 Fahrzeuggruppen mit 2278, identisch für OBFCM und WLTP |
| Kraftstofffaktor Diesel 2640 g/l | **korrigiert → 2631** | 57 Gruppen |
| Strommix 300–450 g/kWh | **bestätigt** | 371,8 → 321,9 g/kWh, erneuerbar 41,6 → 58,3 % |

Der Faktor wird aus `obfcm_co2 / obfcm_fc × 100` zurückgerechnet — die EEA veröffentlicht
beide Größen nebeneinander. Übernommen wurden die EEA-Werte, weil unsere Verbrauchszahlen aus
derselben Quelle stammen; eine fremde Literaturkonstante darauf zu rechnen hätte einen Bruch
in der Systemgrenze erzeugt.

**Zeilenkontrolle core gegen star: Differenz 0** bei 37.092.376 Zeilen.

---

## 11 · Fehler und was sie gelehrt haben

Vollständiges Protokoll: `00_doku/07_Fehlerprotokoll.md` — 17 Fehler, davon **sechs stumme**.

Stumme Fehler brechen kein Programm ab. Sie liefern falsche oder leere Ergebnisse, während
jeder Schritt „ok" meldet. Vier von ihnen liefen durch eine Kette, die an keiner Stelle rot
wurde. Die drei folgenreichsten:

**Die SMARD-Datei wurde nie geladen.** Downloader und Auswertung existierten, der Ladeschritt
dazwischen fehlte. Die Auswertung rechnete auf einer leeren Tabelle weiter und lieferte einen
Well-to-Wheel-Vergleich aus lauter Leerwerten. Alle vier Kettenschritte meldeten Erfolg.
→ *Konsequenz:* Ein leerer Eingang ist jetzt ein Abbruch, kein Ergebnis.

**`min(ft)` wählt alphabetisch.** Der Kraftstofffaktor wurde je Antriebsklasse über `min()`
gezogen. In der PHEV-Klasse liefert das `diesel/electric`, weshalb die gesamte Flotte mit dem
Dieselfaktor bepreist wurde. Aufgefallen ist es nur, weil dieselbe Flotte in zwei Ausgaben
mit unterschiedlichen Werten erschien (157,7 gegen 139,6 g/km).
→ *Konsequenz:* Zwei Zahlen für denselben Sachverhalt sind immer ein Fehler.

**Die Spaltenreihenfolge der SMARD-CSV weicht von der Tabellendefinition ab.** `wind_offshore`
steht vor `wasserkraft`. Ein positionelles `\copy` hätte Windstrom als Wasserkraft verbucht —
und das wäre nie aufgefallen, weil beide den Emissionsfaktor 0 g/kWh tragen.
→ *Konsequenz:* Die Spaltenliste wird aus der Kopfzeile gelesen, nicht angenommen.

**Was ich mitnehme:** Ein Schritt, der „ok" meldet, hat nichts bewiesen. Annahmen gehören in
Parametertabellen mit einer Spalte `geprueft`, nicht als Konstanten ins SQL — und die Prüfung
hat zwei meiner Werte tatsächlich korrigiert.

---

## 12 · Was offen bleibt

1. **Emissionsfaktoren der Kraftwerke** sind Größenordnungen, keine zitierten Werte
   (`core.emissionsfaktor.geprueft = false`). Sie liegen als Parametertabelle vor; ein
   Austausch gegen die UBA-Emissionsbilanz rechnet die Kennzahl neu, ohne eine Abfrage
   anzufassen.
2. **Biomasse steht bilanziell auf 0 g/kWh.** Konsistent mit der Systemgrenze „nur
   Verbrennung am Ort", die auch für den Auspuffwert gilt — aber eine Wahl.
3. **Keine Vorkette auf beiden Seiten.** Weder Raffinerie noch Kraftwerksbau. Für den
   *Vergleich* sauber, für eine absolute Klimabilanz nicht ausreichend.
4. **Der BEV-Realverbrauch bleibt ungemessen.** Diese Lücke lässt sich mit den vorliegenden
   Quellen nicht schließen; sie wäre der nächste Datenbedarf.
5. **`star.ziel_parameter`** trägt durchgängig `geprueft = false`. Die Zielfunktion der
   Flottenregulierung ist als Näherung implementiert.

---

## 13 · Ausblick

- Der Utility Factor wird bis 2027/28 auf rund 34 % abgesenkt. Die Messung sollte danach
  wiederholt werden, um die Wirkung der Regeländerung zu prüfen. Der gemessene Istwert von
  25,8 bis 27,0 % liegt **unter** der neuen Annahme — die Absenkung könnte nicht ausreichen.
- Ab 2023 fließen auch Daten aus der Hauptuntersuchung ein. Der vorliegende Datensatz enthält
  ausschließlich OEM-Meldungen; ein Vergleich beider Meldewege wäre aufschlussreich.
- Das Regressionsmodell ist der Anschlusspunkt für weitere Arbeit: saubere Zielgröße,
  erklärbare Merkmale, SHAP direkt aufsetzbar. Der interessante Weg führt aber nicht über
  ein stärkeres Modell, sondern über **bessere Merkmale** — Ladehäufigkeit, Fahrprofil,
  Halterstruktur. Diese Daten existieren, nur nicht öffentlich.

---

## 14 · Reproduzierbarkeit

Ein Aufruf baut das gesamte Projekt neu:

```
.\03_skripte\99_run_all.ps1
```

Zwölf Schritte, jeder mit eigener Ausgabedatei in `00_doku/`. Die Laufzeiten landen in
`00_doku/_laufzeiten.csv` und stehen in Abschnitt 7 dieses Dokuments. Bricht ein Schritt ab,
hält die Kette an und nennt die fehlerhafte Datei; mit `-Ab <Schritt>` wird fortgesetzt.
