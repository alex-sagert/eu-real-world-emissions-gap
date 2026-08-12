<#
.SYNOPSIS
    Laedt die EEA-Realverbrauchsdaten (OBFCM, VO 2019/631 Art. 12) als ZIP herunter
    und entpackt sie nach 01_daten\raw\obfcm\<version>.

.BESCHREIBUNG
    Anders als bei co2cars gibt es hier einen echten Direktdownload: einen oeffentlichen
    Nextcloud-Share der EEA, rund 1,5 GB je Fassung. Der Download unterstuetzt Resume
    ueber HTTP-Range, sodass ein Abbruch nicht den ganzen Lauf kostet.

    Es existieren zwei Fassungen desselben Berichtsjahres 2024 (Abdeckung 2021-2023).
    Standardmaessig wird v03 geladen. Mit -Both werden beide geladen, um die Differenz
    dokumentieren zu koennen.

.BEISPIEL
    .\02_download_obfcm.ps1
    .\02_download_obfcm.ps1 -Both
#>

[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\01_daten\raw\obfcm'),
    [switch]$Both,
    [switch]$SkipExtract
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Am 10.08.2026 verifizierte Shares (siehe 00_doku/01_Datenquellen_Steckbriefe.md, Q2)
$Shares = @(
    [pscustomobject]@{
        Name  = 'v03_r00'
        Label = 'eea_t_real-world-co2-emission_p_2024_v03_r00 (primaer)'
        Url   = 'https://sdi.eea.europa.eu/datashare/s/N4FtpL8zDMy9pxP/download'
        Doi   = '10.2909/7472e340-2766-4461-b83f-d63e2d81edc7'
    }
    [pscustomobject]@{
        Name  = 'v01_r00'
        Label = 'eea_t_real-world-co2-emission_p_2024_v01_r00 (Vergleichsfassung)'
        Url   = 'https://sdi.eea.europa.eu/datashare/s/rdowHtqPXRAFDzL/download'
        Doi   = '10.2909/ad652e2b-c4a1-4344-a536-dee5a9fae52d'
    }
)

# Begleitende Metadatenbeschreibung - klein, aber unverzichtbar fuer den Feldkatalog
$MetaPdf = 'https://sdi.eea.europa.eu/catalogue/srv/api/records/7472e340-2766-4461-b83f-d63e2d81edc7/attachments/Real%20world%20emissions%20for%20cars%20and%20vans-Statistical%20metadata_2024.pdf'

if (-not $Both) { $Shares = @($Shares[0]) }
[void](New-Item -ItemType Directory -Force -Path $OutDir)
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

function Write-Step {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor $Color
}

function Get-FileWithResume {
    <# Laedt eine Datei mit HTTP-Range-Resume und Fortschrittsanzeige. #>
    param([string]$Url, [string]$Path)

    $existing = 0
    if (Test-Path -LiteralPath $Path) {
        $existing = (Get-Item -LiteralPath $Path).Length
        Write-Step ("  bereits vorhanden: {0:N1} MB - setze fort" -f ($existing / 1MB)) 'Yellow'
    }

    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'eu-real-world-emissions-gap/1.0 (+Reproduktionsskript)'
    $req.Timeout   = 120000
    $req.ReadWriteTimeout = 600000
    if ($existing -gt 0) { $req.AddRange([int64]$existing) }

    try { $resp = $req.GetResponse() }
    catch [Net.WebException] {
        $r = $_.Exception.Response
        if ($r -and [int]$r.StatusCode -eq 416) { Write-Step '  Datei ist bereits vollstaendig.' 'Green'; return }
        throw
    }

    $total  = $resp.ContentLength + $existing
    $stream = $resp.GetResponseStream()
    $fs     = New-Object System.IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write)
    $buf    = New-Object byte[] 1048576
    $done   = $existing
    $sw     = [Diagnostics.Stopwatch]::StartNew()

    try {
        while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $read)
            $done += $read
            if ($sw.ElapsedMilliseconds -gt 1000) {
                $pct = if ($total -gt 0) { [Math]::Round(100.0 * $done / $total, 1) } else { 0 }
                Write-Progress -Activity (Split-Path $Path -Leaf) `
                    -Status ("{0:N1} / {1:N1} MB" -f ($done / 1MB), ($total / 1MB)) `
                    -PercentComplete ([Math]::Min(100, $pct))
                $sw.Restart()
            }
        }
    }
    finally {
        $fs.Close(); $stream.Close(); $resp.Close()
        Write-Progress -Activity (Split-Path $Path -Leaf) -Completed
    }
}

# --- Metadaten-PDF ----------------------------------------------------------
$pdfPath = Join-Path $OutDir 'EEA_RealWorldEmissions_Statistical_metadata_2024.pdf'
if (-not (Test-Path -LiteralPath $pdfPath)) {
    Write-Step 'Lade Metadatenbeschreibung (PDF)'
    try { Get-FileWithResume -Url $MetaPdf -Path $pdfPath }
    catch { Write-Warning "Metadaten-PDF nicht ladbar: $($_.Exception.Message)" }
}

# --- Datensaetze ------------------------------------------------------------
$results = @()
foreach ($s in $Shares) {
    Write-Step ("Lade {0}" -f $s.Label) 'Green'
    $zip = Join-Path $OutDir ("obfcm_{0}.zip" -f $s.Name)

    $t0 = Get-Date
    Get-FileWithResume -Url $s.Url -Path $zip
    $mb = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
    Write-Step ("  {0:N1} MB in {1}" -f $mb, (New-TimeSpan $t0 (Get-Date)).ToString('hh\:mm\:ss'))

    $dest = Join-Path $OutDir $s.Name
    if (-not $SkipExtract) {
        Write-Step '  entpacke ...'
        [void](New-Item -ItemType Directory -Force -Path $dest)
        Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
        Get-ChildItem -LiteralPath $dest -Recurse -File |
            Select-Object @{n='Datei';e={$_.Name}}, @{n='MB';e={[Math]::Round($_.Length/1MB,1)}} |
            Format-Table -AutoSize
    }

    $results += [pscustomobject]@{ Fassung = $s.Name; ZipMB = $mb; DOI = $s.Doi; Ziel = $dest }
}

Write-Host ''
$results | Format-Table -AutoSize
Write-Step 'Naechster Schritt: Kopfzeilen und Zeilenzahlen der entpackten CSVs pruefen,'
Write-Step 'dann Feldkatalog in 00_doku/03_Feldkatalog_obfcm.md ergaenzen.'
