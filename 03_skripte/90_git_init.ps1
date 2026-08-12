<#
.SYNOPSIS
    Legt das Git-Repository an und erzeugt den ersten Commit.

.BESCHREIBUNG
    Muss auf dem Windows-Rechner laufen, nicht in einer Linux-Umgebung: Git
    schreibt seine Objektdateien mit Umbenennungen, die ueber einen gemounteten
    Ordner nicht zuverlaessig funktionieren.

    Das Skript ist absichtlich vorsichtig:
      - Es prueft vorher, ob versehentlich Rohdaten eingecheckt wuerden.
      - Es bricht ab, wenn die Gesamtgroesse ueber 400 MB liegt.
      - Es setzt keinen Remote und pusht nichts. Das machst du bewusst selbst.

.BEISPIEL
    .\03_skripte\90_git_init.ps1
    .\03_skripte\90_git_init.ps1 -Pruefen     # nur anzeigen, nichts anlegen
#>

[CmdletBinding()]
param(
    [string]$Wurzel  = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath,
    [string]$Name    = 'Alexander Sagert',
    [string]$EMail   = 'lx.sagert@gmail.com',
    [switch]$Pruefen,
    [switch]$Neu
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Wurzel

function Schritt { param([string]$T, [string]$C='Cyan')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $T) -ForegroundColor $C }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git nicht gefunden. Git for Windows installieren: https://git-scm.com/download/win'
}

# --- 0) Zustand des Repositories pruefen -------------------------------------
#
# Eine liegengebliebene index.lock stammt fast immer aus einem abgebrochenen
# git-Aufruf. Solange sie existiert, verweigert git jede Indexoperation.
# Mit -Neu wird das gesamte .git-Verzeichnis verworfen und neu begonnen; die
# Arbeitsdateien bleiben dabei unberuehrt.
if ($Neu -and (Test-Path .git)) {
    Schritt 'Verwerfe vorhandenes .git und beginne neu' 'Yellow'
    Remove-Item -LiteralPath .git -Recurse -Force
}

if (Test-Path .git\index.lock) {
    Write-Host ''
    Write-Host 'Es liegt eine index.lock im Repository.' -ForegroundColor Red
    Write-Host 'Das ist der Rest eines abgebrochenen git-Aufrufs. Zwei Wege:' -ForegroundColor Yellow
    Write-Host '  Nur die Sperre entfernen:   Remove-Item .git\index.lock' -ForegroundColor Yellow
    Write-Host '  Ganz neu beginnen:          .\03_skripte\90_git_init.ps1 -Neu' -ForegroundColor Yellow
    Write-Host ''
    throw 'Abgebrochen, damit nichts halb Angelegtes entsteht.'
}

# --- 1) Was wuerde eingecheckt? ----------------------------------------------
Schritt 'Pruefe, was ins Repository ginge' 'Green'

if (-not (Test-Path .git)) { git init -q -b main }

# Kandidatenliste ueber git selbst, damit .gitignore wirklich angewandt wird
$kandidaten = git ls-files --others --cached --exclude-standard
$gesamt = 0
$gross  = @()
foreach ($f in $kandidaten) {
    if (Test-Path -LiteralPath $f) {
        $l = (Get-Item -LiteralPath $f).Length
        $gesamt += $l
        if ($l -gt 5MB) { $gross += [pscustomobject]@{ MB = [math]::Round($l/1MB,1); Datei = $f } }
    }
}

$mb = [math]::Round($gesamt / 1MB, 1)
Schritt ("{0} Dateien, {1} MB" -f $kandidaten.Count, $mb)

if ($gross) {
    Write-Host ''
    Write-Host 'Dateien ueber 5 MB:' -ForegroundColor Yellow
    $gross | Sort-Object MB -Descending | Format-Table -AutoSize
}

# Rohdaten duerfen unter keinen Umstaenden hinein
$verdaechtig = $kandidaten | Where-Object { $_ -match '^01_daten/(raw|interim)/' -and $_ -notmatch '\.gitkeep$' `
                                            -and $_ -notmatch '_co2cars_tabellen\.csv$' `
                                            -and $_ -notmatch '_download_co2cars_log\.csv$' }
if ($verdaechtig) {
    Write-Host ''
    Write-Host 'ABBRUCH: Rohdaten wuerden eingecheckt.' -ForegroundColor Red
    $verdaechtig | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    throw 'Bitte .gitignore pruefen.'
}

if ($mb -gt 400) {
    throw ("ABBRUCH: {0} MB ueberschreiten das Limit von 400 MB." -f $mb)
}

if ($Pruefen) {
    Write-Host ''
    Write-Host 'Nur Pruefung - es wurde nichts committet.' -ForegroundColor Yellow
    return
}

# --- 2) Commit ----------------------------------------------------------------
git config user.name  $Name
git config user.email $EMail

# Keine automatischen Co-Autoren-Zeilen im Commit.
git config --local commit.cleanup strip

Schritt 'Lege den ersten Commit an' 'Green'
git add -A

$nachricht = @'
Realverbrauchsluecke der EU-Neuwagenflotte

Fuehrt 45 Mio. Datensaetze aus dem EU-CO2-Monitoring (VO (EU) 2019/631
Art. 7 und Art. 12) sowie die SMARD-Stromerzeugung in einer
vierschichtigen PostgreSQL-Datenbank zusammen und wertet die Abweichung
zwischen zertifiziertem und gemessenem Kraftstoffverbrauch aus.

- Ladepipeline mit Keyset-Paginierung gegen den DiscoData-SQL-Endpunkt
- Sternschema mit jahresweise partitionierter Faktentabelle, 37,1 Mio. Zeilen
- Analysen A1 bis A7, Well-to-Wheel-Vergleich, Regression in KNIME
- Streamlit-Anwendung auf den Ergebnistabellen
'@
git commit -q -m $nachricht

Schritt 'Fertig' 'Green'
git --no-pager log --oneline -1
Write-Host ''
Write-Host 'Naechster Schritt - Repository auf GitHub anlegen und verbinden:' -ForegroundColor Yellow
Write-Host '  git remote add origin https://github.com/<konto>/eu-real-world-emissions-gap.git'
Write-Host '  git push -u origin main'
