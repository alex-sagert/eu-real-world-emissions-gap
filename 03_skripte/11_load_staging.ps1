<#
.SYNOPSIS
    Lädt die heruntergeladenen CSVs per \copy in die Staging-Schicht und
    protokolliert jeden Ladelauf in meta.load_log.

.BESCHREIBUNG
    Bewusst \copy statt des pgAdmin-Importdialogs: \copy ist der native
    Bulk-Loader und schafft Millionen Zeilen in Minuten statt Stunden.
    Bewusst \copy statt COPY: \copy läuft clientseitig und braucht keine
    Serverrechte auf das Dateisystem.

    Reihenfolge: DDL → Daten → (erst danach!) Indizes und ANALYZE.
    Indizes vor dem Laden kosten ein Vielfaches.

.BEISPIEL
    .\11_load_staging.ps1
    .\11_load_staging.ps1 -Years 2025 -SkipDdl
#>

[CmdletBinding()]
param(
    [int[]] $Years    = @(2021, 2022, 2023, 2024, 2025),
    [string]$RawDir   = (Join-Path $PSScriptRoot '..\01_daten\raw'),
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
    if (-not $c) { throw 'psql nicht gefunden. Pfad über -PsqlExe angeben.' }
    $PsqlExe = $c.Source
}
$RawDir = (Resolve-Path -LiteralPath $RawDir).ProviderPath
$sqlDir = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\02_sql')).ProviderPath

$pgpass = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
if (-not (Test-Path -LiteralPath $pgpass) -and -not $env:PGPASSWORD) {
    $sec = Read-Host "Passwort für $User@$PgHost" -AsSecureString
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$env:PGCLIENTENCODING = 'UTF8'

function Write-Step { param([string]$T, [string]$C='Cyan') Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $T) -ForegroundColor $C }

function Invoke-Psql {
    param([string]$Sql, [switch]$Quiet)
    $psqlArgs = @('-h', $PgHost, '-p', $Port, '-U', $User, '-d', $Database, '-v', 'ON_ERROR_STOP=1')
    if ($Quiet) { $psqlArgs += @('-t', '-A') }
    $psqlArgs += @('-c', $Sql)
    $out = & $PsqlExe @psqlArgs
    if ($LASTEXITCODE -ne 0) { throw "psql-Fehler bei: $Sql" }
    return $out
}

# --- 1) DDL ------------------------------------------------------------------
if (-not $SkipDdl) {
    Write-Step 'Lege Staging-Tabellen an (10_raw_staging_ddl.sql)' 'Green'
    & $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 `
               -f (Join-Path $sqlDir '10_raw_staging_ddl.sql')
    if ($LASTEXITCODE -ne 0) { throw 'DDL fehlgeschlagen.' }
}

# --- 2) co2cars je Jahrgang --------------------------------------------------
$TableByYear = @{ 2021='co2cars_2021Fv24'; 2022='co2cars_2022Fv26'; 2023='co2cars_2023Fv28'
                  2024='co2cars_2024Pv29'; 2025='co2cars_2025Pv31' }

$summary = @()
foreach ($y in $Years) {
    $csv = Join-Path $RawDir ("co2cars_{0}.csv" -f $y)
    if (-not (Test-Path -LiteralPath $csv)) {
        Write-Warning "CSV fehlt, übersprungen: $csv"
        continue
    }

    $mb = [Math]::Round((Get-Item -LiteralPath $csv).Length / 1MB, 1)
    Write-Step ("Lade co2cars_{0}  ({1} MB)" -f $y, $mb) 'Green'
    $t0 = Get-Date

    # Zieltabelle leeren, bevor geladen wird.
    #
    # Das ist die Absicherung fuer Teil-Nachladungen: Wer -Years 2021,2023,2025
    # zusammen mit -SkipDdl aufruft, wuerde sonst an die vorhandenen Daten
    # ANHAENGEN und haette jeden Satz doppelt. Ohne -SkipDdl wiederum wirft die
    # DDL ALLE fuenf Jahrgangstabellen weg - auch die, die gar nicht neu geladen
    # werden sollen. Mit dem TRUNCATE hier ist beides entschaerft:
    # -SkipDdl ist der richtige Weg fuer Teil-Nachladungen und arbeitet sauber.
    Invoke-Psql -Sql "TRUNCATE raw.co2cars_$y" | Out-Null
    Write-Step "  Tabelle geleert"

    # \copy braucht den Pfad in einfachen Anführungszeichen; Backslashes sind ok.
    $sql = "\copy raw.co2cars_$y FROM '$csv' WITH (FORMAT csv, HEADER true, NULL '')"
    & $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 -c $sql
    if ($LASTEXITCODE -ne 0) { throw "Laden von $csv fehlgeschlagen." }

    $n = [int64](Invoke-Psql -Sql "SELECT count(*) FROM raw.co2cars_$y" -Quiet).Trim()
    $dauer = (New-TimeSpan $t0 (Get-Date))
    $rate  = [Math]::Round($n / [Math]::Max(1, $dauer.TotalSeconds))
    Write-Step ("  {0:N0} Zeilen in {1} ({2:N0} Zeilen/s)" -f $n, $dauer.ToString('hh\:mm\:ss'), $rate)

    # co2cars_2025Pv31  ->  Status 'P', Version 'v31'
    if ($TableByYear[$y] -notmatch '^co2cars_\d{4}([FP])v(\d+)$') {
        throw "Tabellenname unerwartet: $($TableByYear[$y])"
    }
    $status  = $Matches[1]
    $version = 'v' + $Matches[2]

    Invoke-Psql -Sql (@"
INSERT INTO meta.load_log (quelle, objekt, source_version, data_status, zeitraum,
                           zeilen_ist, datei, bemerkung)
VALUES ('EEA co2cars', '$($TableByYear[$y])', '$version', '$status', '$y',
        $n, '$($csv -replace "'", "''")',
        'Laufzeit $($dauer.ToString('hh\:mm\:ss')), Fokusländer DE/FR/IT/ES/NL/NO')
"@) | Out-Null

    $summary += [pscustomobject]@{ Jahr=$y; Zeilen=$n; MB=$mb; Dauer=$dauer.ToString('hh\:mm\:ss'); ZeilenProSek=$rate }
}

# --- 3) Historische Massen-Aggregate ----------------------------------------
$hist = Get-ChildItem -LiteralPath $RawDir -Filter 'co2cars_hist_massen_*.csv' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($hist) {
    Write-Step "Lade historische Massen-Aggregate ($($hist.Name))" 'Green'
    & $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 `
        -c "\copy raw.co2cars_hist_massen FROM '$($hist.FullName)' WITH (FORMAT csv, HEADER true, NULL '')"
    $n = [int64](Invoke-Psql -Sql 'SELECT count(*) FROM raw.co2cars_hist_massen' -Quiet).Trim()
    Write-Step ("  {0:N0} Aggregatzeilen" -f $n)
}

$map = Join-Path $RawDir '_co2cars_tabellen.csv'
if (Test-Path -LiteralPath $map) {
    & $PsqlExe -h $PgHost -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 `
        -c "\copy raw.co2cars_tabellen FROM '$map' WITH (FORMAT csv, HEADER true)"
}

# --- 4) Statistiken ----------------------------------------------------------
Write-Step 'ANALYZE über das raw-Schema' 'Green'
Invoke-Psql -Sql 'ANALYZE VERBOSE;' | Out-Null

Write-Host ''
$summary | Format-Table -AutoSize
Write-Host ''
Write-Step 'Nächster Schritt: Datenqualitätsanalyse' 'Green'
Write-Step '  .\10_run_sql.ps1 -File ..\02_sql\15_qualitaet_raw.sql -OutFile ..\00_doku\dq_ausgabe.txt'
