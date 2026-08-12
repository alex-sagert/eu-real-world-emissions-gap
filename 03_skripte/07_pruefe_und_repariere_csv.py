#!/usr/bin/env python3
"""
Prüft die heruntergeladenen co2cars-CSVs Zeile für Zeile und repariert sie.

Warum das nötig wurde
---------------------
Bei einer Wiederaufnahme, die noch vor dem Einbau der Abschneidelogik lief, blieb
am Dateiende eine halb geschriebene Zeile stehen. Beim Anhängen klebte die nächste
Zeile direkt daran:

    815048,ES,STELLANTIS,OPEL AUTOMOBILE,OPEL AUTOMOBILE765418,ES,KIA,...
                                        ^^^^^^^^^^^^^^^^^^^^^^
                          Feld 5 der einen Zeile, Feld 1 der naechsten

PostgreSQL bricht bei so einer Zeile den gesamten COPY ab.

Was dieses Skript tut
---------------------
1. Jede Zeile mit einem echten CSV-Parser lesen und die Feldzahl prüfen (Soll: 30)
2. Zeilen mit abweichender Feldzahl aussortieren und protokollieren
3. Die bereinigte Datei schreiben, das Original als .kaputt sichern
4. Doppelte IDs melden - sie entstehen, wenn ein Wiederaufsetzpunkt hinter dem
   tatsächlichen Schreibstand lag. Entfernt werden sie NICHT hier, sondern in der
   core-Schicht: dort ist es dokumentierbar und in SQL nachvollziehbar.

Der Bericht landet in 00_doku/csv_reparatur_bericht.txt und gehört in den Bericht.

Aufruf:
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\07_pruefe_und_repariere_csv.py
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\07_pruefe_und_repariere_csv.py --nur-pruefen
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

SOLL_FELDER = 30
SOLL_ZEILEN = {2021: 7164289, 2022: 6853648, 2023: 7685055, 2024: 7666174, 2025: 7770432}

csv.field_size_limit(10_000_000)


def log(t: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {t}", flush=True)


def pruefe_datei(pfad: Path, nur_pruefen: bool, bericht: list[str]) -> dict:
    jahr = int(pfad.stem.split("_")[1])
    soll = SOLL_ZEILEN.get(jahr)
    ziel = pfad.with_suffix(".csv.sauber")

    gut = schlecht = 0
    kaputte: list[tuple[int, int, str]] = []      # (Zeilennummer, Feldzahl, Auszug)
    ids: dict[str, int] = {}
    doppelt = 0

    fin = pfad.open(newline="", encoding="utf-8")
    reader = csv.reader(fin)
    kopf = next(reader)

    fout = None if nur_pruefen else ziel.open("w", newline="", encoding="utf-8")
    writer = None
    if fout:
        writer = csv.writer(fout, lineterminator="\r\n")
        writer.writerow(kopf)

    for nr, zeile in enumerate(reader, start=2):
        if len(zeile) != SOLL_FELDER:
            schlecht += 1
            if len(kaputte) < 25:
                kaputte.append((nr, len(zeile), ",".join(zeile)[:150]))
            continue
        satz_id = zeile[0]
        if satz_id in ids:
            doppelt += 1
        else:
            ids[satz_id] = nr
        gut += 1
        if writer:
            writer.writerow(zeile)

    fin.close()
    if fout:
        fout.close()

    bericht.append(f"\n=== co2cars_{jahr}.csv " + "=" * 50)
    bericht.append(f"  Zeilen mit {SOLL_FELDER} Feldern (verwertbar) : {gut:,}")
    bericht.append(f"  Zeilen mit abweichender Feldzahl        : {schlecht:,}")
    bericht.append(f"  doppelte IDs                            : {doppelt:,}")
    bericht.append(f"  eindeutige IDs                          : {len(ids):,}")
    if soll:
        bericht.append(f"  Sollmenge laut Quellzaehlung            : {soll:,}")
        bericht.append(f"  Differenz eindeutige IDs zu Soll        : {len(ids) - soll:+,}")
    for nr, n, txt in kaputte:
        bericht.append(f"    Zeile {nr:>10,}: {n:>3} Felder | {txt}")
    if len(kaputte) == 25:
        bericht.append("    ... weitere nicht aufgelistet")

    return {"jahr": jahr, "gut": gut, "schlecht": schlecht, "doppelt": doppelt,
            "eindeutig": len(ids), "soll": soll, "ziel": ziel}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--raw", default=str(Path(__file__).resolve().parent.parent / "01_daten" / "raw"))
    p.add_argument("--nur-pruefen", action="store_true",
                   help="nur berichten, Dateien nicht anfassen")
    a = p.parse_args()

    raw = Path(a.raw)
    dateien = sorted(raw.glob("co2cars_20*.csv"))
    if not dateien:
        print(f"Keine co2cars-CSVs in {raw}", file=sys.stderr)
        return 1

    bericht = [
        "Bericht zur CSV-Pruefung und -Reparatur",
        f"erstellt {time.strftime('%d.%m.%Y %H:%M')}",
        "",
        "Anlass: Eine Wiederaufnahme vor Einbau der Abschneidelogik hinterliess eine",
        "halb geschriebene Zeile, an die beim Anhaengen die naechste Zeile geklebt wurde.",
        "PostgreSQL bricht bei so einer Zeile den gesamten COPY ab.",
    ]

    log(f"Pruefe {len(dateien)} Dateien " + ("(nur lesen)" if a.nur_pruefen else "(mit Reparatur)"))
    ergebnisse = []
    for f in dateien:
        log(f"  {f.name} ({f.stat().st_size / (1 << 20):,.0f} MB) ...")
        ergebnisse.append(pruefe_datei(f, a.nur_pruefen, bericht))

    # --- Zusammenfassung -----------------------------------------------------
    print()
    print(f"{'Jahr':<6}{'verwertbar':>13}{'kaputt':>9}{'doppelt':>10}{'eindeutig':>13}{'Soll':>13}{'Diff':>9}")
    print("-" * 73)
    for e in ergebnisse:
        print(f"{e['jahr']:<6}{e['gut']:>13,}{e['schlecht']:>9,}{e['doppelt']:>10,}"
              f"{e['eindeutig']:>13,}{e['soll']:>13,}{e['eindeutig'] - e['soll']:>+9,}")
    print("-" * 73)
    print(f"{'SUMME':<6}{sum(e['gut'] for e in ergebnisse):>13,}"
          f"{sum(e['schlecht'] for e in ergebnisse):>9,}"
          f"{sum(e['doppelt'] for e in ergebnisse):>10,}"
          f"{sum(e['eindeutig'] for e in ergebnisse):>13,}"
          f"{sum(e['soll'] for e in ergebnisse):>13,}")

    # --- Dateien tauschen ----------------------------------------------------
    if not a.nur_pruefen:
        print()
        for e in ergebnisse:
            original = Path(a.raw) / f"co2cars_{e['jahr']}.csv"
            sauber = e["ziel"]
            if e["schlecht"] == 0:
                sauber.unlink(missing_ok=True)
                log(f"  {original.name}: nichts zu reparieren")
                continue
            kaputt = original.with_suffix(".csv.kaputt")
            kaputt.unlink(missing_ok=True)
            original.rename(kaputt)
            sauber.rename(original)
            log(f"  {original.name}: {e['schlecht']:,} Zeilen entfernt, "
                f"Original gesichert als {kaputt.name}")

    ber = Path(a.raw).parent.parent / "00_doku" / "csv_reparatur_bericht.txt"
    ber.write_text("\n".join(bericht), encoding="utf-8")
    print()
    log(f"Bericht: {ber}")
    log("Doppelte IDs werden NICHT hier entfernt, sondern in 20_core.sql -")
    log("dort ist die Entscheidung in SQL dokumentiert und nachvollziehbar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
