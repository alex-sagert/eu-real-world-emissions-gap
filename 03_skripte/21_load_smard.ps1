<#
.SYNOPSIS
    Lädt die SMARD-CSV per \copy in raw.smard_erzeugung.

.BESCHREIBUNG
    Dieser Schritt hat am 12.08.2026 gefehlt. 20_download_smard.py hat die CSV
    heruntergeladen, 13_smard_strommix.sql hat die Staging-Tabelle angelegt -
    aber niemand hat die Datei hineingeladen. Ergebnis: "SELECT 0", leere
    core.strommix, leere mart.strommix_intensitaet, und der Well-to-Wheel-
    Vergleich lieferte eine Tabelle aus lauter NULL-Werten, OHNE dass ein
    einziger Fehler gemeldet wurde. Genau diese Sorte Fehler ist gefaehrlich:
    die Kette meldete "ok" bei allen vier Schritten.

    Deshalb zwei Dinge:
      1. Dieses Skript laedt die Datei und prueft die Zeilenzahl.
      2. 13_smard_strommix.sql bricht jetzt mit einer Ausnahme ab, wenn die
         Staging-Tabelle leer ist, statt still weiterzurechnen.

    SPALTENREIHENFOLGE: Die SMARD-CSV liefert die Energietraeger NICHT in der
    Reihenfolge der Tabellendefinition (in der CSV steht wind_offshore vor
    wasserkraft, in der DDL umgekehrt). Ein \copy ohne Spaltenliste ordnet
    POSITIONELL zu - Windstrom waere als Wasserkraft verbucht worden und der
    Fehler waere nirgends aufgefallen, weil beide Faktoren 0 g/kWh haben.
    Die Spaltenliste wird deshalb aus der Kopfzeile der CSV gelesen.

.BEISPIEL
    .\03_skripte\21_load_smard.ps1
#>

[CmdletBinding()]
param(
    [string]$Csv      = (Join-Path $PSScriptRoot '..\01_daten\raw\smard_erzeugung_2021_2025_hour.csv'),
    [string]$Database = 'bd_co2',
    [string]$User     = 'postgres',
    [string]$PgHost   = 'localhost',
    [int]   $Port     = 5432,
    [string]$PsqlExe  = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PsqlExe)) {
    $c = Get-Command psql -ErrorAction SilentlyContinue
    if (-not $c) { throw 'psql nicht gefunden. Pfad über -PsqlExe angeben.' }
    $PsqlExe = $c.Source
}
if (-not (Test-Path -LiteralPath $Csv)) {
    throw "SMARD-CSV fehlt: $Csv  -  zuerst 20_download_smard.py laufen lassen."
}
$Csv = (Resolve-Path -LiteralPath $Csv).ProviderPath

$pgpass = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
if (-not (Test-Path -LiteralPath $pgpass) -and -not $env:PGPASSWORD) {
    $sec = Read-Host "Passwort für $User@$PgHost" -AsSecureString
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$env:PGCLIENTENCODING = 'UTF8'

function Write-Step { param([string]$T, [string]$C = 'Cyan')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $T) -ForegroundColor $C }

function Invoke-Psql {
    param([string]$Sql, [switch]$Quiet)
    $a = @('-h', $PgHost, '-p', $Port, '-U', $User, '-d', $Database, '-v', 'ON_ERROR_STOP=1')
    if ($Quiet) { $a += @('-t', '-A') }
    $a += @('-c', $Sql)
    $out = & $PsqlExe @a
    if ($LASTEXITCODE -ne 0) { throw "psql-Fehler bei: $Sql" }
    return $out
}

# --- Spaltenliste aus der Kopfzeile der CSV ----------------------------------
$kopf = (Get-Content -LiteralPath $Csv -TotalCount 1).Trim()
$spalten = $kopf -split ',' | ForEach-Object { $_.Trim().Trim('"') }
if ($spalten.Count -lt 3) { throw "Kopfzeile unerwartet: $kopf" }

# --- Staging-Tabelle -----------------------------------------------------
# Die DDL liegt bewusst HIER und nicht mehr in 13_smard_strommix.sql. Dort
# stand ein DROP TABLE, das die frisch geladenen Daten beim naechsten Lauf
# wieder weggeworfen haette. Wer laedt, legt an - so kann die Reihenfolge
# nicht mehr auseinanderlaufen.
#
# Alle Spalten TEXT, wie in der uebrigen Rohschicht: Typumwandlung ist Aufgabe
# der core-Schicht, damit ein einzelner unerwarteter Wert nicht den Ladelauf
# abbricht, sondern als Qualitaetsbefund sichtbar wird.
$spaltenDdl = ($spalten | ForEach-Object { "    $_ text" }) -join ",`n"
Invoke-Psql -Sql @"
DROP TABLE IF EXISTS raw.smard_erzeugung;
CREATE UNLOGGED TABLE raw.smard_erzeugung (
$spaltenDdl
);
COMMENT ON TABLE raw.smard_erzeugung IS 'Staging SMARD, realisierte Erzeugung DE in MWh je Zeitpunkt und Energietraeger. Spalten in der Reihenfolge der Quell-CSV.';
"@ | Out-Null

$mb = [Math]::Round((Get-Item -LiteralPath $Csv).Length / 1MB, 2)
Write-Step ("Lade SMARD-Strommix  ({0} MB, {1} Spalten)" -f $mb, $spalten.Count) 'Green'
Write-Step ("  Spaltenreihenfolge aus der CSV: {0}" -f ($spalten -join ', '))

$liste = ($spalten -join ', ')
$sql = "\copy raw.smard_erzeugung ($liste) FROM '$Csv' WITH (FORMAT csv, HEADER true, NULL '')"
& $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 -c $sql
if ($LASTEXITCODE -ne 0) { throw "Laden von $Csv fehlgeschlagen." }

$n = [int64](Invoke-Psql -Quiet -Sql 'SELECT count(*) FROM raw.smard_erzeugung').Trim()
Write-Step ("  {0:N0} Stundenwerte geladen" -f $n)
if ($n -eq 0) { throw 'Staging-Tabelle ist nach dem Laden leer.' }

# --- Plausibilitaet: deckt der Zeitraum wirklich 2021-2025 ab? ---------------
# Eine vollstaendige Stundenreihe ueber fuenf Jahre hat rund 43.800 Werte.
# Deutlich weniger heisst: der Download war unvollstaendig.
$spanne = (Invoke-Psql -Quiet -Sql @"
SELECT to_char(min(to_timestamp(zeitstempel::bigint / 1000)), 'YYYY-MM-DD')
       || ' bis ' ||
       to_char(max(to_timestamp(zeitstempel::bigint / 1000)), 'YYYY-MM-DD')
FROM raw.smard_erzeugung
"@).Trim()
Write-Step ("  Zeitraum: {0}" -f $spanne)
if ($n -lt 40000) {
    Write-Warning ("Nur {0:N0} Stundenwerte - erwartet waren rund 43.800 fuer 2021-2025. Bitte pruefen." -f $n)
}

Invoke-Psql -Sql (@"
INSERT INTO meta.load_log (quelle, objekt, source_version, data_status, zeitraum,
                           zeilen_ist, datei, bemerkung)
-- data_status ist char(1): 'F' final, 'P' provisional. Die SMARD-Reihe der
-- realisierten Erzeugung ist eine abgeschlossene Messreihe, also 'F'.
-- Der ausgeschriebene Status gehoert in die Bemerkung, nicht in die Spalte.
VALUES ('Bundesnetzagentur SMARD', 'raw.smard_erzeugung', 'chart_data', 'F',
        '$spanne', $n, '$($Csv -replace "'", "''")',
        'Realisierte Erzeugung, Stundenwerte je Energietraeger in MWh. Lizenz CC-BY-4.0.')
"@) | Out-Null

Write-Step 'Fertig. Weiter mit 13_smard_strommix.sql' 'Green'
