# Zeitplan Endspurt

Stand: Dienstag, 11.08.2026, 21:45

**Abgabe: Donnerstag 13.08., 12:00 Uhr. Prüfung um 10:00 Uhr (max. 1 h).**
Damit ist **Mittwoch der 12.08. der letzte volle Arbeitstag.** Donnerstagvormittag ist
Puffer für Export und Upload, nicht für Inhalte.

---

## Was steht

| | |
|---|---|
| Daten | 44.930.718 Zeilen, 8,2 GB, vollständig heruntergeladen und geprüft |
| SQL | 13 Dateien, ~250 Statements, geparst — **noch nie ausgeführt** |
| Skripte | 8 PowerShell, 2 Python, alle syntaxgeprüft |
| Dokumentation | Logbuch, Datenlandkarte, Verifikationsprotokoll, Qualitätsbefunde, Ergebnisdokument |
| Abgaben | CAT vollständig geschrieben, NvS-Gerüst mit Abhängigkeitstabelle |
| Ergebnisse | H1 belegt, H2 korrigiert und neu gefasst |

## Was fehlt

| # | Schritt | Aufwand | wer |
|---|---|---|---|
| 1 | SQL-Kette ausführen und Fehler beheben | 3–5 h | Maschine + gemeinsam |
| 2 | SMARD laden, Well-to-Wheel rechnen | 1 h | Maschine |
| 3 | KNIME-Workflow bauen | 2–4 h | **nur Alex** |
| 4 | NvS aus den echten Ausgaben ausformulieren | 2–3 h | Claude |
| 5 | CAT in die educX-Vorlage übertragen | 1 h | Alex |
| 6 | Präsentation + Vortragsskript | 1,5 h | Claude, Feinschliff Alex |
| 7 | GitHub-Repo | 0,5 h | Alex |
| 8 | Streamlit-App | 1–2 h | **darf entfallen** |

---

## Dienstagabend (heute, Claude allein)

Alles vorbereiten, was keine ausgeführte Datenbank braucht:

- [x] Ketten-Runner `99_run_all.ps1` — ein Befehl statt neun, mit Wiederaufsetzpunkt
- [ ] KNIME-Anleitung Knoten für Knoten
- [ ] Präsentationsgliederung und Vortragsskript
- [ ] Repo-README mit Reproduktionsanleitung
- [ ] Streamlit-App (niedrigste Priorität)

## Mittwoch — Stundenplan

| Zeit | Alex | Claude |
|---|---|---|
| **08:00** | `99_run_all.ps1 -OhneSmard` starten | wartet auf erste Ausgaben |
| 08:00–11:00 | Fehlerausgaben durchreichen | Fehler beheben, Kette am Laufen halten |
| **11:00** | SMARD-Schritte starten | Ergebnisse gegen die Vorab-Auswertung prüfen |
| 11:00–15:00 | **KNIME-Workflow** nach Anleitung | NvS-Ergebniskapitel aus den echten Zahlen |
| **15:00** | Modellgüte durchgeben | NvS fertigstellen, Präsentation bauen |
| 15:00–17:00 | CAT in die Vorlage, Repo anlegen | Vortragsskript, letzte Belege einsammeln |
| **17:00** | Gegenlesen | Korrekturen |
| ab 18:00 | Puffer | Streamlit, falls Zeit bleibt |

## Donnerstag

| Zeit | |
|---|---|
| 08:00–09:30 | Export nach docx/pdf, Dateinamen prüfen, Upload vorbereiten |
| 10:00–11:00 | **Prüfung** |
| 11:00–12:00 | Upload, Abgabe |

---

## Die drei Punkte, an denen es kippen kann

1. **Die SQL-Kette bricht früh und wiederholt.** Wahrscheinlichster Kandidat ist
   `30_star.sql`: Die Dimensions-Joins arbeiten mit `IS NOT DISTINCT FROM`, damit
   NULL-Werte matchen — wenn dort etwas nicht greift, verliert die Faktentabelle Zeilen.
   Die eingebaute Zeilenkontrolle core ↔ star meldet das sofort.
   *Gegenmaßnahme:* `-Ab 30_star` setzt hinter dem Laden wieder auf, der Load muss nicht
   wiederholt werden.

2. **Der Staging-Load dauert länger als gedacht.** 37,1 Mio. Zeilen über `\copy`.
   *Gegenmaßnahme:* früh starten, parallel an KNIME arbeiten.

3. **KNIME frisst den Nachmittag.** Es ist GUI-Arbeit und lässt sich nicht abkürzen.
   *Gegenmaßnahme:* Die Anleitung nennt jeden Knoten mit Einstellungen. Wenn es um 15:00
   nicht steht, auf das Minimum reduzieren: DB Connector → DB Query Reader → GroupBy →
   Bar Chart. Das erfüllt den Kursbezug, das Regressionsmodell ist die Kür.

## Reihenfolge der Abgaben nach Wichtigkeit

1. **NvS** — das umfangreichste Dokument, trägt die Bewertung
2. **CAT** — kurz, aber formal verlangt
3. **Präsentation** — ersetzt notfalls die Streamlit-App
4. **GitHub-Repo** — Reproduzierbarkeit
5. Streamlit-App — Kür, entfällt im Zweifel
