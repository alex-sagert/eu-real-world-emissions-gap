# Ergebnis — Die Realverbrauchslücke (A4, H1 und H2)

Stand 10.08.2026 · Datenbasis: EEA OBFCM `2023_Cars_Raw.csv`,
Fassung `eea_t_real-world-co2-emission_p_2024_v03_r00`, DOI 10.2909/7472e340-2766-4461-b83f-d63e2d81edc7

> **Vorläufigkeitsvermerk.** Die Zahlen unten stammen aus einer Vorab-Auswertung der
> Rohdatei, noch nicht aus der PostgreSQL-Pipeline. Sie werden mit `41_analysen_A4_A5.sql`
> reproduziert, sobald `core.realworld` geladen ist. Erst die dortigen Werte gehen in den Bericht.
> Die Methodik ist identisch, Abweichungen wären ein Fehlersignal.

---

## 1 · Datenbasis und Filter

| | |
|---|---|
| Zeilen in der Rohdatei | **7.791.120** |
| Meldeweg | **ausschließlich `OEM`** — kein einziger Satz aus der Hauptuntersuchung |
| Abdeckung | Zulassungsjahrgänge 2021 (2.519.430), 2022 (2.594.380), 2023 (2.055.278) |
| Von der EEA selbst als verwendbar markiert (`Used in calculation = 1`) | **6.515.134 (83,6 %)** |
| Von der EEA ausgeschlossen (`= 0`) | **1.275.986 (16,4 %)** |
| Ohne WLTP-Referenzwert (`Fuel consumption` leer) | 552.870 |
| Deutschland | **1.977.119** — größter Einzelmarkt vor FR (1.462.653) und IT (1.247.416) |

**Filterentscheidungen, beide begründungspflichtig im Bericht:**

1. **`Used in calculation = 1` wird übernommen.** Die EEA hat die Plausibilitätsprüfung
   bereits vorgenommen; sie zu ignorieren wäre eine stillschweigende Abweichung von der
   Referenzmethodik. Die 16,4 % Ausschluss werden genannt, nicht versteckt.
2. **Mindestlaufleistung 1.000 km.** Ein Fahrzeug mit 9,8 km Lebensdauerstrecke — solche
   Sätze stehen in der Datei — erzeugt einen Verbrauchswert ohne Aussagekraft. Ohne diesen
   Filter verzerren Einzelfälle die Verteilung. Deshalb zusätzlich **Median statt
   Mittelwert** und die Angabe des P90.

## 2 · Zwei Datenqualitätsbefunde

**2.1 · `Ft` ist uneinheitlich geschrieben.**
4.872.859 Sätze führen `petrol`/`diesel` klein, 2.918.261 führen `PETROL`/`DIESEL` groß.
Die naheliegende Erklärung — zwei Meldewege — trägt **nicht**: alle 7.791.120 Sätze kommen
über `OEM`. Es ist also ein reiner Konsistenzmangel innerhalb desselben Kanals.
→ In `core.realworld` wird `Ft` mit `lower()` normalisiert. Ohne das zerfällt jede
Gruppierung in zwei Hälften und alle Kennzahlen wären halbiert.

**2.2 · 622.032 Zeilen (8,0 %) enthalten Kommas in Anführungszeichen.**
Beispiel aus der Typspalte: `"XG1TJ(JP,M)"`. Die Datei ist korrekt RFC-4180-quotiert;
`COPY ... WITH (FORMAT csv)` verarbeitet das richtig. Jedes naive Trennen am Komma —
etwa mit `awk -F','` — verschiebt bei diesen Zeilen alle Folgespalten und schreibt
Zahlenwerte in die Kraftstoffspalte. Beim ersten Auswertungsversuch ist genau das
passiert und wurde erst durch die Prüfung der Feldanzahl je Zeile sichtbar
(32 Felder: 7.169.088 · 33 Felder: 622.017 · 34 Felder: 15).

## 3 · Ergebnis Deutschland

Median über 1.608.112 deutsche Fahrzeuge, `Used in calculation = 1`, Laufleistung ≥ 1.000 km.
Verbrauch in l/100 km. Die prozentuale Lücke ist unabhängig vom CO₂-Umrechnungsfaktor und
deshalb die robustere Kennzahl.

| Antriebsklasse | Fahrzeuge | ⌀ Laufleistung | **real** | **WLTP** | **Lücke Median** | **Lücke P90** |
|---|---:|---:|---:|---:|---:|---:|
| Benzin rein | 564.918 | 15.892 km | 7,44 | 6,40 | **+16,0 %** | +34,8 % |
| Benzin Hybrid | 235.746 | 13.416 km | 7,07 | 5,80 | +17,9 % | +37,6 % |
| Diesel rein | 410.135 | 30.677 km | 6,59 | 5,60 | +16,6 % | +32,3 % |
| Diesel Hybrid | 173.344 | 30.207 km | 7,08 | 5,90 | +19,8 % | +37,1 % |
| **PHEV Benzin** | 192.369 | 17.537 km | 6,00 | 1,30 | **+317,8 %** | **+632,0 %** |
| **PHEV Diesel** | 31.600 | 42.373 km | 6,27 | 1,40 | **+335,5 %** | **+852,8 %** |

EU-weit (alle Länder, gleiche Filter) fällt das Bild identisch aus: Verbrenner 15–21 %,
PHEV Benzin +321,8 %, PHEV Diesel +300,6 % bis +374,8 %.

---

## 4 · H1 — bestätigt, und zwar deutlich

> **H1:** Die Lücke zwischen Prüfstand und Straße ist bei Plug-in-Hybriden dramatisch
> größer als bei reinen Verbrennern.

Ein reiner Verbrenner verbraucht real **16–20 %** mehr als im Labor. Ein Plug-in-Hybrid
verbraucht real **rund das Vier- bis Viereinhalbfache** seines Laborwerts. Der Unterschied
ist nicht graduell, sondern eine andere Größenordnung — und er ist über 224.000 deutsche
PHEV gemessen, nicht geschätzt.

Beim P90 wird es noch deutlicher: Jeder zehnte Benzin-PHEV in Deutschland liegt bei
**mehr als dem Siebenfachen** seines Laborwerts, jeder zehnte Diesel-PHEV bei mehr als dem
Neunfachen. Bei reinen Verbrennern liegt dieselbe Grenze bei +33 bis +38 %.

Die Größenordnung deckt sich mit dem Briefing von Transport & Environment (Faktor ~5).
Die eigene Rechnung liegt mit Faktor 4,2 etwas darunter — plausibel, weil hier der Median
und nicht der Mittelwert verwendet wird.

---

## 5 · H2 — **nicht** bestätigt. Das muss so berichtet werden.

> **H2 (Kern):** Ein moderner Diesel oder Benziner ist real ehrlicher als ein PHEV;
> die offizielle Rangfolge kehrt sich teilweise um.

Der erste Halbsatz stimmt, der zweite nicht.

**Der PHEV ist real weiterhin sparsamer als der reine Benziner** — 6,00 gegen 7,44 l/100 km
in Deutschland. Die Rangfolge kehrt sich beim Kraftstoffverbrauch **nicht** um. Wer H2 in
dieser Form behauptet, wird von den Daten widerlegt.

Was sich stattdessen zeigt, ist eine andere, ebenso belastbare Aussage:

| | Benzin rein | PHEV Benzin | Verhältnis |
|---|---:|---:|---:|
| auf dem Papier (WLTP) | 6,40 l | 1,30 l | **4,92 ×** |
| auf der Straße | 7,44 l | 6,00 l | **1,24 ×** |

**Vom versprochenen Vorsprung des Plug-in-Hybrids bleiben auf der Straße rund 25 % übrig.
Etwa vier Fünftel des Vorteils, mit dem er zertifiziert und gefördert wurde, verdampfen.**

Das ist die tragfähige Version des Befunds, und sie ist politisch nicht schwächer als die
ursprüngliche Behauptung — nur präziser.

### Was dieser Befund nicht sagt

- **Er enthält den Netzstrom des PHEV nicht.** Die 6,00 l/100 km sind reiner Kraftstoff.
  Der PHEV zieht zusätzlich Strom aus der Steckdose (`Total grid energy into the battery`
  steht je Fahrzeug in der Datei). Well-to-Wheel mit dem deutschen Strommix aus SMARD kann
  das Bild noch einmal drehen — **in beide Richtungen**. Genau deshalb ist das SMARD-Modul
  fest eingeplant und nicht optional.
- **Er vergleicht keine baugleichen Fahrzeuge.** PHEV sind im Schnitt schwerer und stärker
  motorisiert als der durchschnittliche Benziner. Ein Teil der 6,00 gegen 7,44 l ist
  Fahrzeugklasse, nicht Antriebstechnik. Die Regression in KNIME (Tag 4) kontrolliert dafür.
- **Er sagt nichts über einzelne Fahrer.** Ein PHEV, der täglich geladen wird, kann den
  Laborwert erreichen. Der Median beschreibt die Flotte, nicht den Einzelfall — genau das
  ist der Punkt der Regulierung, die den Utility Factor von 84 % auf rund 34 % senkt.

---

## 6 · Nebenbefund: der Hybrid ist keine Verbesserung, wenn er schwer ist

Diesel-Hybride haben mit **+19,8 %** die *größte* Lücke aller nicht-ladbaren Antriebe —
größer als der reine Diesel (+16,6 %). Zusammen mit dem Befund aus der Kreuztabelle
(Diesel-Hybrid ⌀ 155,9 g/km gegen reiner Diesel 150,1 g/km bei 271 kg Mehrgewicht) ergibt
das ein konsistentes Bild: Hybridisierung wird im Dieselsegment fast ausschließlich in
schweren Fahrzeugen verbaut und kompensiert dort die Masse, statt Verbrauch zu senken.
Das ist H4 im Kleinen und gehört in die Diskussion.

---

## 7 · Reproduktion durch die Pipeline — mit einer Abweichung

Die Vorabwerte oben stammten aus einer Einzelabfrage. `41_analysen_A4_A5.sql` hat sie
reproduziert, aber nicht auf die Nachkommastelle:

| | Vorab | Pipeline (A4) | Pipeline (A4a2) |
|---|---:|---:|---:|
| Benzin rein | +16,0 % | +16,5 % | *gepoolt* |
| PHEV Benzin | +317,8 % | +352,9 % | *gepoolt* |

**Das ist kein Pipelinefehler, sondern ein Methodenunterschied.** Die Zusammenfassung in A4
bildet `avg()` über die Jahresmediane — 2021, 2022 und 2023 zählen gleich viel, obwohl 2022
rund 120.000 PHEV enthält und 2023 nur 27.000. Die Vorabauswertung hat den Median über alle
Fahrzeuge gemeinsam gebildet.

Beide Zahlen sind richtig, sie beantworten verschiedene Fragen. **Maßgeblich ist der
gepoolte Median** (Abfrage A4a2), weil er jedes Fahrzeug gleich gewichtet — und genau das
ist die Aussage von H1. Die Differenz wird hier offengelegt statt stillschweigend angeglichen.

---

## 8 · Well-to-Wheel: H2 ist entschieden

Datenstand 12.08.2026, Deutschland, Strommix aus SMARD (Jahresmittel **355,6 g/kWh** über
2021–2025), BEV-Szenario „mittel" (+15 % auf den Laborwert).

| Antrieb | Quelle Realwert | Papier | Auspuff real | Strom | **Well-to-Wheel** | vs. Papier |
|---|---|---:|---:|---:|---:|---:|
| BEV | WLTP Laborwert | 0,0 | — | 66,7 | **66,7** | *nicht definiert* |
| PHEV | OBFCM gemessen | 31,0 | 138,9 | 21,9 | **160,8** | +419 % |
| ICE Benzin | OBFCM gemessen | 144,0 | 169,4 | 0 | **169,4** | +18 % |
| HEV | OBFCM gemessen | 141,0 | 171,4 | 0 | **171,4** | +22 % |
| ICE Diesel | OBFCM gemessen | 146,0 | 173,3 | 0 | **173,3** | +19 % |

### H2 ist widerlegt — deutlicher als zuvor

Der Plug-in-Hybrid bleibt auch bei fairer Rechnung **mit** realem Netzstrom vorn: 160,8 gegen
169,4 g/km beim reinen Benziner. Die Sensitivitätsrechnung zeigt, wo die Grenze liegt:

| Strommix g/kWh | PHEV gesamt | Benziner | Ergebnis |
|---:|---:|---:|---|
| 350 | 160,6 | 169,4 | PHEV besser |
| 450 | 166,8 | 169,4 | PHEV besser |
| **500** | **169,9** | **169,4** | **PHEV schlechter** |
| 600 | 176,1 | 169,4 | PHEV schlechter |

Die Kippgrenze liegt bei rund 500 g/kWh. Der deutsche Mix liegt bei 355,6 und **fällt**
(371,8 in 2021 auf 321,9 in 2025). Die Rangfolge dreht sich nicht und wird sich mit weiter
sinkender Stromintensität eher festigen.

### Was sich stattdessen zeigt

Der offizielle PHEV-Wert von 31,0 g/km unterschätzt die Realität um den **Faktor 5,2**. Der
Vorsprung ist echt, aber er ist etwa ein Zehntel so groß wie zertifiziert. Für die
Flottenregulierung ist das der entscheidende Punkt: Angerechnet werden 31, gefahren werden 161.

### Der härteste Einzelbefund

Für das Batterieauto schreibt die Verordnung **0 g/km** vor. Mit dem realen deutschen
Strommix sind es **66,7 g/km**. Die Prozentspalte bleibt leer, weil sich durch null nicht
teilen lässt — die Regulierung kennt für diese Antriebsart schlicht keinen Bezugswert.

Über alle drei Aufschlagsszenarien bewegt sich der Wert zwischen **58,0 und 75,4 g/km**.
Selbst im ungünstigsten Fall liegt das BEV bei **44 %** des besten Verbrenners. **Diese
Aussage hängt nicht an meiner Annahme** — das ist der Zweck der Szenariorechnung.

### Einschränkung, die mitgelesen werden muss

Die BEV-Zeile stammt aus der **WLTP-Typprüfung**, alle anderen Zeilen aus gemessenem
Realverbrauch. OBFCM ist ein Kraftstoff-Verbrauchsmesser; ein Batterieauto hat keinen und
ist in dieser Quelle nicht enthalten. Der Vergleich ist deshalb **nicht gleichwertig**. Die
Tabelle `mart.wtw_vergleich` führt dafür die Spalte `quelle_real`, die jede Zeile kennzeichnet.

---

## 9 · Regression (KNIME): Was erklärt die Lücke?

Lineare Regression, 70/30-Aufteilung, Seed 1234, Zielgröße `gap_pct`.

| | Modell 1 — alle Antriebe | Modell 2 — nur PHEV |
|---|---:|---:|
| R² | 0,736 | 0,581 |
| adjustiertes R² | 0,736 | 0,581 |
| MAE | 27,8 PP | 103,8 PP |
| RMSE | 58,3 PP | 147,3 PP |
| mittlere vorzeichenbehaftete Abweichung | −0,128 | +0,954 |

**Modell 1 ist der weniger interessante Fall.** Ein R² von 0,736 über alle Antriebe hinweg
sieht gut aus, sagt aber vor allem: Die Antriebsklasse allein erklärt die Lücke fast. Das war
vor der Rechnung absehbar und ist kein Erkenntnisgewinn.

**Modell 2 ist die eigentliche Aussage.** Innerhalb der Plug-in-Hybride — gleiche
Antriebsart, kontrolliert für Masse, Leistung, Hubraum, elektrische Reichweite, geladenen
Netzstrom und elektrischen Fahranteil — bleiben **42 % der Streuung unerklärt**. Bei einem
MAE von 104 Prozentpunkten auf einem Median von rund 350 % heißt das:

> **Die PHEV-Lücke ist zu einem erheblichen Teil keine Fahrzeugeigenschaft.** Was das Modell
> nicht sieht, ist das Ladeverhalten der Halterin oder des Halters — und genau diese Größe
> steht in keiner Zulassungsdatenbank.

Die mittlere vorzeichenbehaftete Abweichung liegt in beiden Modellen nahe null (−0,13 bzw.
+0,95). Die Modelle schätzen also nicht systematisch zu hoch oder zu niedrig; der Fehler ist
Streuung, keine Verzerrung.

**MAPE ist in Modell 1 nicht berechenbar** (`NaN`), weil einzelne Testzeilen eine Lücke von
exakt 0 % haben und die Kennzahl durch den Istwert teilt. KNIME meldet das als Warnung. Das
ist keine Fehlfunktion, sondern eine Eigenschaft der Kennzahl — MAE und RMSE sind hier die
belastbaren Maße.

---

## 10 · Geprüfte Annahmen

| Annahme | Status | Beleg |
|---|---|---|
| Kraftstofffaktor Benzin 2330 g/l | **widerlegt** | EEA rechnet mit 2278 (94 Gruppen, OBFCM und WLTP identisch) — übernommen |
| Kraftstofffaktor Diesel 2640 g/l | **korrigiert** | EEA rechnet mit 2631 (57 Gruppen) — übernommen |
| Strommix-Größenordnung 300–450 g/kWh | **bestätigt** | 371,8 → 321,9 g/kWh, erneuerbar 41,6 → 58,3 % |
| Emissionsfaktoren je Energieträger | **offen** | `core.emissionsfaktor.geprueft = false` für Braun-/Steinkohle, Erdgas, Biomasse |
| BEV-Aufschlag auf den Laborwert | **bewusst offen** | drei Szenarien, Ergebnis kippt in keinem |
| Öko-Innovationsgutschrift ist in `Ewltp` bereits abgezogen | **widerlegt** | Emissionsfaktor in beiden Gruppen identisch — siehe 10a |

### 10a · Ist die Öko-Innovationsgutschrift in `Ewltp` enthalten?

Ausgeführt 13.08.2026, `02_sql/45_oeko_gutschrift_pruefung.sql`, Ausgabe in
`00_doku/45_oeko_ausgabe.txt`.

**Die offene Frage.** Die Rohdaten führen zwei Spalten nebeneinander: `Ewltp` als
zertifizierten CO₂-Wert und `Erwltp` als Gutschrift für Öko-Innovationen. Ob die
Gutschrift in `Ewltp` schon abgezogen ist oder daneben steht, war aus dem
Verordnungstext nicht eindeutig zu entscheiden. Davon hängt ab, ob die
„offiziellen" Werte im Well-to-Wheel-Vergleich systematisch zu hoch ausgewiesen sind.

**Der Test.** CO₂-Wert und Kraftstoffverbrauch stehen in derselben Zeile. Ihr
Quotient ergibt den Emissionsfaktor, mit dem die Behörde selbst rechnet — aus der
Gegenprobe in `42_wtw_vergleich.sql` bekannt als 2278 g/l Benzin und 2631 g/l
Diesel. Ist die Gutschrift abgezogen, muss der Quotient bei Fahrzeugen mit
Gutschrift *niedriger* liegen, und das Zurückaddieren muss ihn wiederherstellen.

| Kraftstoff | Gruppe | Fahrzeuge | Gutschrift g/km | Faktor wie gemeldet | Faktor zurückaddiert |
|---|---|---:|---:|---:|---:|
| Diesel | ohne Gutschrift | 744.992 | 0,00 | 2621,7 | 2621,7 |
| Diesel | **mit** Gutschrift | 1.972.728 | 1,39 | **2622,8** | 2647,7 |
| Benzin | ohne Gutschrift | 1.549.428 | 0,00 | 2270,2 | 2270,2 |
| Benzin | **mit** Gutschrift | 5.037.283 | 1,57 | **2265,7** | 2291,8 |

**Befund: die Gutschrift ist nicht abgezogen.** Der Faktor „wie gemeldet" ist in
beiden Gruppen praktisch identisch — beim Diesel liegt er bei den Fahrzeugen mit
Gutschrift sogar 1,1 Punkte *höher*. Wäre die Gutschrift abgezogen, müsste er bei
Benzin um rund 24 Punkte niedriger liegen (1,57 g/km sind 1,06 % von 148 g/km,
1,06 % von 2270 = 24). Beobachtet sind 4,5 Punkte, und mit umgekehrtem Vorzeichen
beim Diesel — das ist Rauschen, kein Effekt. Das Zurückaddieren schießt in beiden
Fällen über den bekannten Faktor hinaus (2647,7 > 2631; 2291,8 > 2278).

Der Median bestätigt es unabhängig vom Mittelwert: Diesel 2621,2 gegen 2621,6,
Benzin 2270,3 gegen 2265,3.

**Konsequenz.** `Ewltp` ist der roh gemessene Zertifizierungswert. Die Gutschrift
wird erst auf Flottenebene gegen das Herstellerziel gerechnet — genau so, wie es
in A3 umgesetzt ist (`flottenmittel_vor_oeko` gegen `flottenmittel_nach_oeko`).
Die Spalte „offiziell" im Well-to-Wheel-Vergleich bleibt unverändert richtig.

**Größenordnung, falls der Test doch täuscht.** Die Gutschrift beträgt im Mittel
0,90 bis 1,52 g/km, das sind 0,63 bis 1,27 % des CO₂-Werts. Selbst eine falsche
Entscheidung würde die Ergebnisse nicht bewegen — bei einer PHEV-Lücke von
320 % ist ein Prozentpunkt nicht sichtbar.

| Antriebsklasse | Fahrzeuge | CO₂ offiziell | mittlere Gutschrift | Anteil |
|---|---:|---:|---:|---:|
| ICE_BENZIN | 4.569.729 | 148,0 | 1,31 | 0,88 % |
| ICE_DIESEL | 1.965.325 | 154,0 | 1,06 | 0,69 % |
| HEV | 3.090.233 | 143,5 | 0,90 | 0,63 % |
| PHEV | 1.361.130 | 31,5 | **0,00** | **0,00 %** |

**Nebenbefund, der die Hauptaussage stützt.** Plug-in-Hybride tragen überhaupt
keine Öko-Innovationsgutschrift — nicht ein einziges der 1,36 Millionen
Fahrzeuge. Ihr niedriger Zertifizierungswert von 31,5 g/km stammt vollständig aus
dem Utility Factor, nicht aus angerechneter Zusatztechnik. Der zentrale Vergleich
dieser Arbeit ist von der Gutschriftfrage also gar nicht berührt.

**Und ein Randbefund zur Verbreitung:** 52,7 % aller deutschen Neuzulassungen 2025
tragen eine Gutschrift, 2021 waren es 47,1 %, 2023 sogar 60,2 %. Der Mechanismus
ist die Regel, nicht die Ausnahme.

---

## 11a · Hersteller: wer hält sein Versprechen? (A7)

Ausgeführt 12.08.2026, Deutschland, mindestens 3.000 Fahrzeuge je Hersteller.

### Warum die naheliegende Rechnung falsch wäre

Eine Rangliste „Lücke je Hersteller" über die gesamte Flotte misst nicht die
Ehrlichkeit des Herstellers, sondern seinen **Antriebsmix**. Die Prüfung belegt
das mit einer Korrelation von **0,890** zwischen Plug-in-Hybrid-Anteil und
Verzerrung.

Das deutlichste Beispiel ist Mazda: über die ganze Flotte gerechnet 22,7 %
Lücke — Mittelfeld. Auf reine Verbrenner beschränkt **11,4 %** — der beste Wert
im gesamten Feld. Der Unterschied ist ausschließlich der 32,7-prozentige
PHEV-Anteil.

Deshalb gilt: **nur der Vergleich innerhalb derselben Antriebsart ist zulässig.**

### Reine Verbrenner — die belastbare Rangliste

| | Hersteller | Fahrzeuge | WLTP | real | Lücke | Masse | Leistung |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Mazda | 8.198 | 6,90 | 7,63 | **+11,4 %** | 1.555 kg | 135 kW |
| 2 | Porsche | 13.407 | 11,00 | 12,31 | **+11,5 %** | 1.870 kg | 294 kW |
| 3 | Volvo | 4.586 | 7,30 | 8,14 | +12,2 % | 1.625 kg | 120 kW |
| 4 | Audi Sport | 4.258 | 9,90 | 10,90 | +13,1 % | 1.770 kg | 294 kW |
| 6 | Volkswagen | 309.329 | 6,00 | 6,81 | +14,3 % | 1.520 kg | 110 kW |
| … | | | | | | | |
| 21 | Fiat Group | 5.748 | 6,80 | 8,12 | +21,0 % | 1.395 kg | 110 kW |
| 22 | Dacia | 31.220 | 5,60 | 6,93 | +22,2 % | 1.181 kg | 67 kW |
| 23 | Renault | 64.237 | 5,80 | 7,13 | +22,5 % | 1.280 kg | 67 kW |
| 24 | Alfa Romeo | 3.730 | 8,10 | 10,21 | +22,9 % | 1.755 kg | 206 kW |
| 25 | BMW GmbH (M) | 4.866 | 10,70 | 13,46 | **+24,5 %** | 1.975 kg | 375 kW |

25 Hersteller · Spannweite **13,1 Prozentpunkte** · Mittel 17,0 % · Streuung 3,5 pp

### Der überraschende Befund: klein und sparsam heißt große Lücke

Das Ergebnis läuft der Intuition zuwider. **Porsche liegt auf Platz 2** mit
11,5 % — bei 11,0 l Laborwert und 294 kW. **Dacia und Renault liegen auf den
Plätzen 22 und 23** mit über 22 % — bei den leichtesten Fahrzeugen (1.181 kg)
und den kleinsten Motoren (67 kW) des gesamten Feldes.

Die plausibelste Erklärung ist der **Downsizing-Effekt**: Ein kleiner, aufgeladener
Motor arbeitet im sanften Laborzyklus nahe seinem Bestpunkt und sieht dort
hervorragend aus. Im Alltag — Autobahn, Kaltstart, Zuladung — verlässt er diesen
Bereich sofort und verbraucht überproportional mehr. Ein großer Motor ist im
Labor nie am Limit und im Alltag ebenfalls nicht.

**Wichtig für die Auslegung:** Die Lücke ist eine *relative* Größe. Renault
verbraucht real 7,13 l, Porsche 12,31 l. Der Renault bleibt das sparsamere Auto —
er hält nur sein Versprechen schlechter ein. Beides gleichzeitig ist richtig.

Ein Zusatzbeleg steht in derselben Tabelle: Die BMW GmbH (M-Modelle, 375 kW)
liegt mit 24,5 % auf dem letzten Platz. Große Leistung allein erklärt den
Zusammenhang also nicht — es ist die Kombination aus Auslegung und Fahrprofil.

### Plug-in-Hybride: die Reichweite erklärt es nicht

| Hersteller | Fahrzeuge | WLTP | real | Lücke | elektrisch gefahren | E-Reichweite |
|---|---:|---:|---:|---:|---:|---:|
| Chrysler | 2.783 | 2,00 | 7,20 | +191,2 % | 21,4 % | 47 km |
| Ford | 25.402 | 1,10 | 4,81 | +241,6 % | 31,6 % | 71 km |
| BMW AG | 32.007 | 1,70 | 6,89 | +310,7 % | 29,0 % | 55 km |
| Jaguar Land Rover | 4.268 | 2,00 | 8,38 | +336,5 % | **17,4 %** | **110 km** |
| Mercedes-Benz | 80.428 | 1,20 | 6,08 | +347,9 % | 23,4 % | 66 km |
| Volvo | 14.943 | 1,30 | 6,98 | +411,7 % | 23,6 % | 50 km |
| Mazda | 6.679 | 1,50 | 7,83 | **+423,0 %** | 30,2 % | 63 km |

Die naheliegende Vermutung wäre: größere Batterie → mehr elektrische Fahrt →
kleinere Lücke. **Die Daten sagen das Gegenteil.**

| E-Reichweite | Hersteller | Fahrzeuge | Lücke | elektrisch gefahren |
|---|---:|---:|---:|---:|
| 45 bis 60 km | 6 | 56.546 | +274,6 % | 26,8 % |
| über 60 km | 14 | 164.390 | **+316,6 %** | 29,5 % |

Der elektrische Fahranteil steigt mit der Reichweite kaum (26,8 → 29,5 %), die
Lücke dagegen deutlich (274,6 → 316,6 %). Der Extremfall ist Jaguar Land Rover:
**110 km Reichweite, aber nur 17,4 % elektrisch gefahren** — der schlechteste
Ladeanteil im Feld bei der mit Abstand größten Batterie.

> **Eine größere Batterie verbessert den Laborwert, aber nicht das Verhalten.
> Sie vergrößert die Lücke, statt sie zu schließen.**

Das ist die konsequenteste Bestätigung des Utility-Factor-Befunds: Der
Stellhebel ist nicht die Technik, sondern das Laden.

### Der Mixeffekt in Zahlen

| Hersteller | PHEV-Anteil | Lücke gesamt | Lücke nur Verbrenner | Verzerrung |
|---|---:|---:|---:|---:|
| Mazda | 32,7 % | 22,7 % | 11,4 % | **+11,3 pp** |
| Chrysler | 40,8 % | 25,2 % | 14,8 % | +10,4 pp |
| Volvo | 33,5 % | 22,0 % | 12,2 % | +9,8 pp |
| Mercedes-Benz | 26,8 % | 22,8 % | 15,4 % | +7,4 pp |
| Volkswagen | 2,4 % | 14,6 % | 14,3 % | +0,3 pp |
| Dacia | 0,0 % | 22,3 % | 22,2 % | +0,1 pp |

Korrelation zwischen PHEV-Anteil und Verzerrung: **0,890**.

Wer eine Herstellerrangliste ohne diese Korrektur veröffentlicht, bestraft genau
die Hersteller, die früh elektrifiziert haben.

---

## 11 · Was offen bleibt

1. **Emissionsfaktoren der Kraftwerke** sind Größenordnungen, keine zitierten Werte. Sie
   liegen als Parametertabelle vor (`core.emissionsfaktor`); wer sie gegen die
   UBA-Emissionsbilanz austauscht, rechnet die Kennzahl neu, ohne eine Query anzufassen.
2. **Biomasse steht bilanziell auf 0 g/kWh.** Bei Lebenszyklusbetrachtung wäre der Wert
   deutlich größer. Die Wahl ist konsistent mit der Systemgrenze „nur Verbrennung am Ort",
   die auch für den Auspuffwert gilt — aber sie ist eine Wahl.
3. **Keine Vorkette auf beiden Seiten.** Weder die Raffinerie des Kraftstoffs noch der
   Kraftwerksbau sind enthalten. Für den *Vergleich* ist das sauber, für eine absolute
   Klimabilanz nicht ausreichend.
4. **Der BEV-Realverbrauch bleibt ungemessen.** Diese Lücke lässt sich mit den vorliegenden
   Quellen nicht schließen; sie wäre der nächste Datenbedarf.
