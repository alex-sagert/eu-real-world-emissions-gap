<#
.SYNOPSIS
    Lädt die entpackten OBFCM-CSVs per \copy in raw.obfcm_cars und raw.obfcm_cars_agg.

.BESCHREIBUNG
    Die Rohdatei ist ~1,4 GB mit 7.791.120 Zeilen. Zwei Eigenheiten:
      * Fehlwerte stehen als Zeichenkette 'NULL'  -> NULL 'NULL'
      * 8 % der Zeilen enthalten Kommas in Anfuehrungszeichen -> FORMAT csv noetig

    Das Skript sucht die entpackten Dateien selbst, laedt sie und protokolliert
    den Lauf in meta.load_log.

.BEISPIEL
    .\12_load_obfcm.ps1
#>

[CmdletBinding()]
param(
    [string]$RawDir   = (Join-Path $PSScriptRoot '..\01_daten\raw\obfcm'),
    [string]$Database = 'bd_co2',
    [string]$User     = 'postgres',
    [string]$PgHost   = 'localhost',
    [int]   $Port     = 5432,
    [string]$PsqlExe  = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [switch]$SkipDdl
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PsqlExe)) {
    $c = Get-Command psql -ErrorAction SilentlyContinue
    if (-not $c) { throw 'psql nicht gefunden. Pfad ueber -PsqlExe angeben.' }
    $PsqlExe = $c.Source
}
$RawDir = (Resolve-Path -LiteralPath $RawDir).ProviderPath
$sqlDir = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\02_sql')).ProviderPath

$pgpass = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
if (-not (Test-Path -LiteralPath $pgpass) -and -not $env:PGPASSWORD) {
    $sec = Read-Host "Passwort fuer $User@$PgHost" -AsSecureString
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$env:PGCLIENTENCODING = 'UTF8'

function Write-Step { param([string]$T,[string]$C='Cyan') Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$T) -ForegroundColor $C }

function Invoke-Psql {
    param([string]$Sql, [switch]$Quiet)
    $a = @('-h',$PgHost,'-p',$Port,'-U',$User,'-d',$Database,'-v','ON_ERROR_STOP=1')
    if ($Quiet) { $a += @('-t','-A') }
    $a += @('-c',$Sql)
    $out = & $PsqlExe @a
    if ($LASTEXITCODE -ne 0) { throw "psql-Fehler bei: $Sql" }
    return $out
}

# --- Dateien suchen ----------------------------------------------------------
$rawCsv = Get-ChildItem -LiteralPath $RawDir -Recurse -Filter '*_Cars_Raw.csv'        -ErrorAction SilentlyContinue |
          Sort-Object Length -Descending | Select-Object -First 1
$aggCsv = Get-ChildItem -LiteralPath $RawDir -Recurse -Filter '*_Cars_Aggregated.csv' -ErrorAction SilentlyContinue |
          Select-Object -First 1

if (-not $rawCsv) { throw "Keine *_Cars_Raw.csv unter $RawDir gefunden. Zuerst 02_download_obfcm.ps1 ausfuehren." }
Write-Step ("Rohdatei : {0}  ({1:N0} MB)" -f $rawCsv.Name, ($rawCsv.Length / 1MB)) 'Green'
if ($aggCsv) { Write-Step ("Aggregat : {0}" -f $aggCsv.Name) }

# --- DDL ---------------------------------------------------------------------
if (-not $SkipDdl) {
    Write-Step 'Lege OBFCM-Staging an'
    & $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 -f (Join-Path $sqlDir '12_obfcm_staging.sql')
    if ($LASTEXITCODE -ne 0) { throw 'DDL fehlgeschlagen.' }
}

# --- Laden -------------------------------------------------------------------
# NULL 'NULL': die Datei schreibt Fehlwerte als Zeichenkette NULL.
# FORMAT csv:  8 % der Zeilen enthalten Kommas in Anfuehrungszeichen.
Write-Step 'Lade Rohdaten (dauert einige Minuten)' 'Green'
$t0 = Get-Date
& $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 `
    -c "\copy raw.obfcm_cars FROM '$($rawCsv.FullName)' WITH (FORMAT csv, HEADER true, NULL 'NULL')"
if ($LASTEXITCODE -ne 0) { throw 'Laden der Rohdatei fehlgeschlagen.' }

$n = [int64](Invoke-Psql -Sql 'SELECT count(*) FROM raw.obfcm_cars' -Quiet).Trim()
$d = New-TimeSpan $t0 (Get-Date)
Write-Step ("  {0:N0} Zeilen in {1} ({2:N0} Zeilen/s)" -f $n, $d.ToString('hh\:mm\:ss'), ($n / [Math]::Max(1,$d.TotalSeconds)))

if ($n -ne 7791120) {
    Write-Warning ("Erwartet waren 7.791.120 Zeilen, geladen wurden {0:N0}. Differenz {1:N0} - im Logbuch vermerken." -f $n, (7791120 - $n))
} else {
    Write-Step '  Zeilenzahl stimmt mit der Quellzaehlung vom 10.08.2026 ueberein.' 'Green'
}

if ($aggCsv) {
    Write-Step 'Lade Aggregatdatei'
    & $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 `
        -c "\copy raw.obfcm_cars_agg FROM '$($aggCsv.FullName)' WITH (FORMAT csv, HEADER true, NULL 'NULL')"
    $na = [int64](Invoke-Psql -Sql 'SELECT count(*) FROM raw.obfcm_cars_agg' -Quiet).Trim()
    Write-Step ("  {0:N0} Aggregatzeilen" -f $na)
}

Invoke-Psql -Sql (@"
INSERT INTO meta.load_log (quelle, objekt, source_version, zeitraum, zeilen_soll, zeilen_ist, datei, bemerkung)
VALUES ('EEA OBFCM', 'obfcm_cars', 'v03_r00', '2021-2023', 7791120, $n,
        '$($rawCsv.FullName -replace "'", "''")',
        'DOI 10.2909/7472e340-2766-4461-b83f-d63e2d81edc7, Meldeweg OEM, Laufzeit $($d.ToString('hh\:mm\:ss'))')
"@) | Out-Null

Write-Step 'ANALYZE'
Invoke-Psql -Sql 'ANALYZE raw.obfcm_cars; ANALYZE raw.obfcm_cars_agg;' | Out-Null

Write-Host ''
Write-Step 'Naechster Schritt:' 'Green'
Write-Step '  .\10_run_sql.ps1 -File ..\02_sql\25_core_realworld.sql -OutFile ..\00_doku\realworld_ausgabe.txt'
Write-Step '  .\10_run_sql.ps1 -File ..\02_sql\41_analysen_A4_A5.sql -OutFile ..\00_doku\a4_a5_ausgabe.txt'
