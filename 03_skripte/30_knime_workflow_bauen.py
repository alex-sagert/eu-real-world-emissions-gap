#!/usr/bin/env python3
"""
Baut den KNIME-Workflow "Papier gegen Straße" als .knwf-Datei.

Hintergrund
-----------
Ein .knwf ist ein ZIP mit einer workflow.knime (Knoten, Verbindungen,
Annotationen) und je Knoten einem Unterordner mit settings.xml. Beides ist
XML im KNIME-XMLConfig-Format. Zeilenumbrüche in Werten werden als
%%00013%%00010 kodiert (CR LF).

Der PostgreSQL Connector wird unverändert aus basis.knwf übernommen — dort
stecken Host, Datenbank und Zugangsdaten drin, die Alex bereits eingerichtet
hat. Alles andere wird hier erzeugt.

Aufruf:
    .\\.venv\\Scripts\\python.exe .\\03_skripte\\30_knime_workflow_bauen.py

Ergebnis:
    04_knime\\Papier_gegen_Strasse.knwf   -> in KNIME importieren

Alexander Sagert · 08/2026
"""

from __future__ import annotations

import re
import shutil
import sys
import zipfile
from pathlib import Path

WF = "Papier_gegen_Strasse"
ROOT = Path(__file__).resolve().parent.parent
KNIME = ROOT / "04_knime"
BASIS = KNIME / "basis.knwf"
BAU = KNIME / "_bau"


def nl(text: str) -> str:
    """Zeilenumbrueche in der KNIME-Kodierung."""
    return text.replace("\r\n", "\n").replace("\n", "%%00013%%00010")


def esc(text: str) -> str:
    """XML-Attributwert absichern. & und < sind in Attributen unzulaessig."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")


def v(text: str) -> str:
    return esc(nl(text))


# ---------------------------------------------------------------------------
# Die SQL-Abfragen
# ---------------------------------------------------------------------------

Q_ANTRIEBSMIX = """SELECT ms_code, land_name, jahr, antrieb_label, antriebsklasse,
       zulassungen, anteil_prozent, delta_prozentpunkte,
       avg_co2_wltp, avg_masse_kg
FROM mart.a1_antriebsmix
ORDER BY ms_code, jahr, zulassungen DESC"""

Q_LUECKE = """SELECT land, antriebsklasse, jahr, fahrzeuge,
       median_real_l, median_wltp_l, median_gap_pct, p90_gap_pct,
       median_e_anteil_pct, median_laufleistung
FROM mart.a4_luecke
WHERE fahrzeuge >= 500
ORDER BY median_gap_pct DESC"""

Q_ZIELE = """SELECT hersteller_gruppe, ist_gepoolt, jahr, zulassungen,
       flottenmittel_vor_oeko, flottenmittel_nach_oeko,
       flottenziel_naeherung, abweichung_g_km,
       anteil_bev_prozent, anteil_phev_prozent, anteil_oeko_prozent
FROM mart.a3_flottenziele
WHERE jahr = 2025 AND zulassungen >= 10000
ORDER BY zulassungen DESC"""

# Ausreissergrenze -50 bis 900 Prozent: Ein Regressionsmodell auf einer
# Zielgroesse mit extremen Ausreissern lernt die Ausreisser statt den
# Zusammenhang. Die Grenze schneidet unter einem Prozent der Saetze ab und
# wird im Bericht genannt.
# KORREKTUR 12.08.2026 - der Numeric Scorer brach ab mit
# "Missing value in prediction column in row: Row4".
#
# Ursache lag hier, nicht in KNIME: Der Missing-Value-Knoten war nur fuer
# Zeichenketten konfiguriert. Fehlende ZAHLEN blieben stehen, der Regression
# Predictor liefert fuer solche Zeilen keine Vorhersage, und der Scorer kann
# eine fehlende Vorhersage nicht bewerten. Behoben wird das in SQL statt im
# Knoten, weil die Behandlung dort begruendbar ist:
#
#   e_reichweite_km  NULL -> 0    Ein reiner Verbrenner HAT keine elektrische
#                                 Reichweite. Null ist der sachlich richtige
#                                 Wert, kein Ersatzwert.
#   hubraum_cm3      NULL -> 0    Dasselbe fuer Fahrzeuge ohne Verbrennungsmotor.
#   alle uebrigen    NULL -> Zeile faellt raus. Einen Median einzusetzen wuerde
#                                 Messwerte erfinden, die es nicht gibt.
#
# jahr wird bewusst als TEXT gelesen. Der Zulassungsjahrgang ist eine Kategorie,
# keine Menge - 2023 ist nicht "eins mehr" als 2022. KNIME hat die Spalte als
# Zahl zu Recht als redundant gemeldet.
Q_TRAINING = """SELECT r.antriebsklasse, r.land, r.jahr::text AS jahr,
       r.masse_kg, r.leistung_kw,
       coalesce(r.hubraum_cm3, 0)     AS hubraum_cm3,
       coalesce(r.e_reichweite_km, 0) AS e_reichweite_km,
       r.fc_wltp, r.co2_wltp, r.dist_total_km,
       r.gap_pct
FROM core.realworld r
WHERE r.eea_verwendbar
  AND r.hat_mindestlauf
  AND r.gap_pct IS NOT NULL
  AND r.gap_pct BETWEEN -50 AND 900
  AND r.masse_kg      IS NOT NULL
  AND r.leistung_kw   IS NOT NULL
  AND r.fc_wltp       IS NOT NULL
  AND r.co2_wltp      IS NOT NULL
  AND r.dist_total_km IS NOT NULL
ORDER BY random()
LIMIT 200000"""

# Dasselbe Modell nur innerhalb der PHEV-Gruppe. Ueber alle Antriebe hinweg
# erklaert die Antriebsart die Luecke fast allein - ein hohes R2 waere dort
# trivial. Interessant ist, was INNERHALB der Plug-in-Hybride die Luecke treibt.
# anteil_elektrisch und grid_kwh werden hier NICHT ersetzt, sondern verlangt.
# Sie sind die eigentlichen Erklaergroessen der PHEV-Luecke - haette ich sie
# mit einem Median aufgefuellt, wuerde das Modell auf einem erfundenen Wert
# genau die Frage beantworten, um die es geht.
Q_TRAINING_PHEV = """SELECT r.land, r.jahr::text AS jahr,
       r.masse_kg, r.leistung_kw,
       coalesce(r.hubraum_cm3, 0)     AS hubraum_cm3,
       coalesce(r.e_reichweite_km, 0) AS e_reichweite_km,
       r.fc_wltp, r.co2_wltp, r.dist_total_km,
       r.anteil_elektrisch, r.grid_kwh,
       r.gap_pct
FROM core.realworld r
WHERE r.eea_verwendbar
  AND r.hat_mindestlauf
  AND r.gap_pct IS NOT NULL
  AND r.antriebsklasse = 'PHEV'
  AND r.gap_pct BETWEEN 0 AND 2000
  AND r.masse_kg          IS NOT NULL
  AND r.leistung_kw       IS NOT NULL
  AND r.fc_wltp           IS NOT NULL
  AND r.co2_wltp          IS NOT NULL
  AND r.dist_total_km     IS NOT NULL
  AND r.anteil_elektrisch IS NOT NULL
  AND r.grid_kwh          IS NOT NULL
ORDER BY random()
LIMIT 200000"""

# Die Factory-Kennungen der aktuellen Node-Generation stammen aus dem von
# Alex exportierten Workflow, nicht aus einer Vermutung:
#   Regression Predictor -> ...regression.predict3.RegressionPredictorNodeFactory2
#   Numeric Scorer       -> ...scorer.numeric2.NumericScorer2NodeFactory
# Die aus Woche 3 uebernommenen Vorgaenger (predict2 / numeric) sind in
# KNIME 5.12 als deprecated markiert. Das Einstellungsschema ist identisch,
# nur die Kennung und die Portzahl unterscheiden sich.
MERKMALE = ["antriebsklasse", "land", "jahr", "masse_kg", "leistung_kw",
            "hubraum_cm3", "e_reichweite_km", "fc_wltp", "co2_wltp", "dist_total_km"]
MERKMALE_PHEV = ["land", "jahr", "masse_kg", "leistung_kw", "hubraum_cm3",
                 "e_reichweite_km", "fc_wltp", "co2_wltp", "dist_total_km",
                 "anteil_elektrisch", "grid_kwh"]

KOPF = ('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<config xmlns="http://www.knime.org/2008/09/XMLConfig" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.knime.org/2008/09/XMLConfig '
        'http://www.knime.org/XMLConfig_2008_09.xsd" key="{key}">\n')

BUNDLE_DB = """    <entry key="node-bundle-name" type="xstring" value="KNIME database nodes"/>
    <entry key="node-bundle-symbolic-name" type="xstring" value="org.knime.database.nodes"/>
    <entry key="node-bundle-vendor" type="xstring" value="KNIME AG, Zurich, Switzerland"/>
    <entry key="node-feature-name" type="xstring" value="KNIME Database"/>
    <entry key="node-feature-symbolic-name" type="xstring" value="org.knime.features.database.feature.group"/>
    <entry key="node-feature-vendor" type="xstring" value="KNIME AG, Zurich, Switzerland"/>
"""
# Bundle- und Feature-Angaben woertlich aus einem funktionierenden Workflow
# uebernommen. Der erste Versuch trug hier "KNIME Core" ein - ein Feature, das
# es nicht gibt. KNIME meldete daraufhin "Node not available from extension
# KNIME Core", obwohl das Plugin org.knime.base installiert war.
BUNDLE_BASE = """    <entry key="node-bundle-name" type="xstring" value="KNIME Base Nodes"/>
    <entry key="node-bundle-symbolic-name" type="xstring" value="org.knime.base"/>
    <entry key="node-bundle-vendor" type="xstring" value="KNIME AG, Zurich, Switzerland"/>
    <entry key="node-feature-name" type="xstring" value="KNIME Base nodes"/>
    <entry key="node-feature-symbolic-name" type="xstring" value="org.knime.features.base.feature.group"/>
    <entry key="node-feature-vendor" type="xstring" value="KNIME AG, Zurich, Switzerland"/>
"""


def annotation(text: str, x: int, y: int) -> str:
    return f"""    <config key="nodeAnnotation">
        <entry key="text" type="xstring" value="{v(text)}"/>
        <entry key="contentType" type="xstring" value="text/plain"/>
        <entry key="bgcolor" type="xint" value="16777215"/>
        <entry key="x-coordinate" type="xint" value="{x}"/>
        <entry key="y-coordinate" type="xint" value="{y}"/>
        <entry key="width" type="xint" value="240"/>
        <entry key="height" type="xint" value="15"/>
        <entry key="alignment" type="xstring" value="CENTER"/>
        <entry key="borderSize" type="xint" value="0"/>
        <entry key="borderColor" type="xint" value="16777215"/>
        <entry key="defFontSize" type="xint" value="9"/>
        <entry key="annotation-version" type="xint" value="20230412"/>
        <config key="styles"/>
    </config>
"""


def rumpf(name: str, factory: str, bundle: str, ports: int = 1) -> str:
    p = "".join(f"""        <config key="port_{i}">
            <entry key="index" type="xint" value="{i}"/>
            <entry key="port_dir_location" type="xstring" isnull="true" value=""/>
        </config>
""" for i in range(1, ports + 1))
    return f"""    <entry key="customDescription" type="xstring" isnull="true" value=""/>
    <entry key="state" type="xstring" value="CONFIGURED"/>
    <entry key="factory" type="xstring" value="{factory}"/>
    <entry key="node-name" type="xstring" value="{name}"/>
{bundle}    <config key="factory_settings"/>
    <entry key="name" type="xstring" value="{name}"/>
    <entry key="hasContent" type="xboolean" value="false"/>
    <entry key="isInactive" type="xboolean" value="false"/>
    <config key="ports">
{p}    </config>
    <config key="filestores">
        <entry key="file_store_location" type="xstring" isnull="true" value=""/>
        <entry key="file_store_id" type="xstring" isnull="true" value=""/>
    </config>
</config>
"""


def start(modell: str, notiz: str, x: int, y: int) -> str:
    return (KOPF.format(key="settings.xml")
            + '    <entry key="node_file" type="xstring" value="settings.xml"/>\n'
            + '    <config key="flow_stack"/>\n'
            + '    <config key="internal_node_subsettings">\n'
            + '        <entry key="memory_policy" type="xstring" value="CacheSmallInMemory"/>\n'
            + '    </config>\n'
            + modell
            + '    <config key="variables"/>\n'
            + annotation(notiz, x, y))


# ---------------------------------------------------------------------------
# Knotenbauer
# ---------------------------------------------------------------------------

def db_query_reader(sql: str, notiz: str, x: int, y: int) -> str:
    modell = f"""    <config key="model">
        <entry key="sql_statement" type="xstring" value="{v(sql)}"/>
        <config key="inputTypeMapping">
            <config key="byNameSettings"/>
            <config key="byTypeSettings"/>
        </config>
        <config key="outputTypeMapping">
            <config key="byNameSettings"/>
            <config key="byTypeSettings"/>
        </config>
    </config>
"""
    return start(modell, notiz, x, y) + rumpf(
        "DB Query Reader",
        "org.knime.database.node.io.reader.query.DBQueryReaderNodeFactory",
        BUNDLE_DB, ports=2)


def missing_value(notiz: str, x: int, y: int) -> str:
    modell = """    <config key="model">
        <config key="columnSettings"/>
        <config key="dataTypeSettings">
            <config key="org.knime.core.data.def.StringCell">
                <entry key="factoryID" type="xstring" value="org.knime.base.node.preproc.pmml.missingval.handlers.FixedStringValueMissingCellHandlerFactory"/>
                <config key="settings">
                    <config key="fixStringValue_Internals">
                        <entry key="SettingsModelID" type="xstring" value="SMID_string"/>
                        <entry key="EnabledStatus" type="xboolean" value="true"/>
                    </config>
                    <entry key="fixStringValue" type="xstring" value="unbekannt"/>
                </config>
            </config>
        </config>
    </config>
"""
    return start(modell, notiz, x, y) + rumpf(
        "Missing Value",
        "org.knime.base.node.preproc.pmml.missingval.compute.MissingValueHandlerNodeFactory",
        BUNDLE_BASE, ports=2)


def partitioning(klasse: str | None, notiz: str, x: int, y: int) -> str:
    methode = "Stratified" if klasse else "Random"
    kl = (f'<entry key="class_column" type="xstring" value="{klasse}"/>'
          if klasse else '<entry key="class_column" type="xstring" isnull="true" value=""/>')
    modell = f"""    <config key="model">
        <entry key="method" type="xstring" value="Relative"/>
        <entry key="samplingMethod" type="xstring" value="{methode}"/>
        <entry key="fraction" type="xdouble" value="0.7"/>
        <entry key="count" type="xint" value="100"/>
        <entry key="random_seed" type="xstring" value="1234"/>
        {kl}
    </config>
"""
    return start(modell, notiz, x, y) + rumpf(
        "Partitioning",
        "org.knime.base.node.preproc.partition.PartitionNodeFactory",
        BUNDLE_BASE, ports=2)


def linreg(ziel: str, merkmale: list[str], notiz: str, x: int, y: int) -> str:
    inc = "".join(f'                <entry key="{i}" type="xstring" value="{c}"/>\n'
                  for i, c in enumerate(merkmale))
    modell = f"""    <config key="model">
        <entry key="target" type="xstring" value="{ziel}"/>
        <config key="column_filter">
            <entry key="filter-type" type="xstring" value="STANDARD"/>
            <config key="included_names">
                <entry key="array-size" type="xint" value="{len(merkmale)}"/>
{inc}            </config>
            <config key="excluded_names">
                <entry key="array-size" type="xint" value="0"/>
            </config>
            <entry key="enforce_option" type="xstring" value="EnforceInclusion"/>
            <config key="name_pattern">
                <entry key="pattern" type="xstring" value=""/>
                <entry key="type" type="xstring" value="Wildcard"/>
                <entry key="caseSensitive" type="xboolean" value="true"/>
                <entry key="excludeMatching" type="xboolean" value="false"/>
            </config>
            <config key="datatype">
                <config key="typelist">
                    <entry key="org.knime.core.data.IntValue" type="xboolean" value="false"/>
                    <entry key="org.knime.core.data.BooleanValue" type="xboolean" value="false"/>
                    <entry key="org.knime.core.data.DoubleValue" type="xboolean" value="false"/>
                    <entry key="org.knime.core.data.LongValue" type="xboolean" value="false"/>
                    <entry key="org.knime.core.data.StringValue" type="xboolean" value="false"/>
                    <entry key="org.knime.core.data.date.DateAndTimeValue" type="xboolean" value="false"/>
                </config>
            </config>
        </config>
        <entry key="include_constant" type="xboolean" value="true"/>
        <entry key="offset_value" type="xdouble" value="0.0"/>
        <entry key="missing_value_handling" type="xstring" value="ignore"/>
        <entry key="scatter_plot_first_row" type="xint" value="1"/>
        <entry key="scatter_plot_row_count" type="xint" value="20000"/>
    </config>
"""
    return start(modell, notiz, x, y) + rumpf(
        "Linear Regression Learner",
        "org.knime.base.node.mine.regression.linear2.learner.LinReg2LearnerNodeFactory2",
        BUNDLE_BASE, ports=3)


def predictor(notiz: str, x: int, y: int) -> str:
    modell = """    <config key="model">
        <entry key="has_custom_predicition_name" type="xboolean" value="false"/>
        <entry key="custom_prediction_name" type="xstring" isnull="true" value=""/>
    </config>
"""
    return start(modell, notiz, x, y) + rumpf(
        "Regression Predictor",
        "org.knime.base.node.mine.regression.predict3.RegressionPredictorNodeFactory2",
        BUNDLE_BASE, ports=1)


def scorer(ziel: str, notiz: str, x: int, y: int) -> str:
    modell = f"""    <config key="model">
        <config key="reference_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_string"/>
            <entry key="EnabledStatus" type="xboolean" value="true"/>
        </config>
        <config key="reference">
            <entry key="useRowID" type="xboolean" value="false"/>
            <entry key="columnName" type="xstring" value="{ziel}"/>
        </config>
        <config key="predicted_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_string"/>
            <entry key="EnabledStatus" type="xboolean" value="true"/>
        </config>
        <config key="predicted">
            <entry key="useRowID" type="xboolean" value="false"/>
            <entry key="columnName" type="xstring" value="Prediction ({ziel})"/>
        </config>
        <config key="override default output name_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_boolean"/>
            <entry key="EnabledStatus" type="xboolean" value="true"/>
        </config>
        <entry key="override default output name" type="xboolean" value="false"/>
        <config key="output column_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_string"/>
            <entry key="EnabledStatus" type="xboolean" value="false"/>
        </config>
        <entry key="output column" type="xstring" value="Prediction ({ziel})"/>
        <config key="name prefix for flowvars_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_string"/>
            <entry key="EnabledStatus" type="xboolean" value="false"/>
        </config>
        <entry key="name prefix for flowvars" type="xstring" value=""/>
        <config key="generate flow variables_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_boolean"/>
            <entry key="EnabledStatus" type="xboolean" value="true"/>
        </config>
        <entry key="generate flow variables" type="xboolean" value="false"/>
        <config key="number_of_predictors_Internals">
            <entry key="SettingsModelID" type="xstring" value="SMID_integer"/>
            <entry key="EnabledStatus" type="xboolean" value="true"/>
        </config>
        <entry key="number_of_predictors" type="xint" value="0"/>
    </config>
"""
    return start(modell, notiz, x, y) + rumpf(
        "Numeric Scorer",
        "org.knime.base.node.mine.scorer.numeric2.NumericScorer2NodeFactory",
        BUNDLE_BASE, ports=1)


# ---------------------------------------------------------------------------
# Knoten- und Verbindungsplan
# ---------------------------------------------------------------------------

KNOTEN = [
    # id, Ordnername,                 Bauer,  x,   y
    (2,  "DB Query Reader",  lambda: db_query_reader(Q_ANTRIEBSMIX, "A1 Antriebsmix", 330, 145), 330, 100),
    (3,  "DB Query Reader",  lambda: db_query_reader(Q_LUECKE, "A4 Realverbrauchsluecke", 330, 245), 330, 200),
    (4,  "DB Query Reader",  lambda: db_query_reader(Q_ZIELE, "A3 Flottenziele", 330, 345), 330, 300),
    (5,  "DB Query Reader",  lambda: db_query_reader(Q_TRAINING, "Training alle Antriebe", 330, 495), 330, 450),
    (6,  "Missing Value",    lambda: missing_value("Strings -> unbekannt", 490, 495), 490, 450),
    (7,  "Partitioning",     lambda: partitioning("antriebsklasse", "70/30 stratifiziert, Seed 1234", 650, 495), 650, 450),
    (8,  "Linear Regression Learner", lambda: linreg("gap_pct", MERKMALE, "Ziel: gap_pct", 810, 445), 810, 400),
    (9,  "Regression Predictor", lambda: predictor("auf Testpartition", 970, 495), 970, 450),
    (10, "Numeric Scorer",   lambda: scorer("gap_pct", "R2 / MAE / RMSE", 1130, 495), 1130, 450),
    (11, "DB Query Reader",  lambda: db_query_reader(Q_TRAINING_PHEV, "Training nur PHEV", 330, 745), 330, 700),
    (12, "Missing Value",    lambda: missing_value("Strings -> unbekannt", 490, 745), 490, 700),
    (13, "Partitioning",     lambda: partitioning(None, "70/30 zufaellig, Seed 1234", 650, 745), 650, 700),
    (14, "Linear Regression Learner", lambda: linreg("gap_pct", MERKMALE_PHEV, "Ziel: gap_pct, nur PHEV", 810, 695), 810, 650),
    (15, "Regression Predictor", lambda: predictor("auf Testpartition", 970, 745), 970, 700),
    (16, "Numeric Scorer",   lambda: scorer("gap_pct", "R2 / MAE / RMSE", 1130, 745), 1130, 700),
]

VERBINDUNGEN = [
    (1, 1, 2, 1), (1, 1, 3, 1), (1, 1, 4, 1), (1, 1, 5, 1), (1, 1, 11, 1),
    (5, 1, 6, 1), (6, 1, 7, 1), (7, 1, 8, 1), (7, 2, 9, 2), (8, 1, 9, 1), (9, 1, 10, 1),
    (11, 1, 12, 1), (12, 1, 13, 1), (13, 1, 14, 1), (13, 2, 15, 2), (14, 1, 15, 1), (15, 1, 16, 1),
]

ERKLAERUNG = """Papier gegen Strasse - KNIME-Workflow

ARBEITSTEILUNG: Die schwere Aggregation laeuft in PostgreSQL, KNIME holt ueber
DB Query Reader nur fertige Ergebniszeilen. Das ist die Antwort auf die Frage
"wozu beides?" - nicht KNIME gegen SQL, sondern KNIME auf SQL.

OBEN   Drei Leseknoten fuer die Auswertungen A1, A3 und A4 -> Visualisierung
MITTE  Regression ueber ALLE Antriebe. Achtung bei der Bewertung: die
       Antriebsart erklaert die Luecke fast allein (PHEV gegen Verbrenner sind
       Groessenordnungen). Ein hohes R2 waere hier trivial.
UNTEN  Dasselbe Modell NUR innerhalb der Plug-in-Hybride. Hier wird es
       interessant: was treibt die Luecke, wenn alle Fahrzeuge Stecker haben?
       Erwartung: die elektrische Reichweite und der tatsaechlich elektrisch
       gefahrene Anteil erklaeren am meisten.

REPRODUZIERBARKEIT: Partitionierung 70/30 mit festem Seed 1234. Ohne festen
Seed ist die Modellguete bei jedem Lauf leicht anders und die Zahl im Bericht
nicht belegbar.

FILTER: gap_pct auf -50 bis 900 Prozent begrenzt. Ein Modell auf einer
Zielgroesse mit extremen Ausreissern lernt die Ausreisser statt den
Zusammenhang. Betrifft unter ein Prozent der Saetze, im Bericht genannt.

NOCH ZU ERGAENZEN (von Hand, je 2 Minuten):
  - Bar Chart an Knoten 3: Luecke in Prozent je Antriebsklasse
  - Scatter Plot an Knoten 3: x median_wltp_l, y median_real_l
  - Line Plot an Knoten 2: Antriebsmix Deutschland ueber die Jahre
  - Component um die Diagramme, mit Value Selection auf land und jahr"""


def main() -> int:
    if not BASIS.exists():
        print(f"basis.knwf fehlt: {BASIS}", file=sys.stderr)
        return 1

    # --- basis.knwf entpacken, Connector uebernehmen -----------------------
    # ignore_errors: Auf gemounteten Windows-Laufwerken laesst sich nicht jede
    # Datei loeschen. Der Arbeitsordner wird darum unter einem frischen Namen
    # neu angelegt, falls Reste liegen bleiben.
    shutil.rmtree(BAU, ignore_errors=True)
    if BAU.exists():
        for i in range(2, 20):
            kandidat = BAU.with_name(f"_bau{i}")
            shutil.rmtree(kandidat, ignore_errors=True)
            if not kandidat.exists():
                globals()["BAU"] = kandidat
                break
    BAU_ = globals()["BAU"]
    BAU_.mkdir(parents=True)
    with zipfile.ZipFile(BASIS) as z:
        z.extractall(BAU_)

    quelle = next(p for p in BAU_.iterdir() if p.is_dir())
    ziel = BAU_ / "_neu" / WF
    ziel.mkdir(parents=True)

    # Nur die settings.xml uebernehmen, nicht die Ausfuehrungsartefakte
    # (internal/, port_1/). Sonst haelt KNIME den Knoten fuer ausgefuehrt,
    # findet die Daten aber nicht und meldet beim Laden eine Warnung.
    conn = next(p for p in quelle.iterdir() if p.name.startswith("PostgreSQL Connector"))
    zconn = ziel / "PostgreSQL Connector (#1)"
    zconn.mkdir()
    text = (conn / "settings.xml").read_text(encoding="utf-8")
    text = re.sub(r'(<entry key="state" type="xstring" value=")[^"]*(")',
                  r"\1CONFIGURED\2", text)
    text = re.sub(r'(<entry key="hasContent" type="xboolean" value=")[^"]*(")',
                  r"\1false\2", text)
    (zconn / "settings.xml").write_text(text, encoding="utf-8")
    for f in ("workflow-metadata.xml", "workflowset.meta"):
        if (quelle / f).exists():
            shutil.copy(quelle / f, ziel / f)
    print(f"  PostgreSQL Connector uebernommen aus {conn.name}")

    # --- Knoten schreiben --------------------------------------------------
    for nid, name, bauer, _x, _y in KNOTEN:
        d = ziel / f"{name} (#{nid})"
        d.mkdir()
        (d / "settings.xml").write_text(bauer(), encoding="utf-8")
    print(f"  {len(KNOTEN)} Knoten erzeugt")

    # --- workflow.knime ----------------------------------------------------
    alle = [(1, "PostgreSQL Connector", 130, 400)] + [(i, n, x, y) for i, n, _b, x, y in KNOTEN]
    knoten_xml = ""
    for nid, name, x, y in alle:
        knoten_xml += f"""        <config key="node_{nid}">
            <entry key="id" type="xint" value="{nid}"/>
            <entry key="node_settings_file" type="xstring" value="{name} (#{nid})/settings.xml"/>
            <entry key="node_is_meta" type="xboolean" value="false"/>
            <entry key="node_type" type="xstring" value="NativeNode"/>
            <entry key="ui_classname" type="xstring" value="org.knime.core.node.workflow.NodeUIInformation"/>
            <config key="ui_settings">
                <config key="extrainfo.node.bounds">
                    <entry key="array-size" type="xint" value="4"/>
                    <entry key="0" type="xint" value="{x}"/>
                    <entry key="1" type="xint" value="{y}"/>
                    <entry key="2" type="xint" value="-1"/>
                    <entry key="3" type="xint" value="-1"/>
                </config>
            </config>
        </config>
"""
    verb_xml = ""
    for i, (s, sp, d, dp) in enumerate(VERBINDUNGEN):
        verb_xml += f"""        <config key="connection_{i}">
            <entry key="sourceID" type="xint" value="{s}"/>
            <entry key="destID" type="xint" value="{d}"/>
            <entry key="sourcePort" type="xint" value="{sp}"/>
            <entry key="destPort" type="xint" value="{dp}"/>
        </config>
"""

    wf = KOPF.format(key="workflow.knime")
    wf += """    <entry key="created_by" type="xstring" value="5.12.0.v202606180846"/>
    <entry key="created_by_nightly" type="xboolean" value="false"/>
    <entry key="version" type="xstring" value="5.1.0"/>
    <entry key="name" type="xstring" isnull="true" value=""/>
    <config key="authorInformation">
        <entry key="authored-by" type="xstring" value="Alexander Sagert"/>
        <entry key="authored-when" type="xstring" value="2026-08-12 09:00:00 +0200"/>
        <entry key="lastEdited-by" type="xstring" value="Alexander Sagert"/>
        <entry key="lastEdited-when" type="xstring" value="2026-08-12 09:00:00 +0200"/>
    </config>
    <entry key="customDescription" type="xstring" isnull="true" value=""/>
    <entry key="state" type="xstring" value="CONFIGURED"/>
    <config key="workflow_credentials"/>
    <config key="annotations">
        <config key="annotation_0">
"""
    wf += f'            <entry key="text" type="xstring" value="{v(ERKLAERUNG)}"/>\n'
    wf += """            <entry key="contentType" type="xstring" value="text/plain"/>
            <entry key="bgcolor" type="xint" value="16777215"/>
            <entry key="x-coordinate" type="xint" value="20"/>
            <entry key="y-coordinate" type="xint" value="20"/>
            <entry key="width" type="xint" value="1100"/>
            <entry key="height" type="xint" value="330"/>
            <entry key="alignment" type="xstring" value="LEFT"/>
            <entry key="borderSize" type="xint" value="4"/>
            <entry key="borderColor" type="xint" value="16766976"/>
            <entry key="defFontSize" type="xint" value="9"/>
            <entry key="annotation-version" type="xint" value="20230412"/>
            <config key="styles"/>
        </config>
    </config>
    <config key="nodes">
"""
    wf += knoten_xml + "    </config>\n    <config key=\"connections\">\n" + verb_xml
    wf += """    </config>
    <config key="workflow_editor_settings">
        <entry key="workflow.editor.snapToGrid" type="xboolean" value="true"/>
        <entry key="workflow.editor.ShowGrid" type="xboolean" value="true"/>
        <entry key="workflow.editor.gridX" type="xint" value="20"/>
        <entry key="workflow.editor.gridY" type="xint" value="20"/>
        <entry key="workflow.editor.zoomLevel" type="xdouble" value="1.0"/>
        <entry key="workflow.editor.curvedConnections" type="xboolean" value="true"/>
        <entry key="workflow.editor.connectionWidth" type="xint" value="1"/>
    </config>
</config>
"""
    (ziel / "workflow.knime").write_text(wf, encoding="utf-8")

    # --- packen ------------------------------------------------------------
    # Auf gemounteten Laufwerken laesst sich eine vorhandene Datei nicht immer
    # ueberschreiben. Dann wird unter einem Zweitnamen geschrieben statt
    # abzubrechen - die Arbeit von zwei Minuten soll nicht daran scheitern.
    out = KNIME / f"{WF}.knwf"
    if out.exists():
        try:
            out.unlink()
        except OSError:
            for i in range(2, 20):
                kandidat = KNIME / f"{WF}_v{i}.knwf"
                if not kandidat.exists():
                    out = kandidat
                    print(f"  Hinweis: alte Datei nicht ersetzbar, schreibe {out.name}")
                    break
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted((BAU_ / "_neu").rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(BAU_ / "_neu"))

    # Auf gemounteten Windows-Laufwerken schlaegt das Loeschen einzelner
    # Dateien manchmal fehl. Das darf den Lauf nicht scheitern lassen - die
    # .knwf ist zu diesem Zeitpunkt bereits geschrieben.
    shutil.rmtree(BAU_, ignore_errors=True)
    if BAU_.exists():
        print(f"  Hinweis: Arbeitsordner {BAU_.name} liess sich nicht loeschen, kann von Hand weg.")

    print(f"\nFertig: {out}  ({out.stat().st_size / 1024:,.0f} KB)")
    print(f"  {len(alle)} Knoten, {len(VERBINDUNGEN)} Verbindungen")
    print("\nIn KNIME: Datei -> Import KNIME Workflow -> diese .knwf waehlen.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
