<#
.SYNOPSIS
    Führt eine .sql-Datei mit psql gegen die Projektdatenbank aus.

.BESCHREIBUNG
    Dünner Wrapper um psql, damit Pfade, Kodierung und Fehlerabbruch überall gleich sind.
    Das Passwort wird nicht im Skript gehalten: entweder steht es in
    %APPDATA%\postgresql\pgpass.conf, oder es wird einmalig abgefragt.

.BEISPIEL
    .\10_run_sql.ps1 -File ..\02_sql\00_setup_database.sql -Database postgres
    .\10_run_sql.ps1 -File ..\02_sql\01_schemas.sql
    .\10_run_sql.ps1 -File ..\02_sql\15_qualitaet_raw.sql -OutFile ..\00_doku\dq_ausgabe.txt
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$File,
    [string]$Database = 'bd_co2',
    [string]$User     = 'postgres',
    [string]$PgHost   = 'localhost',
    [int]   $Port     = 5432,
    [string]$PsqlExe  = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PsqlExe)) {
    $c = Get-Command psql -ErrorAction SilentlyContinue
    if (-not $c) { throw "psql nicht gefunden. Pfad über -PsqlExe angeben." }
    $PsqlExe = $c.Source
}
if (-not (Test-Path -LiteralPath $File)) { throw "SQL-Datei nicht gefunden: $File" }
$File = (Resolve-Path -LiteralPath $File).ProviderPath

# Passwort: pgpass bevorzugen, sonst einmalig abfragen (bleibt nur im Prozess)
$pgpass = Join-Path $env:APPDATA 'postgresql\pgpass.conf'
if (-not (Test-Path -LiteralPath $pgpass) -and -not $env:PGPASSWORD) {
    $sec = Read-Host "Passwort für $User@$PgHost" -AsSecureString
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

$env:PGCLIENTENCODING = 'UTF8'

$psqlArgs = @('-h', $PgHost, '-p', $Port, '-U', $User, '-d', $Database,
              '-v', 'ON_ERROR_STOP=1', '--echo-errors', '-f', $File)

Write-Host ("[{0}] psql -d {1} -f {2}" -f (Get-Date -Format 'HH:mm:ss'), $Database, (Split-Path $File -Leaf)) -ForegroundColor Cyan
$t0 = Get-Date

# psql schreibt HINWEIS-, WARNUNG- und Fehlerzeilen auf stderr. Mit 2>&1 macht
# PowerShell daraus ErrorRecords, und bei $ErrorActionPreference = 'Stop' bricht
# schon die erste harmlose Hinweiszeile den Lauf ab - etwa
# "Sicht v_co2cars_alle existiert nicht, wird uebersprungen" aus DROP IF EXISTS.
#
# Deshalb hier bewusst 'Continue' und die Ausgabe mit "$_" zu Text machen.
# Ob wirklich etwas schiefging, entscheidet allein der Exit-Code von psql -
# der steht wegen ON_ERROR_STOP=1 auf 3, sobald ein Statement fehlschlaegt.
$alteVorliebe = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if ($OutFile) {
        # Bewusst nicht Tee-Object: das schreibt unter Windows PowerShell 5.1
        # UTF-16 mit Nullbytes zwischen jedem Zeichen. Die Ausgaben sollen aber
        # zitierfaehig ins NvS und in ein Git-Repo - also UTF-8.
        # Der Umweg ueber Write-Host haelt die Live-Ausgabe auf dem Bildschirm.
        & $PsqlExe @psqlArgs 2>&1 |
            ForEach-Object { $zeile = "$_"; Write-Host $zeile; $zeile } |
            Out-File -LiteralPath $OutFile -Encoding utf8
    } else {
        & $PsqlExe @psqlArgs 2>&1 | ForEach-Object { "$_" }
    }
    $code = $LASTEXITCODE
}
finally { $ErrorActionPreference = $alteVorliebe }

$dauer = (New-TimeSpan $t0 (Get-Date)).ToString('hh\:mm\:ss')
if ($code -ne 0) {
    Write-Host ("[{0}] FEHLGESCHLAGEN (Exit {1}) nach {2}" -f (Get-Date -Format 'HH:mm:ss'), $code, $dauer) -ForegroundColor Red
    exit $code
}
Write-Host ("[{0}] fertig in {1}" -f (Get-Date -Format 'HH:mm:ss'), $dauer) -ForegroundColor Green
