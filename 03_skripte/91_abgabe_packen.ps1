<#
.SYNOPSIS
    Packt das Projekt als ZIP fuer die Abgabe — ohne Zugangsdaten, ohne Rohdaten.

.BESCHREIBUNG
    Git schuetzt vor versehentlich veroeffentlichten Passwoertern, ein ZIP nicht.
    Wer den Projektordner von Hand zippt, packt .streamlit/secrets.toml mit ein.
    Dieses Skript schliesst aus, was nicht nach draussen darf, und nennt vorher,
    was es tut.

    Ausgeschlossen:
      .streamlit/secrets.toml   Datenbankpasswort
      *.pgpass, .env            weitere Zugangsdaten
      01_daten/raw, interim     rund 8,2 GB Rohdaten, reproduzierbar
      .venv, __pycache__        Python-Umgebung
      .git                      Versionsgeschichte
      _archiv                   ueberholte Zwischenstaende

    Das Skript prueft das Ergebnis GEGEN und bricht ab, wenn trotzdem eine
    Zugangsdatei im Archiv gelandet ist.

.BEISPIEL
    .\03_skripte\91_abgabe_packen.ps1
    .\03_skripte\91_abgabe_packen.ps1 -Ziel D:\Abgabe
#>

[CmdletBinding()]
param(
    [string]$Wurzel = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath,
    [string]$Ziel   = [Environment]::GetFolderPath('Desktop'),
    [int]   $MaxMB  = 500
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Wurzel

function Schritt { param([string]$T, [string]$C='Cyan')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $T) -ForegroundColor $C }

$name    = 'Sagert_Alexander__BD__Projekt__08_2026'
$archiv  = Join-Path $Ziel "$name.zip"
$sammeln = Join-Path $env:TEMP $name

# --- Muster, die nicht ins Archiv duerfen ------------------------------------
# Anders als .gitignore behaelt diese Liste die Pruefungsdokumente in
# 06_abgabe — das Archiv geht an die Hochschule, das Repository an die
# Oeffentlichkeit. Zwei Adressaten, zwei Zuschnitte.
$raus = @(
    '\.venv\',  '\__pycache__\', '\.git\', '\_archiv\',
    '\01_daten\raw\', '\01_daten\interim\',
    '\04_knime\_bau',                     # Bauordner des Workflows
    '\.streamlit\secrets.toml',           # das Beispiel bleibt drin
    '.pgpass', '\.env', '~$'
)

function IstAusgeschlossen([string]$pfad) {
    foreach ($m in $raus) {
        if ($pfad -like "*$m*") {
            # secrets.toml.beispiel ist ausdruecklich erlaubt
            if ($pfad -like '*secrets.toml.beispiel') { continue }
            return $true
        }
    }
    return $false
}

# --- 1) Sammeln ---------------------------------------------------------------
Schritt 'Sammle die Dateien' 'Green'
if (Test-Path $sammeln) { Remove-Item $sammeln -Recurse -Force }
New-Item -ItemType Directory -Path $sammeln | Out-Null

$dateien = Get-ChildItem -LiteralPath $Wurzel -Recurse -File -Force |
           Where-Object { -not (IstAusgeschlossen $_.FullName) }

foreach ($f in $dateien) {
    $rel = $f.FullName.Substring($Wurzel.Length).TrimStart('\')
    $neu = Join-Path $sammeln $rel
    $ordner = Split-Path $neu -Parent
    if (-not (Test-Path $ordner)) { New-Item -ItemType Directory -Path $ordner -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $neu
}

$mb = [math]::Round(($dateien | Measure-Object Length -Sum).Sum / 1MB, 1)
Schritt ("{0} Dateien, {1} MB" -f $dateien.Count, $mb)

# --- 2) Gegenprobe ------------------------------------------------------------
Schritt 'Pruefe das Ergebnis auf Zugangsdaten' 'Green'
$verdacht = Get-ChildItem -LiteralPath $sammeln -Recurse -File -Force |
            Where-Object { $_.Name -eq 'secrets.toml' -or $_.Name -like '*.pgpass' -or $_.Name -eq '.env' }
if ($verdacht) {
    Write-Host ''
    Write-Host 'ABBRUCH: Zugangsdaten im Archiv gefunden.' -ForegroundColor Red
    $verdacht | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Red }
    Remove-Item $sammeln -Recurse -Force
    throw 'Nichts gepackt.'
}

# Zweite Gegenprobe: steht irgendwo ein Passwort im Klartext?
#
# Der Wert wird herausgelesen und geprueft, statt ihn im regulaeren Ausdruck
# auszuschliessen. Sonst schlaegt die Pruefung bei jedem Anleitungstext an, der
# ein Beispielpasswort zeigt - genau das ist beim ersten Lauf passiert.
#
# Als Platzhalter gilt: nur Grossbuchstaben und Unterstriche, Punktfolgen,
# oder die bekannten Beispielwoerter. Alles andere ist verdaechtig.
function IstPlatzhalter([string]$wert) {
    if ([string]::IsNullOrWhiteSpace($wert)) { return $true }
    if ($wert -match '^[A-Z_]{3,}$')         { return $true }   # DEIN_PASSWORT
    if ($wert -match '^\.{2,}$')             { return $true }   # ...
    if ($wert -match '^(dein|test|beispiel|changeme|xxx)') { return $true }
    return $false
}

$echteTreffer = @()
$zuPruefen = Get-ChildItem -LiteralPath $sammeln -Recurse -File -Force `
             -Include *.toml,*.ps1,*.py,*.md,*.sql,*.txt,*.json,*.yml,*.yaml
foreach ($datei in $zuPruefen) {
    $nr = 0
    foreach ($zeile in (Get-Content -LiteralPath $datei.FullName -ErrorAction SilentlyContinue)) {
        $nr++
        $m = [regex]::Match($zeile, '(?i)(password|passwort|pwd)\s*[:=]\s*["'']([^"'']+)["'']')
        if ($m.Success -and -not (IstPlatzhalter $m.Groups[2].Value)) {
            $echteTreffer += [pscustomobject]@{ Datei = $datei.FullName; Zeile = $nr }
        }
    }
}

if ($echteTreffer) {
    Write-Host ''
    Write-Host 'ABBRUCH: In diesen Dateien steht ein Passwort im Klartext.' -ForegroundColor Red
    $echteTreffer | ForEach-Object { Write-Host ("  {0}:{1}" -f $_.Datei, $_.Zeile) -ForegroundColor Red }
    Remove-Item $sammeln -Recurse -Force
    throw 'Nichts gepackt.'
}
Schritt ("  keine Zugangsdaten gefunden ({0} Dateien geprueft)" -f $zuPruefen.Count)

if ($mb -gt $MaxMB) {
    Remove-Item $sammeln -Recurse -Force
    throw ("ABBRUCH: {0} MB ueberschreiten das Limit von {1} MB." -f $mb, $MaxMB)
}

# --- 3) Packen ----------------------------------------------------------------
Schritt 'Packe das Archiv' 'Green'
if (Test-Path $archiv) { Remove-Item $archiv -Force }
Compress-Archive -Path (Join-Path $sammeln '*') -DestinationPath $archiv -CompressionLevel Optimal
Remove-Item $sammeln -Recurse -Force

$zipMB = [math]::Round((Get-Item $archiv).Length / 1MB, 1)
Write-Host ''
Schritt ("Fertig: {0}  ({1} MB)" -f $archiv, $zipMB) 'Green'
Write-Host ''
Write-Host 'Enthalten sind Dokumentation, SQL, Skripte, KNIME, Visualisierungen,' -ForegroundColor DarkGray
Write-Host 'Streamlit und die Abgabedokumente. Nicht enthalten: Rohdaten,' -ForegroundColor DarkGray
Write-Host 'Zugangsdaten, Python-Umgebung, Versionsgeschichte.' -ForegroundColor DarkGray
