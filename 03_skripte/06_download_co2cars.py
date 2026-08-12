#!/usr/bin/env python3
"""
Schneller Downloader für EEA co2cars über den DiscoData-SQL-REST-Endpunkt.

Gleiche Logik wie 01_download_co2cars.ps1, aber deutlich schneller:

    PowerShell   ~ 900 Zeilen/s   Invoke-RestMethod baut je Zeile ein PSObject,
                                  danach 30 Eigenschaftszugriffe pro Zeile
    Python       ~ 8.000+ /s      json.loads parst in C, csv.writer schreibt
                                  direkt aus Listen, Session hält die Verbindung

Zustandsdateien sind formatgleich zum PowerShell-Skript. Ein mit PowerShell
begonnener Lauf lässt sich hier fortsetzen und umgekehrt.

Aufruf (aus dem Projektordner):

    .\\.venv\\Scripts\\python.exe .\\03_skripte\\06_download_co2cars.py --years 2025
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\06_download_co2cars.py --years 2021 2022
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\06_download_co2cars.py --force

Alexander Sagert · 08/2026
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import quote

import requests

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

ENDPOINT = "https://discodata.eea.europa.eu/sql"

# Am 10.08.2026 durch Probing verifiziert, siehe 00_doku/02_Verifikationsprotokoll.md
TABLE_BY_YEAR = {
    2021: "co2cars_2021Fv24",   # final
    2022: "co2cars_2022Fv26",   # final
    2023: "co2cars_2023Fv28",   # final
    2024: "co2cars_2024Pv29",   # provisional
    2025: "co2cars_2025Pv31",   # provisional
}

# Sollmengen der Fokusländer, an der Quelle gezählt
SOLL = {2021: 7164289, 2022: 6853648, 2023: 7685055, 2024: 7666174, 2025: 7770432}

# SQL-Ausdruck -> CSV-Spaltenname. Reihenfolge = Spaltenreihenfolge der CSV und
# muss zu 02_sql/10_raw_staging_ddl.sql passen.
COLUMNS: list[tuple[str, str]] = [
    ("ID", "id"), ("MS", "ms"), ("Mp", "mp"), ("Mh", "mh"), ("Man", "man"),
    ("TAN", "tan"), ("T", "typ"), ("Va", "va"), ("Ve", "ve"), ("Mk", "mk"),
    ("Cn", "cn"), ("Ct", "ct"), ("[M (kg)]", "m_kg"), ("Mt", "mt"),
    ("[Enedc (g/km)]", "enedc"), ("[Ewltp (g/km)]", "ewltp"), ("[W (mm)]", "w_mm"),
    ("Ft", "ft"), ("Fm", "fm"), ("[Ec (cm3)]", "ec_cm3"), ("[Ep (KW)]", "ep_kw"),
    ("[Z (Wh/km)]", "z_whkm"), ("IT", "it_code"), ("[Erwltp (g/km)]", "erwltp"),
    ("Dr", "dr"), ("Fc", "fc"), ("R", "r_count"), ("Year", "year"),
    ("Status", "status"), ("Version_file", "version_file"),
]
NAMES = [n for _, n in COLUMNS]
SELECT_LIST = ", ".join(f"{expr} AS {name}" for expr, name in COLUMNS)


# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

def log(text: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {text}", flush=True)


class Disco:
    """Dünne Hülle um den REST-Endpunkt mit Wiederholung und Verbindungswiederverwendung."""

    def __init__(self, retries: int = 5, timeout: int = 600):
        self.s = requests.Session()
        self.s.headers.update({"User-Agent": "eu-real-world-emissions-gap/1.0"})
        self.retries = retries
        self.timeout = timeout

    def query(self, sql: str, nr_of_hits: int = 100) -> list[dict]:
        url = f"{ENDPOINT}?query={quote(sql)}&p=1&nrOfHits={nr_of_hits}"
        last = None
        for attempt in range(1, self.retries + 1):
            try:
                r = self.s.get(url, timeout=self.timeout)
                r.raise_for_status()
                data = json.loads(r.content)
            except Exception as exc:                      # Netz, Timeout, defektes JSON
                last = exc
                wait = min(60, 2 ** attempt)
                log(f"  Request fehlgeschlagen ({attempt}/{self.retries}): {exc} - warte {wait}s")
                time.sleep(wait)
                continue
            if "errors" in data:
                e = data["errors"][0]
                raise RuntimeError(f"DiscoData-Fehler {e.get('errorcode')}: {e.get('error')}")
            return data.get("results", [])
        raise RuntimeError(f"Endpunkt nach {self.retries} Versuchen nicht erreichbar: {last}")


def read_state(path: Path) -> dict | None:
    """Liest den Stand, ohne bei Sperre oder defektem Inhalt abzubrechen."""
    try:
        text = path.read_text(encoding="utf-8-sig")
        return json.loads(text) if text.strip() else None
    except Exception:
        return None


def save_state(path: Path, cursor: int, written: int, finished: bool = False) -> None:
    """
    Schreibt den Stand atomar: erst in eine temporäre Datei, dann umbenennen.

    Ein Leser sieht damit immer entweder den alten oder den neuen Stand,
    niemals eine halb geschriebene Datei - und ein Leser kann den Schreiber
    auch nicht blockieren. Genau daran sind die PowerShell-Läufe gescheitert.
    """
    tmp = path.with_suffix(".state.tmp")
    payload = json.dumps({"cursor": cursor, "written": written, "finished": finished})
    for _ in range(10):
        try:
            tmp.write_text(payload, encoding="utf-8")
            os.replace(tmp, path)
            return
        except OSError:
            time.sleep(0.2)
    print(f"WARNUNG: Stand konnte nicht gesichert werden ({path.name}). Lauf geht weiter.",
          file=sys.stderr, flush=True)


def truncate_csv(path: Path, data_rows: int) -> int:
    """
    Kürzt die CSV auf Kopfzeile + data_rows Datenzeilen.

    Nötig, weil die CSV laufend geschrieben wird, der Stand aber erst nach dem
    vollständigen Fenster. Ein mitten im Fenster beendeter Lauf hinterlässt
    mehr Zeilen, als der Stand kennt - ohne Kürzung entstünden Dubletten.
    Gibt die Zeilenzahl vor dem Kürzen zurück.
    """
    if not path.exists():
        return -1
    target = data_rows + 1        # Kopfzeile mitzählen
    lines = 0
    cut = -1
    pos = 0
    with path.open("rb") as f:
        while True:
            chunk = f.read(4 << 20)
            if not chunk:
                break
            start = 0
            while True:
                i = chunk.find(b"\n", start)
                if i < 0:
                    break
                lines += 1
                if lines == target and cut < 0:
                    cut = pos + i + 1
                start = i + 1
            pos += len(chunk)
    if cut >= 0 and cut < path.stat().st_size:
        os.truncate(path, cut)
    return lines - 1


# ---------------------------------------------------------------------------
# Hauptlauf je Jahrgang
# ---------------------------------------------------------------------------

def download_year(year: int, countries: list[str], out_dir: Path, disco: Disco,
                  target_rows: int, max_rows: int, force: bool) -> dict:
    table = f"[CO2Emission].[latest].[{TABLE_BY_YEAR[year]}]"
    country_list = ",".join(f"'{c}'" for c in countries)
    csv_path = out_dir / f"co2cars_{year}.csv"
    state_path = out_dir / f"co2cars_{year}.state"

    log(f"Jahr {year} - ermittle ID-Bereich aus {TABLE_BY_YEAR[year]}")
    b = disco.query(f"SELECT MIN(ID) AS mn, MAX(ID) AS mx, COUNT(*) AS n FROM {table}", 1)[0]
    min_id, max_id, n_all = int(b["mn"]), int(b["mx"]), int(b["n"])
    n_exp = int(disco.query(
        f"SELECT COUNT(*) AS n FROM {table} WHERE MS IN ({country_list})", 1)[0]["n"])
    log(f"  ID {min_id:,} .. {max_id:,} | gesamt {n_all:,} Zeilen | Sollmenge Fokuslaender {n_exp:,}")

    # Startfenster aus der tatsächlichen ID-Dichte. Sie schwankt stark:
    # 2025 rund 2,8 IDs je Zielzeile, 2021 rund 20,9.
    span = max_id - min_id + 1
    dichte = span / max(1, n_exp)
    win_start = max(5000, int(dichte * target_rows))
    win_max = win_start * 4
    win = win_start
    log(f"  ID-Dichte {dichte:,.2f} IDs je Zielzeile -> Startfenster {win_start:,}, "
        f"Obergrenze {win_max:,} (Ziel {target_rows:,} Zeilen/Request)")

    # --- Wiederaufnahme ----------------------------------------------------
    cursor, written = min_id, 0
    st = None if force else read_state(state_path)
    if st:
        cursor, written = int(st["cursor"]), int(st["written"])
        log(f"  Wiederaufnahme bei ID {cursor:,} ({written:,} Zeilen laut Stand)")
        vorhanden = truncate_csv(csv_path, written)
        if vorhanden < 0:
            raise RuntimeError(f"CSV fehlt, obwohl ein Stand existiert: {csv_path}")
        if vorhanden > written:
            log(f"  CSV enthielt {vorhanden:,} Zeilen, {vorhanden - written:,} davon nach dem "
                f"gesicherten Stand -> abgeschnitten")
        elif vorhanden < written:
            raise RuntimeError(
                f"CSV hat nur {vorhanden:,} Zeilen, der Stand nennt {written:,}. "
                f"Unvollstaendig - mit --force neu starten.")
        else:
            log("  CSV und Stand stimmen ueberein.")
        fh = csv_path.open("a", newline="", encoding="utf-8")
        # \r\n, weil das PowerShell-Skript so schreibt. Eine Datei mit
        # gemischten Zeilenenden laesst COPY ... FORMAT csv scheitern
        # ("unquoted carriage return found in data"). Da ein Lauf hier
        # fortgesetzt werden kann, der dort begonnen hat, muss das gleich sein.
        writer = csv.writer(fh, lineterminator="\r\n")
    else:
        fh = csv_path.open("w", newline="", encoding="utf-8")
        # \r\n, weil das PowerShell-Skript so schreibt. Eine Datei mit
        # gemischten Zeilenenden laesst COPY ... FORMAT csv scheitern
        # ("unquoted carriage return found in data"). Da ein Lauf hier
        # fortgesetzt werden kann, der dort begonnen hat, muss das gleich sein.
        writer = csv.writer(fh, lineterminator="\r\n")
        writer.writerow(NAMES)

    requests_done = 0
    schema_geprueft = False
    t0 = time.time()
    letzte_meldung = 0.0

    try:
        while cursor <= max_id:
            hi = cursor + win
            sql = (f"SELECT {SELECT_LIST} FROM {table} "
                   f"WHERE ID >= {cursor} AND ID < {hi} AND MS IN ({country_list})")
            rows = disco.query(sql, max_rows)
            requests_done += 1

            # Zeilenlimit erreicht: Antwort waere abgeschnitten. Fenster halbieren
            # und denselben Bereich erneut abfragen - es geht keine Zeile verloren.
            if len(rows) >= max_rows:
                if win <= 5000:
                    raise RuntimeError(f"Fenster bereits bei {win} und weiterhin am Limit.")
                win //= 2
                continue

            # Leerer Bereich: statt blind zu vergroessern die naechste passende
            # ID erfragen und dorthin springen. Ein Request statt vieler.
            if not rows:
                nxt = disco.query(
                    f"SELECT MIN(ID) AS mn FROM {table} "
                    f"WHERE ID >= {hi} AND MS IN ({country_list})", 1)
                requests_done += 1
                if not nxt or nxt[0]["mn"] is None:
                    cursor = max_id + 1
                else:
                    cursor = int(nxt[0]["mn"])
                    win = win_start
                continue

            if not schema_geprueft:
                fehlend = [n for n in NAMES if n not in rows[0]]
                if fehlend:
                    print(f"WARNUNG: Jahrgang {year}: Quelle liefert diese Spalten NICHT: "
                          f"{', '.join(fehlend)}", file=sys.stderr, flush=True)
                else:
                    log(f"  Schemapruefung ok - alle {len(NAMES)} Spalten vorhanden")
                schema_geprueft = True

            # Kern der Beschleunigung: eine Listcomprehension und ein writerows,
            # statt je Zeile ein Objekt aufzubauen und 30 Eigenschaften zu lesen.
            writer.writerows([[r.get(n) for n in NAMES] for r in rows])
            written += len(rows)
            cursor = hi

            # Fenster auf die Zielzeilenzahl nachregeln, Aenderung auf Faktor 4 begrenzt
            faktor = min(4.0, max(0.25, target_rows / len(rows)))
            win = min(win_max, max(5000, int(win * faktor)))

            fh.flush()
            save_state(state_path, cursor, written)

            jetzt = time.time()
            if jetzt - letzte_meldung >= 5:
                pct = min(100.0, 100.0 * (cursor - min_id) / span)
                rate = written / max(1e-9, jetzt - t0)
                rest = (n_exp - written) / rate if rate > 0 else 0
                log(f"  {written:>10,} / {n_exp:,} Zeilen | {pct:5.1f} % | {rate:>7,.0f} Zeilen/s "
                    f"| Fenster {win:>9,} | Rest ~{time.strftime('%H:%M:%S', time.gmtime(rest))}")
                letzte_meldung = jetzt
    finally:
        fh.flush()
        fh.close()

    save_state(state_path, cursor, written, finished=True)

    dauer = time.time() - t0
    mb = csv_path.stat().st_size / (1 << 20)
    ok = written == n_exp
    log(f"  {'fertig' if ok else 'ABWEICHUNG'}: {written:,} Zeilen (Soll {n_exp:,}) | "
        f"{mb:,.0f} MB | {requests_done} Requests | "
        f"{time.strftime('%H:%M:%S', time.gmtime(dauer))} | {written / max(1, dauer):,.0f} Zeilen/s")
    if not ok:
        print(f"WARNUNG: Differenz in {year}: {n_exp - written:,} Zeilen. "
              f"Nicht stillschweigend akzeptieren - im Logbuch vermerken.",
              file=sys.stderr, flush=True)

    return {"jahr": year, "tabelle": TABLE_BY_YEAR[year], "soll": n_exp, "ist": written,
            "differenz": n_exp - written, "mb": round(mb, 1), "requests": requests_done,
            "sekunden": round(dauer)}


def main() -> int:
    p = argparse.ArgumentParser(description="EEA co2cars über DiscoData laden")
    p.add_argument("--years", type=int, nargs="+", default=[2021, 2022, 2023, 2024, 2025])
    p.add_argument("--countries", nargs="+", default=["DE", "FR", "IT", "ES", "NL", "NO"])
    p.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "01_daten" / "raw"))
    p.add_argument("--target-rows", type=int, default=50000)
    p.add_argument("--max-rows", type=int, default=100000, help="nrOfHits je Request")
    p.add_argument("--force", action="store_true", help="vorhandenen Stand ignorieren")
    a = p.parse_args()

    out_dir = Path(a.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    disco = Disco()

    log(f"Start - Laender: {'/'.join(a.countries)} - Jahre: {'/'.join(map(str, a.years))}")
    t0 = time.time()
    summary = []
    for year in a.years:
        if year not in TABLE_BY_YEAR:
            print(f"WARNUNG: Kein Tabellenname fuer {year} hinterlegt - uebersprungen.", file=sys.stderr)
            continue
        summary.append(download_year(year, a.countries, out_dir, disco,
                                     a.target_rows, a.max_rows, a.force))

    log(f"Gesamtlauf {time.strftime('%H:%M:%S', time.gmtime(time.time() - t0))}")
    print()
    print(f"{'Jahr':<6}{'Soll':>12}{'Ist':>12}{'Differenz':>11}{'MB':>8}{'Requests':>10}{'Dauer':>10}")
    print("-" * 69)
    for s in summary:
        print(f"{s['jahr']:<6}{s['soll']:>12,}{s['ist']:>12,}{s['differenz']:>11,}"
              f"{s['mb']:>8,.0f}{s['requests']:>10,}"
              f"{time.strftime('%H:%M:%S', time.gmtime(s['sekunden'])):>10}")

    log_path = out_dir / "_download_co2cars_log.csv"
    with log_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0].keys()) if summary else ["jahr"])
        w.writeheader()
        w.writerows(summary)
    log(f"Protokoll: {log_path}")

    return 0 if all(s["differenz"] == 0 for s in summary) else 1


if __name__ == "__main__":
    sys.exit(main())
