<#
.SYNOPSIS
    Führt die komplette Verarbeitungskette aus, mit Zeitmessung und Protokoll.

.BESCHREIBUNG
    Ein Aufruf statt neun. Jeder Schritt schreibt seine Ausgabe nach 00_doku,
    die Laufzeiten landen in 00_doku\_laufzeiten.csv - und genau die gehören
    in den Bericht.

    Bricht ein Schritt ab, hält die Kette an und nennt die Datei mit dem Fehler.
    Mit -Ab kann danach ab genau diesem Schritt fortgesetzt werden, ohne den
    Load zu wiederholen.

.BEISPIEL
    .\99_run_all.ps1                      # alles
    .\99_run_all.ps1 -Ab 20_core          # ab der core-Schicht
    .\99_run_all.ps1 -NurSql              # Laden ueberspringen
    .\99_run_all.ps1 -Liste               # nur anzeigen, was laufen wuerde
#>

[CmdletBinding()]
param(
    [string]$Ab,
    [switch]$NurSql,
    [switch]$Liste,
    [switch]$OhneSmard
)

$ErrorActionPreference = 'Stop'
$root   = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$doku   = Join-Path $root '00_doku'
$sql    = Join-Path $root '02_sql'
$skript = Join-Path $root '03_skripte'

# Schritt = @{ Name; Typ (sql|ps|py); Datei; Beschreibung; Optional }
$Kette = @(
    @{ Name='00_setup_database';  Typ='sql'; Datei='00_setup_database.sql';  Db='postgres'; Text='Datenbank bd_co2 anlegen'; Optional=$true }
    @{ Name='01_schemas';         Typ='sql'; Datei='01_schemas.sql';         Text='Schemata raw/core/star/mart/meta' }
    @{ Name='11_load_staging';    Typ='ps';  Datei='11_load_staging.ps1';    Text='37,1 Mio. co2cars-Zeilen laden'; Load=$true }
    @{ Name='12_load_obfcm';      Typ='ps';  Datei='12_load_obfcm.ps1';      Text='7,8 Mio. OBFCM-Zeilen laden';    Load=$true }
    @{ Name='15_qualitaet_raw';   Typ='sql'; Datei='15_qualitaet_raw.sql';   Text='Datenqualitaet der Rohschicht' }
    @{ Name='20_core';            Typ='sql'; Datei='20_core.sql';            Text='Typisierung, Antriebsklasse, Oeko-Codes' }
    @{ Name='25_core_realworld';  Typ='sql'; Datei='25_core_realworld.sql';  Text='OBFCM typisieren, Luecke je Fahrzeug' }
    @{ Name='30_star';            Typ='sql'; Datei='30_star.sql';            Text='Sternschema und Faktentabelle' }
    @{ Name='32_indizes_explain'; Typ='sql'; Datei='32_indizes_explain.sql'; Text='Indizes, ANALYZE, EXPLAIN-Belege' }
    @{ Name='40_analysen';        Typ='sql'; Datei='40_analysen_A1_A6.sql';  Text='A1, A2, A3, A6' }
    @{ Name='41_analysen_A4_A5';  Typ='sql'; Datei='41_analysen_A4_A5.sql';  Text='A4 Luecke, A5 Rangumkehr' }
    @{ Name='20_smard';           Typ='py';  Datei='20_download_smard.py';   Text='SMARD-Strommix herunterladen'; Smard=$true }
    @{ Name='21_load_smard';      Typ='ps';  Datei='21_load_smard.ps1';      Text='SMARD-CSV in die Rohschicht laden'; Smard=$true; Load=$true }
    @{ Name='13_smard_strommix';  Typ='sql'; Datei='13_smard_strommix.sql';  Text='CO2-Intensitaet des Strommixes'; Smard=$true }
    @{ Name='42_wtw_vergleich';   Typ='sql'; Datei='42_wtw_vergleich.sql';   Text='Well-to-Wheel, entscheidet H2'; Smard=$true }
    @{ Name='43_knime_basis';     Typ='sql'; Datei='43_knime_trainingsbasis.sql'; Text='Trainingsbasis fuer die Regression' }
    @{ Name='44_hersteller';      Typ='sql'; Datei='44_hersteller_luecke.sql';    Text='A7 Luecke je Hersteller, Mixeffekt' }
    @{ Name='45_oeko_gutschrift'; Typ='sql'; Datei='45_oeko_gutschrift_pruefung.sql'; Text='Pruefung: ist die Oeko-Gutschrift in Ewltp abgezogen?' }
)

if ($Ab) {
    # Bewusst eine einfache Schleife statt [array]::FindIndex mit
    # [Predicate[object]] - Windows PowerShell 5.1 kann den Scriptblock nicht in
    # den generischen Delegaten wandeln und meldet "keine Ueberladung gefunden".
    $i = -1
    for ($k = 0; $k -lt $Kette.Count; $k++) {
        if ($Kette[$k].Name -eq $Ab) { $i = $k; break }
    }
    if ($i -lt 0) {
        throw ("Unbekannter Schritt '{0}'. Verfuegbar: {1}" -f $Ab, (($Kette | ForEach-Object { $_.Name }) -join ', '))
    }
    $Kette = $Kette[$i..($Kette.Count - 1)]
}
if ($NurSql)    { $Kette = $Kette | Where-Object { -not $_.Load } }
if ($OhneSmard) { $Kette = $Kette | Where-Object { -not $_.Smard } }

if ($Liste) {
    $Kette | ForEach-Object { '{0,-20} {1,-4} {2}' -f $_.Name, $_.Typ, $_.Text }
    return
}

$venvPy = Join-Path $root '.venv\Scripts\python.exe'
$ergebnisse = @()
$start = Get-Date

Write-Host ''
Write-Host ("Kette startet - {0} Schritte" -f $Kette.Count) -ForegroundColor Green
Write-Host ''

foreach ($s in $Kette) {
    $t0 = Get-Date
    Write-Host ("[{0}] {1,-20} {2}" -f (Get-Date -Format 'HH:mm:ss'), $s.Name, $s.Text) -ForegroundColor Cyan

    try {
        # Auch hier: Meldungen externer Programme auf stderr duerfen die Kette
        # nicht beenden. Ueber Erfolg entscheidet der Exit-Code. Von den
        # aufgerufenen PowerShell-Skripten geworfene Fehler sind echte
        # terminierende Fehler und laufen trotzdem in den catch-Block.
        $ErrorActionPreference = 'Continue'
        switch ($s.Typ) {
            'sql' {
                # Hashtable-Splatting, nicht Array-Splatting: Ein gesplattetes
                # Array uebergibt POSITIONELL, der Text "-File" landet dann als
                # Wert im ersten Parameter. Nur eine Hashtable bindet benannt.
                # (Bei einer .exe ist Array-Splatting dagegen richtig, dort sind
                # alle Argumente ohnehin nur Zeichenketten - siehe 10_run_sql.ps1.)
                $runArgs = @{
                    File    = (Join-Path $sql  $s.Datei)
                    OutFile = (Join-Path $doku ("{0}_ausgabe.txt" -f $s.Name))
                }
                if ($s.Db) { $runArgs['Database'] = $s.Db }
                & (Join-Path $skript '10_run_sql.ps1') @runArgs
                if ($LASTEXITCODE -ne 0) { throw "psql meldet Exit $LASTEXITCODE" }
            }
            'ps'  { & (Join-Path $skript $s.Datei) }
            'py'  {
                if (-not (Test-Path -LiteralPath $venvPy)) { throw "venv fehlt - zuerst 00_setup_python_env.ps1" }
                & $venvPy (Join-Path $skript $s.Datei)
                if ($LASTEXITCODE -ne 0) { throw "Python meldet Exit $LASTEXITCODE" }
            }
        }
        $ErrorActionPreference = 'Stop'
        $status = 'ok'
    }
    catch {
        $ErrorActionPreference = 'Stop'
        $status = 'FEHLER'
        $dauer  = (New-TimeSpan $t0 (Get-Date))
        $ergebnisse += [pscustomobject]@{ Schritt=$s.Name; Status=$status; Dauer=$dauer.ToString('hh\:mm\:ss') }

        Write-Host ''
        Write-Host ("ABBRUCH bei {0} nach {1}" -f $s.Name, $dauer.ToString('hh\:mm\:ss')) -ForegroundColor Red
        Write-Host ("  Datei    : {0}" -f $s.Datei) -ForegroundColor Red
        Write-Host ("  Meldung  : {0}" -f $_.Exception.Message) -ForegroundColor Red
        if ($s.Typ -eq 'sql') {
            Write-Host ("  Ausgabe  : {0}" -f (Join-Path $doku ("{0}_ausgabe.txt" -f $s.Name))) -ForegroundColor Yellow
            Write-Host '  Die letzten Zeilen der Ausgabedatei nennen das fehlerhafte Statement.' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host ("Nach der Korrektur fortsetzen mit:  .\99_run_all.ps1 -Ab {0}" -f $s.Name) -ForegroundColor Yellow
        Write-Host ''
        $ergebnisse | Format-Table -AutoSize
        exit 1
    }

    $dauer = (New-TimeSpan $t0 (Get-Date))
    Write-Host ("           fertig in {0}" -f $dauer.ToString('hh\:mm\:ss')) -ForegroundColor DarkGray
    $ergebnisse += [pscustomobject]@{ Schritt=$s.Name; Status=$status; Dauer=$dauer.ToString('hh\:mm\:ss') }
}

$gesamt = (New-TimeSpan $start (Get-Date))
Write-Host ''
Write-Host ("Kette vollstaendig durchgelaufen - {0}" -f $gesamt.ToString('hh\:mm\:ss')) -ForegroundColor Green
$ergebnisse | Format-Table -AutoSize

$ergebnisse | Export-Csv -LiteralPath (Join-Path $doku '_laufzeiten.csv') -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host 'Laufzeiten fuer den Bericht: 00_doku\_laufzeiten.csv' -ForegroundColor Green
Write-Host 'Als Naechstes pruefen:' -ForegroundColor Green
Write-Host '  1. 30_star_ausgabe.txt      - Zeilenkontrolle core gegen star muss 0 zeigen'
Write-Host '  2. 41_analysen_A4_A5_ausgabe.txt - muss +16,0 % und +317,8 % reproduzieren'
Write-Host '  3. 32_indizes_explain_ausgabe.txt - Laufzeiten ins Logbuch uebertragen'
