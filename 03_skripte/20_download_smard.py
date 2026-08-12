#!/usr/bin/env python3
"""
Lädt die realisierte Stromerzeugung Deutschlands von SMARD (Bundesnetzagentur).

Zweck im Projekt: Der OBFCM-Realwert eines Elektroautos ist per Definition 0 g/km,
weil nur der Auspuff zählt. Ein fairer Vergleich zwischen Verbrenner, PHEV und BEV
braucht deshalb die CO₂-Intensität des Stroms, der tatsächlich geflossen ist.
Das ist die noch offene Hälfte von H2.

API: https://www.smard.de/app/chart_data/{filter}/DE/{filter}_DE_{aufloesung}_{ts}.json
Der Index unter .../index_{aufloesung}.json liefert die verfügbaren Wochenstempel.
Lizenz der Daten: CC-BY-4.0, Quellenangabe "Bundesnetzagentur | SMARD.de".

Aufruf:
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\20_download_smard.py
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\20_download_smard.py --von 2021 --bis 2025
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\20_download_smard.py --pruefe-ids

Alexander Sagert · 08/2026
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import requests

BASIS = "https://www.smard.de/app/chart_data"

# ---------------------------------------------------------------------------
# Filter-IDs der realisierten Erzeugung.
#
# ACHTUNG: Diese Zuordnung ist NICHT amtlich dokumentiert, sondern aus der
# SMARD-Weboberfläche und der Community-Dokumentation (smard.api.bund.dev)
# übernommen. Sie wird deshalb beim Lauf gegen Plausibilitätsregeln geprüft
# (--pruefe-ids), und das Ergebnis dieser Prüfung gehört in den Bericht.
#
# Prüfregeln, die eine Verwechslung auffliegen ließen:
#   * Photovoltaik muss nachts exakt 0 sein und mittags ein Maximum haben
#   * Kernenergie muss ab April 2023 durchgehend 0 sein (Abschaltung)
#   * Braunkohle muss über den ganzen Zeitraum deutlich über 0 liegen
# ---------------------------------------------------------------------------
#
# KORRIGIERT am 11.08.2026. Die erste Zuordnung war durchgehend verschoben und
# wurde durch --pruefe-ids überführt. Die Belege aus der Beispielwoche (MWh/h):
#
#   1225  Min 0, Max 6.291   -> Laufwasser fällt nie auf 0, Offshore-Wind schon
#   1226  Min 1.868, nie 0   -> genau umgekehrt: das ist Wasserkraft
#   1228  Min 92, Max 119    -> 0,1 GW, viel zu klein für Biomasse (~4 GW)
#   4066  3.390 bis 4.408    -> enges Band = Grundlast = Biomasse, nicht Wind
#   4070  Min 2, Max 5.746   -> fällt auf 0, typisch Pumpspeicher
#   4071  2.156 bis 10.484   -> Größenordnung und Schwankung passen zu Erdgas
#
TRAEGER = {
    1223: "braunkohle",
    1224: "kernenergie",
    1225: "wind_offshore",
    1226: "wasserkraft",
    1227: "sonstige_konventionelle",
    1228: "sonstige_erneuerbare",
    4066: "biomasse",
    4067: "wind_onshore",
    4068: "photovoltaik",
    4069: "steinkohle",
    4070: "pumpspeicher",
    4071: "erdgas",
}


def log(t: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {t}", flush=True)


class Smard:
    def __init__(self, retries: int = 4, timeout: int = 120):
        self.s = requests.Session()
        self.s.headers.update({"User-Agent": "eu-real-world-emissions-gap/1.0"})
        self.retries, self.timeout = retries, timeout

    def get(self, url: str):
        for versuch in range(1, self.retries + 1):
            try:
                r = self.s.get(url, timeout=self.timeout)
                if r.status_code == 404:
                    return None                      # Woche nicht vorhanden
                r.raise_for_status()
                return json.loads(r.content)
            except Exception as exc:
                if versuch == self.retries:
                    log(f"  aufgegeben: {url} ({exc})")
                    return None
                time.sleep(min(30, 2 ** versuch))
        return None

    def index(self, filter_id: int, aufloesung: str) -> list[int]:
        d = self.get(f"{BASIS}/{filter_id}/DE/index_{aufloesung}.json")
        return d.get("timestamps", []) if d else []

    def woche(self, filter_id: int, aufloesung: str, ts: int) -> list[list]:
        d = self.get(f"{BASIS}/{filter_id}/DE/{filter_id}_DE_{aufloesung}_{ts}.json")
        return d.get("series", []) if d else []


def pruefe_ids(sm: Smard, aufloesung: str) -> None:
    """
    Prüft die Filter-Zuordnung an einer Beispielwoche gegen physikalische Erwartungen.
    Eine vertauschte ID fällt hier auf, bevor sie in eine Kennzahl einfließt.
    """
    log("Pruefe Filter-IDs an einer Beispielwoche ...")
    print(f"\n{'ID':>6}  {'Traeger':<24}{'Werte':>7}{'Min':>10}{'Max':>10}{'Mittel':>10}"
          f"{'Nullanteil':>12}  Bewertung")
    print("-" * 96)
    for fid, name in TRAEGER.items():
        stamps = sm.index(fid, aufloesung)
        ziel = [t for t in stamps if 1720000000000 < t < 1725000000000]   # Sommerwoche 2024
        if not ziel:
            print(f"{fid:>6}  {name:<24}{'-':>7}  keine passende Woche im Index")
            continue
        serie = [v for _, v in sm.woche(fid, aufloesung, ziel[0]) if v is not None]
        if not serie:
            print(f"{fid:>6}  {name:<24}{0:>7}  keine Daten")
            continue
        null = sum(1 for v in serie if v == 0) / len(serie)
        mit = sum(serie) / len(serie)
        spanne = max(serie) / max(1.0, min(serie))     # Schwankungsbreite
        bew = ""
        # Bei Stundenaufloesung ist der Nachtwert der Photovoltaik nicht exakt 0,
        # sondern nahe 0. Deshalb wird die Schwankungsbreite geprueft, nicht der
        # Nullanteil - PV schwankt um Groessenordnungen, sonst nichts.
        if name == "photovoltaik":
            bew = "ok (Tag-Nacht-Spanne)" if spanne > 100 else "PRUEFEN - zu gleichmaessig fuer PV"
        elif name == "biomasse":
            bew = "ok (Grundlast ~4 GW)" if 2000 < mit < 6000 else f"PRUEFEN - {mit:,.0f} MWh unplausibel fuer Biomasse"
        elif name == "wasserkraft":
            bew = "ok (Laufwasser, nie 0)" if min(serie) > 500 else "PRUEFEN - Laufwasser faellt nicht auf 0"
        elif name == "wind_offshore":
            bew = "ok (schwankt bis 0)" if min(serie) < 500 else "PRUEFEN - zu gleichmaessig fuer Wind"
        elif name == "braunkohle":
            bew = "ok (durchgehend > 0)" if null < 0.05 and mit > 3000 else "PRUEFEN"
        elif name == "kernenergie":
            bew = "ok (seit 04/2023 abgeschaltet)" if null > 0.95 else "PRUEFEN - erwartet 0"
        elif name == "erdgas":
            bew = "ok" if 1000 < mit < 15000 else f"PRUEFEN - {mit:,.0f} MWh unplausibel"
        print(f"{fid:>6}  {name:<24}{len(serie):>7}{min(serie):>10,.0f}{max(serie):>10,.0f}"
              f"{sum(serie)/len(serie):>10,.0f}{null:>11.1%}  {bew}")
    print()


def main() -> int:
    p = argparse.ArgumentParser(description="SMARD-Stromerzeugung laden")
    p.add_argument("--von", type=int, default=2021)
    p.add_argument("--bis", type=int, default=2025)
    p.add_argument("--aufloesung", default="hour", choices=["quarterhour", "hour", "day"],
                   help="hour reicht fuer eine CO2-Intensitaet und ist ein Viertel des Volumens")
    p.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "01_daten" / "raw"))
    p.add_argument("--pruefe-ids", action="store_true", help="nur die Filter-Zuordnung pruefen")
    a = p.parse_args()

    sm = Smard()
    if a.pruefe_ids:
        pruefe_ids(sm, a.aufloesung)
        return 0

    out_dir = Path(a.out); out_dir.mkdir(parents=True, exist_ok=True)
    ziel = out_dir / f"smard_erzeugung_{a.von}_{a.bis}_{a.aufloesung}.csv"

    von_ms = int(datetime(a.von, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
    bis_ms = int(datetime(a.bis + 1, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)

    log(f"SMARD  {a.von}-{a.bis}  Aufloesung {a.aufloesung}  ->  {ziel.name}")
    pruefe_ids(sm, a.aufloesung)

    # zeitstempel -> {traeger: MWh}
    daten: dict[int, dict[str, float]] = defaultdict(dict)
    t0 = time.time()

    for fid, name in TRAEGER.items():
        stamps = [t for t in sm.index(fid, a.aufloesung) if von_ms <= t < bis_ms]
        log(f"  {name:<24} {len(stamps):>4} Wochen")
        for i, ts in enumerate(stamps, 1):
            for punkt, wert in sm.woche(fid, a.aufloesung, ts):
                if von_ms <= punkt < bis_ms and wert is not None:
                    daten[punkt][name] = wert
            if i % 50 == 0:
                log(f"    {i}/{len(stamps)} Wochen, {len(daten):,} Zeitpunkte")

    spalten = ["zeitstempel", "zeit_utc"] + list(TRAEGER.values())
    with ziel.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\r\n")
        w.writerow(spalten)
        for ts in sorted(daten):
            zeile = daten[ts]
            w.writerow([ts, datetime.fromtimestamp(ts / 1000, tz=timezone.utc).isoformat()]
                       + [zeile.get(n) for n in TRAEGER.values()])

    mb = ziel.stat().st_size / (1 << 20)
    log(f"Fertig: {len(daten):,} Zeitpunkte, {mb:,.1f} MB, "
        f"{time.strftime('%H:%M:%S', time.gmtime(time.time() - t0))}")
    log(f"Datei: {ziel}")
    log("Weiter mit: 10_run_sql.ps1 -File ..\\02_sql\\13_smard_staging.sql")
    log('Quellenangabe fuer Bericht und App: "Bundesnetzagentur | SMARD.de", CC-BY-4.0')
    return 0


if __name__ == "__main__":
    sys.exit(main())
