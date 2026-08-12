# Fehlerprotokoll

**Projekt:** Papier gegen Straße · Big Data Projektwoche · Alexander Sagert
**Stand:** 12.08.2026

Dieses Dokument listet die Fehler auf, die im Projekt aufgetreten sind, wie sie gefunden
wurden und was daraus folgt. Es ist kein Anhang, sondern Teil des Nachweises.

Der Grund: Eine Pipeline, die angeblich auf Anhieb lief, ist nicht überprüft worden. Zwei der
folgenden Fehler waren **stumm** — sie haben kein Programm zum Absturz gebracht, sondern
falsche oder leere Ergebnisse geliefert, während jeder Schritt „ok" meldete. Solche Fehler
findet man nur, wenn man das Ergebnis gegen etwas hält.

---

## Übersicht

| # | Fehler | Art | Gefunden durch |
|---|---|---|---|
| 1 | ID-Fenster im Downloader 10× zu klein | laut | Laufzeitmessung |
| 2 | `$null`-Rückgabe bei leerem Ergebnis | laut | StrictMode-Abbruch |
| 3 | Zustand nur alle 20 Anfragen gesichert | **stumm** | Nachrechnen der Zeilenzahl |
| 4 | Statusskript sperrte die Zustandsdatei | laut | drei gleichzeitige Abbrüche |
| 5 | CSV-Zeilen verschmolzen nach Wiederaufnahme | **stumm** | Feldzahlprüfung über *alle* Zeilen |
| 6 | Array-Splatting bindet positionell | laut | Parameter landete im falschen Feld |
| 7 | `2>&1` macht NOTICEs zu Fehlern | laut | Abbruch bei harmloser Meldung |
| 8 | Teilnachladung hätte Daten verdoppelt | **stumm** (verhindert) | Durchdenken vor dem Lauf |
| 9 | Numerischer Feldüberlauf, zweimal | laut | PostgreSQL-Fehlermeldung |
| 10 | `IS NOT DISTINCT FROM` ist nicht hashbar | laut | Laufzeit 6 h statt 10 min |
| 11 | Falsche SMARD-Filter-IDs | **stumm** | Plausibilitätsprüfung |
| 12 | KNIME-Factory-Kennungen geraten | laut | KNIME-Fehlermeldung |
| 13 | SMARD-CSV nie geladen | **stumm** | Ergebnistabelle voller Leerwerte |
| 14 | `round(double precision, integer)` | laut | PostgreSQL-Fehlermeldung |
| 15 | `min(ft)` wählt alphabetisch | **stumm** | Widerspruch zweier Ausgaben |
| 16 | BEV fehlte im Vergleich vollständig | **stumm** | leere Spalte in der Szenariotabelle |
| 17 | Fehlende Zahlen brechen den Scorer | laut | KNIME-Fehlermeldung |

---

## Die stummen Fehler im Einzelnen

Die lauten Fehler (1, 2, 4, 6, 7, 9, 10, 12, 14, 17) sind im Logbuch dokumentiert. Sie haben
Zeit gekostet, aber kein Ergebnis verfälscht — ein Programm, das abbricht, liefert keine
falsche Zahl. Die folgenden sechs sind die relevanten.

### 3 + 5 · Verschmolzene CSV-Zeilen nach Wiederaufnahme

**Was passierte.** Der Downloader schrieb die CSV fortlaufend, sicherte seinen Zustand aber
nur alle 20 Anfragen. Nach einem Abbruch setzte er an der gesicherten Stelle wieder auf,
während in der Datei schon mehr stand. Ergebnis: eine verschmolzene Zeile an der Nahtstelle
und rund 113.000 doppelte beziehungsweise fehlende IDs in drei Jahrgängen.

**Warum es fast durchgerutscht wäre.** Meine erste Prüfung zählte die Felder je Zeile — aber
nur für die ersten 200.000 Zeilen. Die Naht lag weiter hinten.

**Konsequenz.** Der Zustand wird nach jedem Fenster gesichert, und beim Wiederaufsetzen wird
die CSV auf den gesicherten Stand **gekürzt**. Prüfungen laufen über die vollständige Datei,
nicht über einen Anfangsausschnitt. Eine Stichprobe am Anfang einer Datei prüft die Stelle,
an der Fehler am unwahrscheinlichsten sind.

### 8 · Teilnachladung hätte die Daten verdoppelt

Ohne `-SkipDdl` verwirft die DDL **alle fünf** Jahrgangstabellen, auch die, die gar nicht neu
geladen werden sollen. Mit `-SkipDdl` hätte ein Nachladen einzelner Jahre an die vorhandenen
Daten **angehängt**. Beide Wege waren falsch, und keiner hätte eine Fehlermeldung erzeugt —
die Zeilenzahl wäre nur zu hoch gewesen.

**Konsequenz.** `TRUNCATE` vor jedem `\copy`. Der Fehler ist nie eingetreten; er ist hier
aufgeführt, weil das Durchdenken vor dem Lauf ihn verhindert hat und nicht der Zufall.

### 11 · Falsche SMARD-Filter-IDs

Die Zuordnung der Filternummern zu den Energieträgern war falsch. Aufgefallen ist es an einer
Plausibilitätsprüfung, die dem Downloader eingebaut war: Biomasse erschien mit 111 MWh
(erwartet rund 4 GW), und „Wasserkraft" traf auf 0 MWh — was Laufwasser nie tut.

**Konsequenz.** Ein Download, der Zahlen liefert, hat noch nichts bewiesen. Die
Größenordnungsprüfung gegen bekanntes Fachwissen gehört in das Ladeskript, nicht in die
spätere Auswertung.

### 13 · Die SMARD-CSV wurde nie geladen

**Was passierte.** Der Downloader holte die Datei, das SQL-Skript legte die Staging-Tabelle
an — aber es gab keinen Schritt dazwischen, der die Datei in die Tabelle lud. Die Auswertung
rechnete auf einer leeren Tabelle weiter: `core.strommix` leer, `mart.strommix_intensitaet`
leer, und der Well-to-Wheel-Vergleich lieferte eine formal vollständige Tabelle aus lauter
Leerwerten. **Alle vier Kettenschritte meldeten „ok".**

**Warum es auffiel.** Die Ausgabe wurde gelesen, nicht nur der Statuszeile geglaubt. Drei
leere Spalten in der Szenariotabelle sind sichtbar, wenn man hinsieht.

**Konsequenz, dreifach.**
1. Ein eigener Ladeschritt (`21_load_smard.ps1`), der die Zeilenzahl und den Zeitraum prüft.
2. `13_smard_strommix.sql` und `42_wtw_vergleich.sql` **brechen ab**, wenn ihr Eingang leer
   ist, statt auf `NULL` weiterzurechnen. Ein leerer Eingang ist ein Abbruch, kein Ergebnis.
3. Beim Laden wird die Spaltenliste aus der **Kopfzeile der CSV** gelesen. Die SMARD-Datei
   liefert `wind_offshore` vor `wasserkraft`, meine Tabellendefinition hatte es umgekehrt.
   Ein positionelles `\copy` hätte Windstrom als Wasserkraft verbucht — und das wäre nie
   aufgefallen, weil beide den Emissionsfaktor 0 g/kWh tragen.

Punkt 3 ist der lehrreichste: Ein Fehler, der sich hinter zwei gleichen Zahlen versteckt,
wird nur durch eine Regel gefunden, nicht durch eine Prüfung des Ergebnisses.

### 15 · `min(ft)` wählt alphabetisch, nicht sachlich

**Was passierte.** Der Kraftstoff-Emissionsfaktor wurde je Antriebsklasse über
`min(r.ft) AS ft_beispiel` gezogen. `min()` auf Text wählt **alphabetisch**. In der
PHEV-Klasse kommen `diesel/electric` und `petrol/electric` vor — `min()` liefert
`diesel/electric`. Die gesamte Plug-in-Hybrid-Flotte wurde also mit dem **Dieselfaktor**
bepreist, obwohl sie überwiegend aus Benzinern besteht. Die HEV-Klasse traf es genauso.

**Warum es auffiel.** Dieselbe Flotte erschien in der Haupttabelle mit 157,7 g/km Auspuff und
in der Sensitivitätsrechnung mit 139,6. Zwei Zahlen für denselben Sachverhalt sind immer ein
Fehler, auch wenn beide für sich plausibel aussehen. Die zweite Ursache dafür war eine
hartkodierte `2330` in der Sensitivitätsrechnung, während die Haupttabelle die Faktortabelle
benutzte.

**Konsequenz.** Der Faktor wird je **Fahrzeug** gezogen und über die Klasse gemittelt, ist
also mit der tatsächlichen Kraftstoffverteilung gewichtet. `mode()` hält zusätzlich fest,
welcher Kraftstoff die Klasse dominiert. Beide Rechnungen lesen denselben Wert aus derselben
Tabelle, und eine Kontrollabfrage prüft die Übereinstimmung explizit. Konstanten stehen in
Parametertabellen, nicht im SQL.

Der HEV-Faktor bestätigt die Korrektur: 2426,8 g/l liegt zwischen Benzin (2278) und Diesel
(2631), weil die Klasse beides enthält.

### 16 · Das Batterieauto fehlte im Vergleich vollständig

**Was passierte.** In `mart.wtw_vergleich` gab es keine BEV-Zeile — ausgerechnet für die
Antriebsart, um die es bei H2 geht. Die drei Szenariozeilen standen leer da.

**Warum.** Der Grund ist sachlich und war mir beim Bauen nicht bewusst: **OBFCM ist ein
Kraftstoff-Verbrauchsmesser.** Ein Batterieauto hat keinen und steht deshalb gar nicht in
`core.realworld`.

**Konsequenz.** Die BEV-Zahlen kommen jetzt aus der Zulassungsstatistik (`Z (Wh/km)` aus der
WLTP-Typprüfung). Das ist ein **Laborwert**, kein gemessener — und der Vergleich ist damit
nicht gleichwertig. Statt das zu verschweigen, führt die Ergebnistabelle die Spalte
`quelle_real`, die jede Zeile als „OBFCM gemessen" oder „WLTP Laborwert" kennzeichnet, und
die Auswertung rechnet drei Aufschlagsszenarien. Das Ergebnis kippt in keinem davon.

---

## Was ich daraus mitnehme

**Ein Schritt, der „ok" meldet, hat nichts bewiesen.** Vier von sechs stummen Fehlern liefen
durch eine Kette, die an keiner Stelle rot wurde. Gefunden wurden sie durch gelesene
Ausgaben, Größenordnungsprüfungen und den Vergleich zweier Rechenwege.

**Zwei Zahlen für denselben Sachverhalt sind immer ein Fehler.** Auch wenn beide plausibel
aussehen. Der Widerspruch ist wertvoller als jede Einzelprüfung, weil er sich nicht
wegdiskutieren lässt.

**Ein leerer Eingang ist ein Abbruch, kein Ergebnis.** `NULL` rechnet sich stillschweigend
durch die gesamte Pipeline und erzeugt am Ende eine formal korrekte, inhaltsleere Tabelle.

**Annahmen gehören in Tabellen, nicht in Abfragen.** Jede Konstante im SQL ist eine Annahme,
die niemand mehr findet. Als Zeile in einer Parametertabelle mit Spalte `geprueft` ist sie
sichtbar, austauschbar und prüfbar — und die Prüfung hat zwei meiner Werte tatsächlich
korrigiert.

**Fremde Kennungen werden gelesen, nicht geraten.** Drei Anläufe bei den KNIME-Factories,
alle drei durch Nachschlagen in einem funktionierenden Workflow beendet. Die erste Vermutung
war jedes Mal falsch.