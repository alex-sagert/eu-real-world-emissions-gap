# Das Projekt in zehn Minuten verstehen

Diese Datei erklärt das Projekt ohne Fachbegriffe. Sie ist der Einstieg — alles
andere in `00_doku/` geht in die Tiefe.

---

## 1 · Die Grundidee in vier Sätzen

Jedes Auto hat einen Verbrauchswert auf dem Papier. Der stammt aus einem
Labortest und entscheidet über Steuer, Förderung und die CO₂-Ziele der Hersteller.

Seit 2021 hat jedes neue Auto in der EU außerdem einen **Zähler an Bord**, der
den tatsächlichen Verbrauch mitschreibt. Die Hersteller müssen diese Werte an die
EU-Kommission melden.

**Damit gibt es für dasselbe Auto zwei Zahlen: eine versprochene und eine
gemessene.** Der Unterschied zwischen beiden ist das gesamte Thema dieses Projekts.

Ich habe beide Datenbestände heruntergeladen, zusammengeführt und ausgerechnet,
wie groß der Unterschied ist — für 45 Millionen Datensätze.

---

## 2 · Warum das nicht trivial ist

Wenn beide Zahlen einfach nebeneinander in einer Tabelle stünden, wäre das eine
Excel-Aufgabe. Sie stehen aber nicht nebeneinander:

| Problem | Was ich tun musste |
|---|---|
| Die Zulassungsdaten gibt es nicht als Datei zum Herunterladen | Eine eigene Ladepipeline gegen eine Programmierschnittstelle bauen |
| 45 Millionen Zeilen passen in kein Tabellenprogramm | Eine Datenbank aufsetzen und die Daten in Schichten strukturieren |
| Die Rohdaten sind unsauber und uneinheitlich | Typisierung, Filter und Qualitätsprüfungen schreiben |
| Ein Elektroauto hat keinen Kraftstoffzähler | Für den fairen Vergleich den Strommix aus einer dritten Quelle holen |

Das ist die eigentliche Arbeit. Das Rechnen am Ende ist der kleinste Teil.

---

## 3 · Die Fachbegriffe, die du kennen musst

Mehr sind es nicht.

**WLTP** — der Labortest, aus dem der Wert auf dem Papier stammt. Ein
standardisierter Fahrzyklus auf einem Rollenprüfstand.

**OBFCM** — *On-Board Fuel Consumption Meter*. Der Zähler im Auto, der den echten
Verbrauch mitschreibt. Die Datenquelle für die „Straße"-Werte.

**Utility Factor** — die Annahme in der WLTP-Regel, **wie oft ein
Plug-in-Hybrid geladen wird**. Die Regel unterstellt rund 84 Prozent elektrische
Fahrleistung. Das ist der Kern des ganzen Befunds — siehe Abschnitt 5.

**Well-to-Wheel** — „von der Quelle bis zum Rad". Bei einem Elektroauto kommt am
Auspuff nichts heraus, aber im Kraftwerk schon. Well-to-Wheel rechnet den
Strom mit, damit der Vergleich fair wird.

**Median** — der mittlere Wert, wenn man alle Fahrzeuge der Größe nach sortiert.
Ich benutze ihn statt des Durchschnitts, weil einzelne Extremfahrzeuge einen
Durchschnitt stark verzerren, den Median aber nicht.

**Sternschema** — die Art, wie die Datenbank aufgebaut ist. Eine große Tabelle
mit Zahlen in der Mitte, drumherum kleine Tabellen mit den Bezeichnungen
(Hersteller, Modell, Antrieb). Spart Platz und macht Auswertungen schnell.

---

## 4 · Was ich gebaut habe, in der Reihenfolge

```
1. Herunterladen        Programmierschnittstelle der EU-Umweltagentur
                        → 37,1 Mio. Zulassungen + 7,8 Mio. Messwerte als CSV

2. Rohschicht (raw)     Alles unverändert in die Datenbank, alle Spalten als Text.
                        Nichts wird geprüft — was kaputt ist, bleibt sichtbar.

3. Kernschicht (core)   Typen setzen, auf Pkw filtern, Antriebsart ableiten.
                        Hier entstehen die eigentlichen Kennzahlen je Fahrzeug.

4. Sternschema (star)   Faktentabelle plus fünf Dimensionstabellen.
                        Nach Jahr aufgeteilt, damit Abfragen schnell bleiben.

5. Ergebnisse (mart)    Eine Tabelle je Auswertung. Das ist, was KNIME liest.
```

Jeder Schritt ist eine eigene Datei. Ein einziger Aufruf führt alle aus:
`.\03_skripte\99_run_all.ps1`

---

## 5 · Die Ergebnisse — was du wirklich sagen musst

### Ergebnis 1: Verbrenner weichen moderat ab

Benziner verbrauchen real **16 Prozent** mehr als auf dem Papier, Diesel
**17 Prozent**, Hybride ohne Stecker **19 Prozent**.

Das ist spürbar, aber niemanden vom Hocker reißend. Reifen, Fahrstil,
Kurzstrecke — dafür gibt es normale Erklärungen.

### Ergebnis 2: Plug-in-Hybride weichen um das Fünffache ab

**320 Prozent.** Auf dem Papier 1,40 Liter, auf der Straße 6,06 Liter.

### Ergebnis 3: Und hier ist der Grund

Ein Plug-in-Hybrid hat zwei Antriebe. Wie sparsam er ist, hängt fast
ausschließlich davon ab, **wie oft er geladen wird**. Die WLTP-Regel muss dafür
eine Annahme treffen — und sie unterstellt rund **84 Prozent** elektrische
Fahrleistung.

Gemessen wurden in Deutschland **26 Prozent**. In keinem einzigen der 27
EU-Länder kommt der Wert auch nur in die Nähe von 84 Prozent.

> **Der Plug-in-Hybrid ist nicht schlecht gebaut. Er wird nicht geladen.**

Das ist der Satz, um den sich das ganze Projekt dreht. Wenn du nur einen
mitnimmst, dann diesen.

### Ergebnis 4: Trotzdem bleibt der Plug-in-Hybrid vorn

Das war meine Überraschung — ich hatte das Gegenteil erwartet.

Rechnet man den Netzstrom mit dem realen deutschen Strommix mit, kommt der
Plug-in-Hybrid auf **160,8 g CO₂/km**, der reine Benziner auf **169,4**. Er
bleibt also sparsamer.

Aber: Zertifiziert sind **31,0**. Sein Vorsprung ist real also nur etwa ein
Zehntel so groß wie auf dem Papier.

### Ergebnis 5: Zwischen einzelnen Autos kippt es sehr wohl

Auf der Ebene konkreter Modelle stimmt meine ursprüngliche These:

| | auf dem Papier | auf der Straße |
|---|---:|---:|
| BMW 116d (Diesel) | 4,60 l | 5,44 l |
| MG EHS Plug-in-Hybrid | 1,80 l | 8,58 l |

Der Diesel sollte laut Typprüfung 2,6-mal schlechter sein. Real verbraucht er
3,14 Liter weniger. **In 20,9 Prozent aller verglichenen Modellpaare dreht sich
die Rangfolge auf der Straße um.**

### Ergebnis 6: Das Elektroauto ist nicht emissionsfrei — aber klar vorn

Die Verordnung schreibt **0 g/km** vor. Mit dem realen deutschen Strommix sind
es **66,7**. Auch im ungünstigsten Szenario liegt es bei 44 Prozent des besten
Verbrenners.

---

## 6 · Wenn du in der Prüfung nur drei Dinge sagen kannst

1. **„Es sind dieselben Fahrzeuge."** Nicht Labor gegen Umfrage, sondern Labor
   gegen Messung am selben Auto, verbunden über die Typgenehmigungsnummer.
   Deshalb ist die Lücke belastbar.

2. **„Die Ursache ist eine Verhaltensannahme, keine Technik."** Die Regel
   unterstellt 84 Prozent Ladeanteil, gemessen sind 26. Nicht der Motor weicht
   ab, sondern die Annahme über den Fahrer.

3. **„Meine Hypothese war zur Hälfte falsch, und das steht so im Bericht."**
   Auf Flottenebene bleibt der Plug-in-Hybrid vorn. Auf Modellebene kippt es in
   jedem fünften Fall. Beides ist belegt.

---

## 7 · Die Fragen, die kommen könnten

**„Warum PostgreSQL und nicht Excel?"**
45 Millionen Zeilen. Excel kann rund eine Million je Blatt. Und ohne
Partitionierung und Indizes würde jede Auswertung Minuten statt Sekunden dauern.

**„Warum kein MongoDB oder Neo4j, das war doch im Kurs?"**
Weil die Daten durchgängig tabellarisch sind. Es gibt keine schemalosen
Dokumente und keine Netzstruktur, deren Verfolgung etwas bringen würde. Ein
Einsatz wäre Selbstzweck gewesen. Das steht so im CAT unter (K).

**„Wie können Sie sicher sein, dass die Zahlen stimmen?"**
Drei Wege: Die Zeilenzahl zwischen den Schichten stimmt exakt überein
(Differenz null). Die Emissionsfaktoren wurden gegen die von der EU-Umweltagentur
selbst verwendeten Werte gegengerechnet — dabei hat sich einer meiner Werte als
falsch erwiesen und wurde korrigiert. Und jede Zahl im Bericht stammt aus einer
ausgeführten Abfrage, deren Ausgabe im Projektordner liegt.

**„Was war das größte technische Problem?"**
Der Aufbau des Sternschemas lief anfangs mit 15 Megabyte pro Minute — sechs
Stunden hochgerechnet. Ursache war ein Vergleichsoperator, den die Datenbank
nicht optimieren kann. Nach dem Umbau: 1,3 Gigabyte pro Minute, zehn Minuten
Gesamtlaufzeit. Faktor 85, ohne Hardwareänderung.

**„Was würden Sie beim nächsten Mal anders machen?"**
Prüfschritte von Anfang an einbauen. Sechs meiner 17 Fehler waren stumm — sie
haben kein Programm abstürzen lassen, sondern falsche oder leere Ergebnisse
geliefert, während jeder Schritt „ok" meldete. Gefunden habe ich sie nur, weil
ich die Ausgaben gelesen und Größenordnungen geprüft habe.

---

## 8 · Wo was liegt

| Ordner | Inhalt |
|---|---|
| `00_doku/` | Diese Datei, Ergebnisse, Qualitätsbefunde, Fehlerprotokoll, alle Ausgaben |
| `01_daten/` | Rohdaten (nicht im Repository — mit einem Aufruf reproduzierbar) |
| `02_sql/` | 17 SQL-Dateien, in Ausführungsreihenfolge nummeriert |
| `03_skripte/` | Download-, Lade- und Steuerskripte |
| `04_knime/` | Der KNIME-Workflow und die Anleitung dazu |
| `05_visualisierung/` | Diagramme und Datenbankmodelle als Bilder |
| `06_abgabe/` | CAT, Bericht, Präsentation |
