"""
Papier gegen Straße — interaktive Auswertung der Realverbrauchslücke.

    streamlit run 07_streamlit/app.py

Die App rechnet nichts selbst. Sie liest ausschließlich die fertigen
mart-Tabellen aus PostgreSQL — dieselben Zahlen, die auch im Bericht und in der
Präsentation stehen. Damit kann sie gar nicht zu einem anderen Ergebnis kommen
als die Dokumente, und das ist Absicht: Eine App, die eigene Aggregationen
rechnet, ist eine zweite Wahrheit.

Zugangsdaten kommen aus .streamlit/secrets.toml oder aus Umgebungsvariablen.
Sie stehen nicht im Code und nicht im Repository.
"""

from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import quote_plus

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from sqlalchemy import create_engine, text

# --------------------------------------------------------------------------- #
# Gestaltung — dieselben Farben wie die Präsentation
# --------------------------------------------------------------------------- #
ASPHALT = "#17191B"
PAPIER = "#F4F0E6"
SIGNAL = "#E0442B"
GRUEN = "#2E8B62"
SCHIEFER = "#6E7377"

st.set_page_config(
    page_title="Papier gegen Straße",
    page_icon="🛣️",
    layout="wide",
)

st.markdown(
    f"""
    <style>
      .stApp {{ background-color: {PAPIER}; }}
      h1, h2, h3 {{ color: {ASPHALT}; letter-spacing: -0.02em; }}
      [data-testid="stMetricValue"] {{ font-size: 2.4rem; }}
      [data-testid="stSidebar"] {{ background-color: #EAE5D8; }}
      .marke {{ color:{SIGNAL}; font-weight:700; letter-spacing:.18em;
                font-size:.78rem; text-transform:uppercase; }}
    </style>
    """,
    unsafe_allow_html=True,
)


# --------------------------------------------------------------------------- #
# Datenbank
# --------------------------------------------------------------------------- #
def _secrets_vorhanden() -> bool:
    """Prueft, ob ueberhaupt eine secrets.toml existiert.

    Wichtig: st.secrets darf nur angefasst werden, wenn die Datei da ist.
    Fehlt sie, wirft der Zugriff nicht nur eine Ausnahme — Streamlit schreibt
    zusaetzlich eine rote Meldung in die Oberflaeche, und zwar bei JEDEM
    Zugriff. Ein try/except faengt die Ausnahme, aber nicht die Meldung.
    Deshalb wird hier zuerst das Dateisystem gefragt.
    """
    return any(
        (Path.home() / ".streamlit" / "secrets.toml").exists()
        or (Path.cwd() / ".streamlit" / "secrets.toml").exists()
        for _ in (0,)
    )


def _aus_secrets() -> dict | None:
    """Liest den Abschnitt [postgres] aus secrets.toml, falls vorhanden."""
    if not _secrets_vorhanden():
        return None
    try:
        if "postgres" in st.secrets:
            return dict(st.secrets["postgres"])
    except Exception:  # noqa: BLE001
        pass
    return None


def zugang() -> dict:
    """Zugangsdaten in dieser Reihenfolge: secrets.toml, Eingabefeld, Umgebung."""
    aus_datei = _aus_secrets()
    if aus_datei:
        return {
            "user": aus_datei.get("user", "postgres"),
            "password": aus_datei.get("password", ""),
            "host": aus_datei.get("host", "localhost"),
            "port": str(aus_datei.get("port", 5432)),
            "database": aus_datei.get("database", "bd_co2"),
        }
    e = st.session_state.get("zugang_eingabe")
    if e:
        return e
    return {
        "user": os.getenv("PGUSER", "postgres"),
        "password": os.getenv("PGPASSWORD", ""),
        "host": os.getenv("PGHOST", "localhost"),
        "port": os.getenv("PGPORT", "5432"),
        "database": os.getenv("PGDATABASE", "bd_co2"),
    }


def _verbindung(c: dict) -> str:
    return (
        f"postgresql+psycopg2://{quote_plus(c['user'])}:{quote_plus(c['password'])}"
        f"@{c['host']}:{c['port']}/{c['database']}"
    )


@st.cache_resource(show_spinner=False)
def motor(zeichenkette: str):
    return create_engine(zeichenkette, pool_pre_ping=True)


@st.cache_data(ttl=3600, show_spinner=False)
def lies(sql: str, zeichenkette: str | None = None) -> pd.DataFrame:
    """Führt eine Abfrage aus und gibt das Ergebnis als DataFrame zurück."""
    z = zeichenkette or _verbindung(zugang())
    with motor(z).connect() as v:
        return pd.read_sql_query(text(sql), v)


def kopf(nummer: str, wort: str, titel: str, unter: str = "") -> None:
    st.markdown(f'<div class="marke">{nummer} &nbsp;&nbsp; {wort}</div>', unsafe_allow_html=True)
    st.markdown(f"## {titel}")
    if unter:
        st.caption(unter)


# --------------------------------------------------------------------------- #
# Verbindung prüfen, bevor irgendetwas gezeichnet wird
# --------------------------------------------------------------------------- #
try:
    _ = lies("SELECT 1 AS ok")
except Exception as fehler:  # noqa: BLE001
    st.markdown("## Verbindung zur Datenbank")
    st.warning(
        "Die App erreicht die Datenbank **bd_co2** nicht. Sie rechnet nichts "
        "selbst, sondern liest die fertigen Ergebnistabellen aus PostgreSQL."
    )

    c = zugang()
    with st.form("zugangsform"):
        s1, s2 = st.columns(2)
        with s1:
            host = st.text_input("Host", c["host"])
            port = st.text_input("Port", c["port"])
            datenbank = st.text_input("Datenbank", c["database"])
        with s2:
            benutzer = st.text_input("Benutzer", c["user"])
            passwort = st.text_input("Passwort", c["password"], type="password")
        if st.form_submit_button("Verbinden", type="primary"):
            st.session_state["zugang_eingabe"] = {
                "user": benutzer, "password": passwort, "host": host,
                "port": port, "database": datenbank,
            }
            st.cache_data.clear()
            st.cache_resource.clear()
            st.rerun()

    with st.expander("Dauerhaft hinterlegen, statt jedes Mal einzugeben"):
        st.markdown(
            "Eine Datei `.streamlit/secrets.toml` im Projektordner anlegen:"
        )
        st.code(
            '[postgres]\nuser = "postgres"\npassword = "HIER_DEIN_PASSWORT"\n'
            'host = "localhost"\nport = 5432\ndatabase = "bd_co2"',
            language="toml",
        )
        st.caption(
            "Die Datei ist in `.gitignore` ausgeschlossen und landet nicht im "
            "Repository. Alternativ gehen die Umgebungsvariablen PGUSER, "
            "PGPASSWORD, PGHOST, PGPORT und PGDATABASE."
        )
        st.markdown(
            "Ist die Datenbank noch gar nicht gebaut: `.\\03_skripte\\99_run_all.ps1`"
        )

    with st.expander("Fehlermeldung im Original"):
        st.exception(fehler)
    st.stop()


# --------------------------------------------------------------------------- #
# Seitenleiste
# --------------------------------------------------------------------------- #
with st.sidebar:
    st.markdown("### Papier gegen Straße")
    st.caption("Realverbrauchslücke der EU-Neuwagenflotte, 2021–2025")

    laender = lies(
        "SELECT DISTINCT land FROM mart.a4_luecke_gepoolt ORDER BY land"
    )["land"].tolist()
    land = st.selectbox(
        "Land", laender, index=laender.index("DE") if "DE" in laender else 0
    )

    st.divider()
    st.caption(
        "Die Kennzahlen sind Mediane über **alle** Zulassungsjahrgänge gemeinsam "
        "— dieselbe Tabelle, aus der auch Bericht und Präsentation lesen."
    )
    st.caption(
        "Ein Median lässt sich nicht aus Teilmedianen zusammensetzen. Eine "
        "Auswahl einzelner Jahrgänge würde deshalb andere Zahlen liefern als "
        "der Bericht. Die Entwicklung über die Jahrgänge steht weiter unten "
        "als eigener Abschnitt."
    )


# --------------------------------------------------------------------------- #
# Kopfbereich
# --------------------------------------------------------------------------- #
st.markdown(
    f"<h1 style='color:{ASPHALT};margin-bottom:0'>Papier gegen Straße</h1>",
    unsafe_allow_html=True,
)
st.caption(
    "Was der Laborwert verspricht und was der Bordzähler misst — "
    "45 Millionen amtliche Datensätze aus dem EU-CO₂-Monitoring."
)
st.divider()


# --------------------------------------------------------------------------- #
# 01 · Die Lücke je Antriebsklasse
# --------------------------------------------------------------------------- #
luecke = lies(f"""
    SELECT antriebsklasse, fahrzeuge, wltp_l, real_l,
           gap_median_pct AS gap_pct, gap_p90_pct AS p90_pct,
           e_anteil_pct, jahr_von, jahr_bis
    FROM mart.a4_luecke_gepoolt
    WHERE land = '{land}'
    ORDER BY fahrzeuge DESC
""")

if not luecke.empty:
    spanne = f"{int(luecke['jahr_von'].min())}–{int(luecke['jahr_bis'].max())}"
else:
    spanne = ""

kopf("01", "Die Lücke", "Was das Papier verspricht. Was die Straße misst.",
     f"{land} · Zulassungsjahrgänge {spanne} · Median über alle Fahrzeuge")

if luecke.empty:
    st.info("Für diese Auswahl liegen keine Daten vor.")
    st.stop()

spalten = st.columns(len(luecke))
for spalte, (_, z) in zip(spalten, luecke.iterrows()):
    spalte.metric(
        z["antriebsklasse"],
        f"+{z['gap_pct']:.1f} %".replace(".", ","),
        f"{int(z['fahrzeuge']):,} Fahrzeuge".replace(",", "."),
        delta_color="off",
    )

# Der Lücken-Balken aus der Präsentation, hier als Plotly-Grafik
abb = go.Figure()
abb.add_trace(go.Bar(
    y=luecke["antriebsklasse"], x=luecke["wltp_l"], orientation="h",
    name="Laborwert (WLTP)", marker=dict(color="rgba(0,0,0,0)",
                                         line=dict(color=SCHIEFER, width=1.5)),
    text=luecke["wltp_l"], textposition="outside",
))
abb.add_trace(go.Bar(
    y=luecke["antriebsklasse"], x=luecke["real_l"], orientation="h",
    name="gemessen (OBFCM)", marker=dict(color=SIGNAL),
    text=luecke["real_l"], textposition="outside",
))
abb.update_layout(
    barmode="group", height=340, plot_bgcolor=PAPIER, paper_bgcolor=PAPIER,
    font=dict(color=ASPHALT, size=13),
    xaxis_title="Liter je 100 km", yaxis_title=None,
    legend=dict(orientation="h", y=1.12, x=0),
    margin=dict(l=10, r=40, t=10, b=10),
)
abb.update_xaxes(gridcolor="#E0DBCC", zeroline=False)
abb.update_yaxes(gridcolor="rgba(0,0,0,0)")
st.plotly_chart(abb, use_container_width=True)

with st.expander("Warum der Median und nicht der Durchschnitt?"):
    st.markdown(
        "Die Verteilung der Lücke ist rechtsschief: Einzelne Fahrzeuge mit "
        "extremer Nutzung ziehen einen Durchschnitt spürbar nach oben, den "
        "Median aber nicht. Das 90. Perzentil zeigt daneben, wie weit das obere "
        "Ende reicht — beim Plug-in-Hybrid ist genau das die Aussage."
    )
    st.dataframe(
        luecke.drop(columns=["jahr_von", "jahr_bis"]).rename(columns={
            "antriebsklasse": "Antrieb", "fahrzeuge": "Fahrzeuge",
            "wltp_l": "WLTP l/100 km", "real_l": "real l/100 km",
            "gap_pct": "Lücke Median %", "p90_pct": "Lücke P90 %",
            "e_anteil_pct": "elektrisch gefahren %",
        }),
        use_container_width=True, hide_index=True,
    )

with st.expander("Entwicklung über die Zulassungsjahrgänge"):
    st.caption(
        "Hier steht je Jahrgang ein eigener Median. Diese Werte lassen sich "
        "nicht zu einem Gesamtmedian mitteln — deshalb sind die Kennzahlen "
        "oben getrennt gerechnet."
    )
    verlauf = lies(f"""
        SELECT jahr, antriebsklasse, fahrzeuge, median_gap_pct
        FROM mart.a4_luecke
        WHERE land = '{land}' AND fahrzeuge >= 500
        ORDER BY jahr, antriebsklasse
    """)
    if verlauf.empty:
        st.info("Keine Jahrgangsdaten für dieses Land.")
    else:
        vl = px.line(
            verlauf, x="jahr", y="median_gap_pct", color="antriebsklasse",
            markers=True,
            labels={"jahr": "Zulassungsjahrgang",
                    "median_gap_pct": "Lücke in Prozent",
                    "antriebsklasse": ""},
        )
        vl.update_layout(
            plot_bgcolor=PAPIER, paper_bgcolor=PAPIER,
            font=dict(color=ASPHALT, size=12), height=340,
            margin=dict(l=10, r=10, t=30, b=10),
        )
        vl.update_xaxes(gridcolor="#E0DBCC", dtick=1)
        vl.update_yaxes(gridcolor="#E0DBCC")
        st.plotly_chart(vl, use_container_width=True)

st.divider()


# --------------------------------------------------------------------------- #
# 02 · Der Utility Factor
# --------------------------------------------------------------------------- #
phev = luecke[luecke["antriebsklasse"] == "PHEV"]
if not phev.empty and pd.notna(phev.iloc[0]["e_anteil_pct"]):
    kopf("02", "Die Ursache", "Der Utility Factor in der Praxis",
         "Die WLTP-Regel unterstellt rund 84 Prozent elektrische Fahrleistung.")

    gemessen = float(phev.iloc[0]["e_anteil_pct"])
    links, rechts = st.columns([1, 2])
    with links:
        st.metric("unterstellt (WLTP)", "84,0 %")
        st.metric("gemessen", f"{gemessen:.1f} %".replace(".", ","),
                  f"{gemessen - 84:.1f} Prozentpunkte".replace(".", ","))
    with rechts:
        uf = go.Figure()
        uf.add_trace(go.Bar(x=[84.0], y=["unterstellt"], orientation="h",
                            marker=dict(color=SCHIEFER), name="WLTP-Annahme"))
        uf.add_trace(go.Bar(x=[gemessen], y=["gemessen"], orientation="h",
                            marker=dict(color=SIGNAL), name="Realität"))
        uf.update_layout(
            height=200, showlegend=False, plot_bgcolor=PAPIER, paper_bgcolor=PAPIER,
            font=dict(color=ASPHALT, size=13),
            xaxis=dict(range=[0, 100], title="elektrisch gefahrener Anteil in Prozent",
                       gridcolor="#E0DBCC"),
            margin=dict(l=10, r=10, t=10, b=10),
        )
        st.plotly_chart(uf, use_container_width=True)

    st.markdown(
        f"> **Der Plug-in-Hybrid ist nicht schlecht gebaut. Er wird nicht geladen.** "
        f"Die Regel unterstellt 84 Prozent, gemessen wurden {gemessen:.1f} Prozent."
        .replace(".", ",")
    )
    st.divider()


# --------------------------------------------------------------------------- #
# 03 · Hersteller
# --------------------------------------------------------------------------- #
kopf("03", "Hersteller", "Wer hält sein Versprechen?",
     "Nur reine Verbrenner — sonst misst die Rangliste den Antriebsmix "
     "statt der Motorentechnik.")

try:
    hersteller = lies("""
        SELECT hersteller, fahrzeuge, wltp_l, real_l, gap_median_pct,
               masse_kg, leistung_kw
        FROM mart.a7_hersteller_verbrenner
        ORDER BY gap_median_pct
    """)
except Exception:  # noqa: BLE001
    hersteller = pd.DataFrame()

if hersteller.empty:
    st.info(
        "Die Herstellerauswertung fehlt noch. "
        "Sie entsteht mit `02_sql/44_hersteller_luecke.sql`."
    )
else:
    hersteller["farbe"] = [
        GRUEN if g <= hersteller["gap_median_pct"].quantile(0.25)
        else SIGNAL if g >= hersteller["gap_median_pct"].quantile(0.75)
        else ASPHALT
        for g in hersteller["gap_median_pct"]
    ]
    rang = px.bar(
        hersteller, x="gap_median_pct", y="hersteller", orientation="h",
        text="gap_median_pct",
        labels={"gap_median_pct": "Lücke in Prozent", "hersteller": ""},
        height=max(420, 26 * len(hersteller)),
    )
    rang.update_traces(marker_color=hersteller["farbe"],
                       texttemplate="%{text:.1f} %", textposition="outside")
    rang.update_layout(
        plot_bgcolor=PAPIER, paper_bgcolor=PAPIER, font=dict(color=ASPHALT, size=12),
        yaxis=dict(autorange="reversed"), margin=dict(l=10, r=50, t=10, b=10),
    )
    rang.update_xaxes(gridcolor="#E0DBCC")
    st.plotly_chart(rang, use_container_width=True)

    a, b = st.columns(2)
    with a:
        st.markdown("**Klein und sparsam heißt große Lücke**")
        st.markdown(
            "Porsche liegt vorn, Dacia und Renault hinten — genau umgekehrt zur "
            "Intuition. Ein kleiner aufgeladener Motor arbeitet im sanften "
            "Laborzyklus nahe seinem Bestpunkt und verlässt ihn im Alltag sofort."
        )
    with b:
        st.markdown("**Die Lücke ist relativ, nicht absolut**")
        st.markdown(
            "Renault verbraucht real 7,13 l, Porsche 12,31 l. Der Renault bleibt "
            "das sparsamere Auto — er hält sein Versprechen nur schlechter ein."
        )

    st.scatter_chart(
        hersteller.rename(columns={"leistung_kw": "Leistung kW",
                                   "gap_median_pct": "Lücke %"}),
        x="Leistung kW", y="Lücke %", color=None, height=320,
    )
    st.caption(
        "Motorleistung gegen Lücke. Der Zusammenhang ist sichtbar, aber nicht "
        "eindeutig — die BMW-M-Modelle mit 375 kW liegen am schlechtesten. "
        "Leistung allein erklärt den Befund nicht."
    )

st.divider()


# --------------------------------------------------------------------------- #
# 04 · Well-to-Wheel
# --------------------------------------------------------------------------- #
kopf("04", "Well-to-Wheel", "Der faire Vergleich",
     "Auspuff plus Netzstrom, bewertet mit dem realen deutschen Strommix.")

try:
    wtw = lies("""
        SELECT antriebsklasse, quelle_real, co2_offiziell, co2_wtw_gesamt,
               bev_szenario, strommix_g_kwh
        FROM mart.wtw_vergleich
        ORDER BY co2_wtw_gesamt
    """)
except Exception:  # noqa: BLE001
    wtw = pd.DataFrame()

if wtw.empty:
    st.info("Der Well-to-Wheel-Vergleich fehlt noch — `02_sql/42_wtw_vergleich.sql`.")
else:
    szenarien = sorted(wtw["bev_szenario"].unique())
    szenario = st.radio(
        "Annahme für den Realverbrauch des Batterieautos",
        szenarien,
        index=szenarien.index("mittel") if "mittel" in szenarien else 0,
        horizontal=True,
        help="Der Bordzähler misst Kraftstoff. Ein Batterieauto hat keinen, "
             "deshalb wird sein Laborwert mit einem Aufschlag gerechnet — "
             "in drei Szenarien, damit sichtbar ist, ob das Ergebnis daran hängt.",
    )
    w = wtw[wtw["bev_szenario"] == szenario].sort_values("co2_wtw_gesamt")

    fig = go.Figure()
    fig.add_trace(go.Bar(
        x=w["antriebsklasse"], y=w["co2_offiziell"], name="offiziell (Papier)",
        marker=dict(color="rgba(0,0,0,0)", line=dict(color=SCHIEFER, width=1.5)),
        text=w["co2_offiziell"], textposition="outside",
    ))
    fig.add_trace(go.Bar(
        x=w["antriebsklasse"], y=w["co2_wtw_gesamt"], name="real (Well-to-Wheel)",
        marker=dict(color=SIGNAL), text=w["co2_wtw_gesamt"], textposition="outside",
    ))
    fig.update_layout(
        barmode="group", height=420, plot_bgcolor=PAPIER, paper_bgcolor=PAPIER,
        font=dict(color=ASPHALT, size=13), yaxis_title="g CO₂ je km",
        legend=dict(orientation="h", y=1.1, x=0), margin=dict(l=10, r=10, t=10, b=10),
    )
    fig.update_yaxes(gridcolor="#E0DBCC")
    st.plotly_chart(fig, use_container_width=True)

    st.caption(
        f"Strommix: {w['strommix_g_kwh'].iloc[0]} g CO₂/kWh. "
        "Beim Batterieauto fehlt der linke Balken nicht — die Verordnung "
        "schreibt dort 0 g/km vor."
    )

    if "quelle_real" in w.columns:
        labor = w[w["quelle_real"].str.contains("Labor", na=False)]
        if not labor.empty:
            st.warning(
                "**Nicht gleichwertig:** Die Zeile "
                f"*{', '.join(labor['antriebsklasse'])}* stammt aus der "
                "WLTP-Typprüfung, alle anderen aus gemessenem Realverbrauch. "
                "OBFCM ist ein Kraftstoffmesser — ein Batterieauto hat keinen "
                "und ist in dieser Quelle nicht enthalten."
            )

st.divider()


# --------------------------------------------------------------------------- #
# 05 · Der Gap-Rechner
# --------------------------------------------------------------------------- #
kopf("05", "Rechner", "Was kostet die Lücke?",
     "Die gemessene Abweichung auf die eigene Fahrleistung umgerechnet.")

r1, r2, r3 = st.columns(3)
with r1:
    antrieb = st.selectbox("Antrieb", luecke["antriebsklasse"].tolist())
with r2:
    km = st.number_input("Fahrleistung je Jahr in km", 5_000, 100_000, 15_000, 1_000)
with r3:
    preis = st.number_input("Kraftstoffpreis je Liter in Euro", 1.0, 3.0, 1.75, 0.05)

z = luecke[luecke["antriebsklasse"] == antrieb].iloc[0]
liter_papier = float(z["wltp_l"]) * km / 100
liter_real = float(z["real_l"]) * km / 100
mehr = liter_real - liter_papier

k1, k2, k3 = st.columns(3)
k1.metric("nach Laborwert", f"{liter_papier:,.0f} l".replace(",", "."),
          f"{liter_papier * preis:,.0f} €".replace(",", "."), delta_color="off")
k2.metric("tatsächlich", f"{liter_real:,.0f} l".replace(",", "."),
          f"{liter_real * preis:,.0f} €".replace(",", "."), delta_color="off")
k3.metric("Differenz je Jahr", f"{mehr:,.0f} l".replace(",", "."),
          f"{mehr * preis:,.0f} €".replace(",", "."))

st.caption(
    "Rechnung auf Basis des Medians dieser Antriebsklasse. Ein einzelnes "
    "Fahrzeug kann deutlich darüber oder darunter liegen — das 90. Perzentil "
    f"dieser Klasse liegt bei {z['p90_pct']:.1f} Prozent.".replace(".", ",")
)

st.divider()
st.caption(
    "Quellen: EEA co2cars (Art. 7) · EEA OBFCM (Art. 12, CC-BY-4.0) · "
    "SMARD, Bundesnetzagentur (CC-BY-4.0). "
    "Alle Kennzahlen stammen aus den mart-Tabellen der Projektdatenbank."
)
