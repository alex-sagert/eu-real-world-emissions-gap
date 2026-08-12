<#
.SYNOPSIS
    Historische Zeitreihe 2010-2020 fuer H4 (Gewichtsspirale) - vorverdichtet an der Quelle.

.BESCHREIBUNG
    H4 fragt nach der Entwicklung der Fahrzeugmasse ueber 15 Jahre. Dafuer werden keine
    Einzelfahrzeuge gebraucht, sondern eine Verteilung. Row-Level fuer 2010-2020 waere
    rund 100 Mio. zusaetzliche Zeilen ueber REST - unverhaeltnismaessig.

    Stattdessen wird an der Quelle vorverdichtet: je Land, Jahr, Kraftstoffart und
    50-kg-Massenklasse werden Anzahl und Mittelwerte geholt. Das ergibt ein Histogramm,
    aus dem sich lokal Median, Perzentile und massengewichtete Mittel exakt genug
    rekonstruieren lassen - bei wenigen zehntausend Zeilen statt 100 Mio.

    Diese Entscheidung wird im Bericht unter Methodik begruendet.

    Schritt 1 des Skripts ermittelt ausserdem die Tabellennamen der Altjahrgaenge durch
    Probing, weil DiscoData die Systemtabellen sperrt und der Datahub nur den aktuellen
    Jahrgang nennt.

.BEISPIEL
    .\03_download_co2cars_hist.ps1
    .\03_download_co2cars_hist.ps1 -Years 2015,2016 -BucketKg 25
#>

[CmdletBinding()]
param(
    [int[]] $Years    = @(2010..2020),
    [string]$OutDir   = (Join-Path $PSScriptRoot '..\01_daten\raw'),
    [int]   $BucketKg = 50,
    [int]   $MaxVersionProbe = 40
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Endpoint = 'https://discodata.eea.europa.eu/sql'

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Force -Path $OutDir) }
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

function Write-Step { param([string]$T, [string]$C='Cyan') Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $T) -ForegroundColor $C }

function Invoke-Disco {
    param([string]$Query, [int]$NrOfHits = 100, [switch]$Quiet)
    $url = '{0}?query={1}&p=1&nrOfHits={2}' -f $Endpoint, [uri]::EscapeDataString($Query), $NrOfHits
    try { $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 600 }
    catch { if ($Quiet) { return $null } throw }
    if ($resp.PSObject.Properties.Name -contains 'errors') {
        if ($Quiet) { return $null }
        throw ("DiscoData-Fehler {0}: {1}" -f $resp.errors[0].errorcode, $resp.errors[0].error)
    }
    # Ohne fuehrendes Komma; die Aufrufstellen klammern mit @(...).
    return @($resp.results)
}

# ---------------------------------------------------------------------------
# Schritt 1 - Tabellennamen der Altjahrgaenge ermitteln
# ---------------------------------------------------------------------------
Write-Step 'Ermittle Tabellennamen durch Probing (Systemtabellen sind gesperrt)' 'Green'

$known = @{ 2021='co2cars_2021Fv24'; 2022='co2cars_2022Fv26'; 2023='co2cars_2023Fv28'
            2024='co2cars_2024Pv29'; 2025='co2cars_2025Pv31' }
$found = @{}

foreach ($y in $Years) {
    if ($known.ContainsKey($y)) { $found[$y] = $known[$y]; continue }
    $hit = $null
    foreach ($st in 'F','P') {
        for ($v = 1; $v -le $MaxVersionProbe; $v++) {
            $t = "co2cars_{0}{1}v{2}" -f $y, $st, $v
            $r = Invoke-Disco -Query "SELECT TOP 1 Year AS y FROM [CO2Emission].[latest].[$t]" -NrOfHits 1 -Quiet
            if ($null -ne $r -and $r.Count -gt 0) { $hit = $t; break }
        }
        if ($hit) { break }
    }
    if ($hit) { $found[$y] = $hit; Write-Step ("  {0} -> {1}" -f $y, $hit) }
    else       { Write-Warning "  $y - keine Tabelle gefunden (bis v$MaxVersionProbe geprueft)" }
}

$mapPath = Join-Path $OutDir '_co2cars_tabellen.csv'
$found.GetEnumerator() | Sort-Object Name |
    Select-Object @{n='jahr';e={$_.Key}}, @{n='tabelle';e={$_.Value}} |
    Export-Csv -LiteralPath $mapPath -NoTypeInformation -Encoding UTF8
Write-Step "Tabellenzuordnung gespeichert: $mapPath"

# ---------------------------------------------------------------------------
# Schritt 2 - Aggregate je Land / Jahr / Antrieb / Massenklasse
# ---------------------------------------------------------------------------
$rowsAll = @()

foreach ($y in ($found.Keys | Sort-Object)) {
    $table  = '[CO2Emission].[latest].[{0}]' -f $found[$y]
    $bucket = "(CAST([M (kg)] AS INT) / $BucketKg) * $BucketKg"

    $q = "SELECT MS AS ms, $bucket AS mass_bucket, Ft AS ft, COUNT(*) AS n, " +
         "AVG(CAST([M (kg)] AS FLOAT)) AS avg_mass, " +
         "AVG(CAST([Ewltp (g/km)] AS FLOAT)) AS avg_ewltp, " +
         "AVG(CAST([Enedc (g/km)] AS FLOAT)) AS avg_enedc, " +
         "AVG(CAST([Ep (KW)] AS FLOAT)) AS avg_kw " +
         "FROM $table WHERE [M (kg)] IS NOT NULL " +
         "GROUP BY MS, $bucket, Ft"

    Write-Step ("Jahr {0} ({1}) - Aggregat wird berechnet ..." -f $y, $found[$y])
    $rows = @(Invoke-Disco -Query $q -NrOfHits 200000)

    foreach ($r in $rows) {
        $rowsAll += [pscustomobject]@{
            jahr = $y; tabelle = $found[$y]; ms = $r.ms; mass_bucket = $r.mass_bucket
            ft = $r.ft; n = $r.n; avg_mass = $r.avg_mass; avg_ewltp = $r.avg_ewltp
            avg_enedc = $r.avg_enedc; avg_kw = $r.avg_kw
        }
    }
    Write-Step ("  {0:N0} Aggregatzeilen, {1:N0} Fahrzeuge" -f $rows.Count, (($rows | Measure-Object n -Sum).Sum))
}

$outPath = Join-Path $OutDir ("co2cars_hist_massen_{0}kg.csv" -f $BucketKg)
$rowsAll | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Step ("Fertig: {0:N0} Zeilen -> {1}" -f $rowsAll.Count, $outPath) 'Green'
Write-Step ("Abgedeckte Fahrzeuge insgesamt: {0:N0}" -f (($rowsAll | Measure-Object n -Sum).Sum))
