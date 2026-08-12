<#
.SYNOPSIS
    Zieht echte Beispielzeilen und Häufigkeitsverteilungen aus der EEA-Quelle,
    damit die Variablen in Excel geprüft werden können - bevor 37 Mio. Zeilen laufen.

.BESCHREIBUNG
    Schreibt nach 01_daten\referenz:
      stichprobe_co2cars_<jahr>.csv    500 vollständige Beispielzeilen (alle Spalten)
      verteilung_<spalte>_<jahr>.csv   Häufigkeit je Ausprägung der kategorialen Spalten
      nullquoten_<jahr>.csv            Belegungsgrad je Spalte
      wertebereiche_<jahr>.csv         Min/Max/Mittel der numerischen Spalten

    Alle Dateien sind klein und lassen sich direkt in Excel öffnen
    (Semikolon als Trennzeichen, damit Excel-DE sie ohne Importdialog aufteilt).

.BEISPIEL
    .\04_stichprobe.ps1
    .\04_stichprobe.ps1 -Year 2023 -SampleSize 2000
#>

[CmdletBinding()]
param(
    [int]   $Year       = 2025,
    [int]   $SampleSize = 500,
    [string]$Country    = 'DE',
    [string]$OutDir     = (Join-Path $PSScriptRoot '..\01_daten\referenz'),
    [char]  $Delimiter  = ';'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TableByYear = @{ 2021='co2cars_2021Fv24'; 2022='co2cars_2022Fv26'; 2023='co2cars_2023Fv28'
                  2024='co2cars_2024Pv29'; 2025='co2cars_2025Pv31' }
if (-not $TableByYear.ContainsKey($Year)) { throw "Kein Tabellenname für $Year hinterlegt." }
$table = '[CO2Emission].[latest].[{0}]' -f $TableByYear[$Year]

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Force -Path $OutDir) }
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

function Write-Step { param([string]$T,[string]$C='Cyan') Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$T) -ForegroundColor $C }

function Invoke-Disco {
    param([string]$Query, [int]$NrOfHits = 1000)
    $url = 'https://discodata.eea.europa.eu/sql?query={0}&p=1&nrOfHits={1}' -f [uri]::EscapeDataString($Query), $NrOfHits
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 300
    if ($resp.PSObject.Properties.Name -contains 'errors') {
        throw ("DiscoData-Fehler {0}: {1}" -f $resp.errors[0].errorcode, $resp.errors[0].error)
    }
    return @($resp.results)
}

function Save-Csv {
    param($Data, [string]$Name)
    $p = Join-Path $OutDir $Name
    $Data | Export-Csv -LiteralPath $p -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter
    Write-Step ("  -> {0}  ({1} Zeilen)" -f $Name, @($Data).Count)
    return $p
}

Write-Step ("Stichprobe aus {0}" -f $TableByYear[$Year]) 'Green'

# ---------------------------------------------------------------------------
# 1) Vollständige Beispielzeilen - alle Spalten, so wie die EEA sie liefert
# ---------------------------------------------------------------------------
Write-Step "1/5  $SampleSize Beispielzeilen ($Country, alle Spalten)"
$sample = Invoke-Disco -Query "SELECT TOP $SampleSize * FROM $table WHERE MS = '$Country'" -NrOfHits $SampleSize
Save-Csv $sample ("stichprobe_co2cars_{0}_{1}.csv" -f $Year, $Country) | Out-Null

# Spaltenliste der Quelle festhalten - die EEA ändert sie zwischen Jahrgängen
$spalten = $sample[0].PSObject.Properties.Name
Save-Csv ($spalten | ForEach-Object {
    [pscustomobject]@{ position = [array]::IndexOf($spalten, $_) + 1; quellspalte = $_ }
}) ("spaltenliste_{0}.csv" -f $Year) | Out-Null

# ---------------------------------------------------------------------------
# 2) Häufigkeitsverteilungen der kategorialen Spalten
# ---------------------------------------------------------------------------
Write-Step '2/5  Häufigkeitsverteilungen'
foreach ($sp in 'MS','Ft','Fm','Ct','Cr','Status','Version_file','IT','Mp','Mk') {
    $top = if ($sp -in 'Mp','Mk','IT') { 'TOP 300 ' } else { '' }
    $ord = if ($top) { ' ORDER BY n DESC' } else { '' }
    try {
        $rows = Invoke-Disco -Query "SELECT $top$sp AS wert, COUNT(*) AS n FROM $table GROUP BY $sp$ord" -NrOfHits 5000
        $ges  = ($rows | Measure-Object n -Sum).Sum
        $out  = $rows | Sort-Object { [int]$_.n } -Descending | ForEach-Object {
            [pscustomobject]@{
                spalte  = $sp
                wert    = $(if ([string]::IsNullOrEmpty([string]$_.wert)) { '(leer)' } else { $_.wert })
                anzahl  = $_.n
                prozent = [Math]::Round(100.0 * $_.n / $ges, 4)
            }
        }
        Save-Csv $out ("verteilung_{0}_{1}.csv" -f $sp.ToLower(), $Year) | Out-Null
    }
    catch { Write-Warning "  $sp : $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 3) Belegungsgrad je Spalte (COUNT(spalte) zählt NULL nicht mit)
# ---------------------------------------------------------------------------
Write-Step '3/5  Belegungsgrad je Spalte'
$pruefSpalten = @{
    'Mp'='Mp'; 'Mh'='Mh'; 'Man'='Man'; 'MMS'='MMS'; 'TAN'='TAN'; 'Mk'='Mk'; 'Cn'='Cn'
    'M (kg)'='[M (kg)]'; 'Mt'='Mt'; 'Enedc (g/km)'='[Enedc (g/km)]'; 'Ewltp (g/km)'='[Ewltp (g/km)]'
    'W (mm)'='[W (mm)]'; 'At1 (mm)'='[At1 (mm)]'; 'Ec (cm3)'='[Ec (cm3)]'; 'Ep (KW)'='[Ep (KW)]'
    'Z (Wh/km)'='[Z (Wh/km)]'; 'Erwltp (g/km)'='[Erwltp (g/km)]'; 'Ernedc (g/km)'='[Ernedc (g/km)]'
    'Dr'='Dr'; 'Fc'='Fc'; 'R'='R'
}
$gesamt = [int64](Invoke-Disco -Query "SELECT COUNT(*) AS n FROM $table" -NrOfHits 1)[0].n
$belegung = foreach ($k in ($pruefSpalten.Keys | Sort-Object)) {
    try {
        $n = [int64](Invoke-Disco -Query "SELECT COUNT($($pruefSpalten[$k])) AS n FROM $table" -NrOfHits 1)[0].n
        [pscustomobject]@{
            spalte = $k; belegt = $n; fehlt = $gesamt - $n
            prozent_belegt = [Math]::Round(100.0 * $n / $gesamt, 3)
        }
    } catch { Write-Warning "  $k : $($_.Exception.Message)" }
}
Save-Csv ($belegung | Sort-Object prozent_belegt) ("nullquoten_{0}.csv" -f $Year) | Out-Null

# ---------------------------------------------------------------------------
# 4) Wertebereiche der numerischen Spalten
# ---------------------------------------------------------------------------
Write-Step '4/5  Wertebereiche numerisch'
$bereiche = foreach ($k in 'M (kg)','Mt','Ewltp (g/km)','Enedc (g/km)','Ec (cm3)','Ep (KW)','Z (Wh/km)','Erwltp (g/km)','Fc') {
    $expr = "[$k]"
    try {
        $r = (Invoke-Disco -Query "SELECT MIN($expr) AS mn, MAX($expr) AS mx, AVG(CAST($expr AS FLOAT)) AS av FROM $table" -NrOfHits 1)[0]
        [pscustomobject]@{ spalte=$k; minimum=$r.mn; maximum=$r.mx; mittelwert=[Math]::Round([double]$r.av,2) }
    } catch { Write-Warning "  $k : $($_.Exception.Message)" }
}
Save-Csv $bereiche ("wertebereiche_{0}.csv" -f $Year) | Out-Null

# ---------------------------------------------------------------------------
# 5) Kreuztabelle Ft x Fm - der Kern der Antriebsdefinition
# ---------------------------------------------------------------------------
Write-Step '5/5  Kreuztabelle Ft x Fm (Grundlage von dim_powertrain)'
$kreuz = Invoke-Disco -Query "SELECT Ft AS ft, Fm AS fm, COUNT(*) AS n, AVG(CAST([Ewltp (g/km)] AS FLOAT)) AS avg_ewltp, AVG(CAST([M (kg)] AS FLOAT)) AS avg_masse FROM $table GROUP BY Ft, Fm" -NrOfHits 5000
$gesK = ($kreuz | Measure-Object n -Sum).Sum
Save-Csv ($kreuz | Sort-Object { [int]$_.n } -Descending | ForEach-Object {
    [pscustomobject]@{
        ft = $_.ft; fm = $_.fm; anzahl = $_.n
        prozent   = [Math]::Round(100.0 * $_.n / $gesK, 4)
        avg_ewltp = $(if ($null -ne $_.avg_ewltp) { [Math]::Round([double]$_.avg_ewltp, 1) } else { $null })
        avg_masse = $(if ($null -ne $_.avg_masse) { [Math]::Round([double]$_.avg_masse, 0) } else { $null })
    }
}) ("kreuztabelle_ft_fm_{0}.csv" -f $Year) | Out-Null

Write-Host ''
Write-Step "Fertig. Alle Dateien liegen in:" 'Green'
Write-Host "  $OutDir"
Write-Host ''
Write-Step 'Zum Ansehen: Ordner öffnen und die CSVs doppelklicken (Trennzeichen Semikolon).'
Write-Step 'Wichtigste Datei zuerst: kreuztabelle_ft_fm_*.csv'
