<#
.SYNOPSIS
    Zeigt den Fortschritt aller laufenden co2cars-Downloads auf einen Blick.

.BESCHREIBUNG
    Liest die .state-Dateien, die 01_download_co2cars.ps1 nach jedem Fenster
    schreibt, und stellt sie gegen die am 10.08.2026 an der Quelle gezaehlten
    Sollmengen. Laeuft gefahrlos parallel zu den Downloads - es wird nur gelesen.

    Mit -Watch aktualisiert sich die Anzeige alle 20 Sekunden und zeigt
    zusaetzlich die Rate und eine grobe Restzeitschaetzung.

.BEISPIEL
    .\05_status.ps1
    .\05_status.ps1 -Watch
    .\05_status.ps1 -Watch -Interval 60
#>

[CmdletBinding()]
param(
    [string]$RawDir   = (Join-Path $PSScriptRoot '..\01_daten\raw'),
    [switch]$Watch,
    [int]   $Interval = 20
)

$ErrorActionPreference = 'Stop'
$RawDir = (Resolve-Path -LiteralPath $RawDir).ProviderPath

# Sollmengen der Fokuslaender DE/FR/IT/ES/NL/NO, an der Quelle gezaehlt.
# Siehe 00_doku/02_Verifikationsprotokoll.md, Abschnitt 2.
$Soll = @{ 2021 = 7164289; 2022 = 6853648; 2023 = 7685055; 2024 = 7666174; 2025 = 7770432 }

$vorher = @{}

function Read-State {
    <#
        Liest eine .state-Datei OHNE sie fuer den schreibenden Downloader zu
        sperren. Get-Content oeffnet mit einer Freigabe, die dem Downloader das
        Schreiben verwehrt - trifft er dann seinen Speicherpunkt, wirft er eine
        IOException und bricht wegen ErrorActionPreference='Stop' komplett ab.
        Genau das ist am 10.08.2026 passiert und hat zwei Ladelaeufe gekillt.

        FileShare::ReadWrite loest das: beide duerfen gleichzeitig zugreifen.
        Schlaegt das Lesen doch fehl, wird $null geliefert und die Anzeige
        zeigt den letzten bekannten Wert - eine Statusanzeige darf niemals
        den ueberwachten Prozess stoeren.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = New-Object System.IO.FileStream(
                $Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr   = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd(); $sr.Dispose()
        } finally { $fs.Dispose() }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text.TrimStart([char]0xFEFF) | ConvertFrom-Json)
    }
    catch { return $null }
}

function Show-Status {
    $zeilen = @()
    $gesamtIst = 0; $gesamtSoll = 0

    foreach ($j in ($Soll.Keys | Sort-Object)) {
        $state = Join-Path $RawDir ("co2cars_{0}.state" -f $j)
        $csv   = Join-Path $RawDir ("co2cars_{0}.csv"   -f $j)

        $written = 0; $fertig = $false
        $s = Read-State -Path $state
        if ($null -ne $s) {
            $written = [int64]$s.written
            $fertig  = ($s.PSObject.Properties.Name -contains 'finished') -and $s.finished
        }
        elseif ($vorher.ContainsKey($j)) {
            $written = $vorher[$j]        # letzter bekannter Wert statt 0
        }
        $mb = if (Test-Path -LiteralPath $csv) { [Math]::Round((Get-Item -LiteralPath $csv).Length / 1MB, 0) } else { 0 }

        $pct  = [Math]::Round(100.0 * $written / $Soll[$j], 1)
        $rate = $null; $rest = ''
        if ($vorher.ContainsKey($j) -and $written -gt $vorher[$j]) {
            $rate = [Math]::Round(($written - $vorher[$j]) / $Interval)
            if ($rate -gt 0 -and -not $fertig) {
                $sek  = ($Soll[$j] - $written) / $rate
                $rest = [TimeSpan]::FromSeconds($sek).ToString('hh\:mm\:ss')
            }
        }
        $vorher[$j] = $written
        $gesamtIst += $written; $gesamtSoll += $Soll[$j]

        $zeilen += [pscustomobject]@{
            Jahr    = $j
            Zeilen  = '{0,10:N0}' -f $written
            Soll    = '{0,10:N0}' -f $Soll[$j]
            Prozent = '{0,6:N1} %' -f $pct
            MB      = '{0,6:N0}' -f $mb
            'Zeilen/s' = if ($null -ne $rate) { '{0,8:N0}' -f $rate } else { '       -' }
            Rest    = if ($fertig) { 'FERTIG' } elseif ($rest) { $rest } else { '-' }
            Status  = if ($fertig) { 'ok' } elseif ($written -eq 0) { 'nicht gestartet' } else { 'laeuft' }
        }
    }

    Clear-Host
    Write-Host ("co2cars-Download  ·  Stand {0}" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ''
    $zeilen | Format-Table -AutoSize
    $g = [Math]::Round(100.0 * $gesamtIst / $gesamtSoll, 1)
    Write-Host ("Gesamt: {0:N0} von {1:N0} Zeilen  =  {2} %" -f $gesamtIst, $gesamtSoll, $g) -ForegroundColor Green
    Write-Host ''
    Write-Host 'Fertig ist ein Jahrgang, wenn Status = ok steht.' -ForegroundColor DarkGray
    Write-Host 'Im Downloader-Fenster erscheint dann die gruene Zeile "fertig: N Zeilen (Soll N)".' -ForegroundColor DarkGray
    if ($Watch) { Write-Host "`nAktualisierung alle $Interval s · Strg+C zum Beenden" -ForegroundColor DarkGray }
}

if ($Watch) {
    Show-Status
    while ($true) { Start-Sleep -Seconds $Interval; Show-Status }
} else {
    Show-Status
}
