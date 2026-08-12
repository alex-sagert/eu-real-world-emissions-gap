<#
.SYNOPSIS
    Laedt EEA co2cars (VO 2019/631 Art. 7) fuer die Fokuslaender ueber den
    DiscoData-SQL-REST-Endpunkt und schreibt je Jahrgang eine CSV-Datei.

.BESCHREIBUNG
    Der Datahub bietet fuer co2cars keinen CSV-Bulkdownload mehr. Einziger Zugang zu
    Rohdaten auf Fahrzeugebene ist der REST-Endpunkt. Dieser laeuft gegen MS SQL Server
    und wuerde bei Seiten-Paginierung (Parameter p) intern OFFSET verwenden - bei
    ~10 Mio. Zeilen je Jahrgang ist das unbrauchbar langsam.

    Deshalb: Keyset-Paginierung ueber die aufsteigende Spalte ID.
    Fuer 2025 gilt ID 162.744.190 .. 184.519.240 bei 10.833.597 Zeilen (Dichte ~50 %).
    Ein ID-Fenster von 100.000 liefert damit rund 50.000 Zeilen EU-weit bzw. rund
    36.000 Zeilen nach Laenderfilter.

    Das Skript ist wiederaufsetzbar: Der Fortschritt steht in einer .state-Datei je
    Jahrgang. Ein Abbruch kostet hoechstens das gerade laufende Fenster.

.BEISPIEL
    .\01_download_co2cars.ps1
    .\01_download_co2cars.ps1 -Years 2025 -WindowSize 50000
    .\01_download_co2cars.ps1 -Force          # ignoriert vorhandenen Fortschritt
#>

[CmdletBinding()]
param(
    [int[]]   $Years      = @(2021, 2022, 2023, 2024, 2025),
    [string[]]$Countries  = @('DE', 'FR', 'IT', 'ES', 'NL', 'NO'),
    [string]  $OutDir     = (Join-Path $PSScriptRoot '..\01_daten\raw'),
    [int]     $TargetRows = 50000,    # angestrebte Zeilen je Request
    [int64]   $WindowSize = 0,        # 0 = automatisch aus dem ID-Bereich ableiten
    [int64]   $MinWindow  = 5000,
    [int64]   $MaxWindow  = 50000000,
    [int]     $MaxRows    = 100000,   # nrOfHits je Request (hartes Zeilenlimit)
    [int]     $MaxRetry   = 5,
    [switch]  $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

# Tabellennamen am 10.08.2026 durch Probing verifiziert (siehe
# 00_doku/02_Verifikationsprotokoll.md, Abschnitt 1).
$TableByYear = @{
    2021 = 'co2cars_2021Fv24'   # final
    2022 = 'co2cars_2022Fv26'   # final
    2023 = 'co2cars_2023Fv28'   # final
    2024 = 'co2cars_2024Pv29'   # provisional
    2025 = 'co2cars_2025Pv31'   # provisional
}

# Spaltenprojektion: SQL-Ausdruck -> CSV-Spaltenname.
# Reihenfolge bestimmt die Spaltenreihenfolge in der CSV und muss zur
# Staging-DDL in 02_sql/10_raw_staging_ddl.sql passen.
$Columns = [ordered]@{
    'ID'              = 'id'
    'MS'              = 'ms'
    'Mp'              = 'mp'
    'Mh'              = 'mh'
    'Man'             = 'man'
    'TAN'             = 'tan'
    'T'               = 'typ'
    'Va'              = 'va'
    'Ve'              = 've'
    'Mk'              = 'mk'
    'Cn'              = 'cn'
    'Ct'              = 'ct'
    '[M (kg)]'        = 'm_kg'
    'Mt'              = 'mt'
    '[Enedc (g/km)]'  = 'enedc'
    '[Ewltp (g/km)]'  = 'ewltp'
    '[W (mm)]'        = 'w_mm'
    'Ft'              = 'ft'
    'Fm'              = 'fm'
    '[Ec (cm3)]'      = 'ec_cm3'
    '[Ep (KW)]'       = 'ep_kw'
    '[Z (Wh/km)]'     = 'z_whkm'
    'IT'              = 'it_code'
    '[Erwltp (g/km)]' = 'erwltp'
    'Dr'              = 'dr'
    'Fc'              = 'fc'
    'R'               = 'r_count'
    'Year'            = 'year'
    'Status'          = 'status'
    'Version_file'    = 'version_file'
}

$Endpoint = 'https://discodata.eea.europa.eu/sql'

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor $Color
}

function Invoke-Disco {
    <#
        Setzt eine T-SQL-Query gegen DiscoData ab und liefert das results-Array.
        Wirft eine Exception, wenn der Endpunkt einen Fehler meldet.
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$NrOfHits = 100
    )

    $url = '{0}?query={1}&p=1&nrOfHits={2}' -f $Endpoint, [uri]::EscapeDataString($Query), $NrOfHits

    for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 600
        }
        catch {
            if ($attempt -eq $MaxRetry) { throw }
            $wait = [Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-Warning ("Request fehlgeschlagen (Versuch {0}/{1}): {2} - warte {3}s" -f `
                            $attempt, $MaxRetry, $_.Exception.Message, $wait)
            Start-Sleep -Seconds $wait
            continue
        }

        if ($resp.PSObject.Properties.Name -contains 'errors') {
            throw ("DiscoData-Fehler {0}: {1}" -f $resp.errors[0].errorcode, $resp.errors[0].error)
        }
        # Bewusst OHNE fuehrendes Komma: die Funktion gibt die Zeilen einzeln in
        # den Ausgabestrom. Jede Aufrufstelle klammert mit @(...), damit auch ein
        # leeres Ergebnis (0 Zeilen) und ein Einzeltreffer als Array ankommen -
        # sonst wird daraus $null bzw. ein Skalar und .Count scheitert unter
        # StrictMode. Ein zusaetzliches Komma wuerde hier ein verschachteltes
        # Array erzeugen; dann waere $r im Schreibblock nicht die Zeile, sondern
        # das ganze Array.
        return @($resp.results)
    }
}

function ConvertTo-CsvField {
    <#
        Serialisiert einen Wert RFC-4180-konform.
        NULL wird zum leeren, ungequoteten Feld -> passt zu COPY ... WITH (NULL '').
        Leerstrings aus der Quelle (z. B. Spalte IT) bleiben als "" erhalten und
        werden erst in der core-Schicht auf NULL normalisiert.
    #>
    param($Value)

    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($s -match '[",\r\n]') { return '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function Save-State {
    <#
        Sichert den Fortschritt - mit Schreibfreigabe und Wiederholung.

        Warum nicht einfach Set-Content: Liest ein anderes Prozess die Datei
        genau in diesem Moment (etwa die Statusanzeige 05_status.ps1), sperrt
        Windows sie kurzzeitig. Set-Content wirft dann eine IOException, und
        wegen $ErrorActionPreference = 'Stop' bricht der komplette Ladelauf ab.
        Ein fehlgeschlagener Speicherpunkt darf aber niemals den Download
        beenden - im schlimmsten Fall ist der Stand ein Fenster alt.

        FileShare::ReadWrite erlaubt paralleles Lesen, zehn Versuche mit
        200 ms Abstand ueberbruecken kurze Sperren, und wenn es dann immer
        noch nicht klappt, gibt es eine Warnung statt eines Abbruchs.
    #>
    param(
        [string]$Path,
        [int64] $Cursor,
        [int64] $Written,
        [bool]  $Finished = $false
    )

    $json = @{ cursor = $Cursor; written = $Written; finished = $Finished } | ConvertTo-Json -Compress

    for ($versuch = 1; $versuch -le 10; $versuch++) {
        try {
            $fs = New-Object System.IO.FileStream(
                    $Path, [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
                $sw.Write($json); $sw.Flush(); $sw.Dispose()
            } finally { $fs.Dispose() }
            return $true
        }
        catch { Start-Sleep -Milliseconds 200 }
    }
    Write-Warning ("Stand konnte nicht gesichert werden ({0}). Lauf geht weiter, Stand ist ein Fenster alt." -f (Split-Path $Path -Leaf))
    return $false
}

function Read-State {
    <# Liest den Stand ohne die Datei fuer andere zu sperren. #>
    param([string]$Path)
    try {
        $fs = New-Object System.IO.FileStream(
                $Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr   = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd(); $sr.Dispose()
        } finally { $fs.Dispose() }
        return ($text.TrimStart([char]0xFEFF) | ConvertFrom-Json)
    }
    catch { return $null }
}

function Set-CsvRowCount {
    <#
        Kuerzt eine CSV auf Kopfzeile + $DataRows Datenzeilen.

        Warum das noetig ist: Der StreamWriter schreibt laufend auf die Platte,
        die .state-Datei wird erst nach dem vollstaendigen Fenster gesichert.
        Wird der Prozess mitten in einem Fenster beendet (Fenster geschlossen,
        Strg+C, Absturz), enthaelt die CSV mehr Zeilen als der gesicherte Stand
        kennt. Ohne Kuerzung wuerde dieses Fenster beim Wiederaufsetzen ein
        zweites Mal geschrieben - die Datei haette Dubletten, und aufgefallen
        waere es erst bei der Zeilenkontrolle core gegen star.

        Statt die Datei neu zu schreiben wird die Byteposition der Zielzeile
        gesucht und die Datei dort abgeschnitten. Ein Durchlauf, kein zweiter
        Speicherplatz.

        Rueckgabe: die Anzahl Datenzeilen, die vor dem Kuerzen vorhanden war.
    #>
    param([string]$Path, [int64]$DataRows)

    if (-not (Test-Path -LiteralPath $Path)) { return -1 }

    $ziel = $DataRows + 1          # Kopfzeile mitzaehlen
    $fs   = [System.IO.File]::Open($Path, 'Open', 'ReadWrite')
    try {
        $buf     = New-Object byte[] 4194304
        $zeilen  = [int64]0
        $abschnitt = [int64]-1
        $basis   = [int64]0

        while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            for ($i = 0; $i -lt $read; $i++) {
                if ($buf[$i] -eq 10) {                  # Zeilenvorschub
                    $zeilen++
                    if ($zeilen -eq $ziel -and $abschnitt -lt 0) {
                        $abschnitt = $basis + $i + 1
                    }
                }
            }
            $basis += $read
        }
        $vorhanden = $zeilen - 1                        # ohne Kopfzeile

        if ($abschnitt -ge 0 -and $abschnitt -lt $fs.Length) {
            $fs.SetLength($abschnitt)
        }
        return $vorhanden
    }
    finally { $fs.Close(); $fs.Dispose() }
}

# ---------------------------------------------------------------------------
# Hauptlauf
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $OutDir)) {
    [void](New-Item -ItemType Directory -Force -Path $OutDir)
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

$selectList  = ($Columns.Keys | ForEach-Object { "$_ AS $($Columns[$_])" }) -join ', '
$countryList = ($Countries | ForEach-Object { "'$_'" }) -join ','
$header      = ($Columns.Values) -join ','
$utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

$runStart = Get-Date
Write-Step ("Start - Laender: {0} - Jahre: {1}" -f ($Countries -join '/'), ($Years -join '/')) 'Green'

$summary = @()

foreach ($year in $Years) {

    if (-not $TableByYear.Contains($year)) {
        Write-Warning "Kein Tabellenname fuer $year hinterlegt - uebersprungen."
        continue
    }

    $table     = '[CO2Emission].[latest].[{0}]' -f $TableByYear[$year]
    $csvPath   = Join-Path $OutDir ("co2cars_{0}.csv"   -f $year)
    $statePath = Join-Path $OutDir ("co2cars_{0}.state" -f $year)

    # --- Bereich und Sollzahl ermitteln (2 kleine Queries) -----------------
    Write-Step "Jahr $year - ermittle ID-Bereich aus $($TableByYear[$year])"
    $bounds = @(Invoke-Disco -Query ("SELECT MIN(ID) AS mn, MAX(ID) AS mx, COUNT(*) AS n FROM $table") -NrOfHits 1)
    $minId = [int64]$bounds[0].mn
    $maxId = [int64]$bounds[0].mx
    $nAll  = [int64]$bounds[0].n

    $expQ  = "SELECT COUNT(*) AS n FROM $table WHERE MS IN ($countryList)"
    $nExp  = [int64](@(Invoke-Disco -Query $expQ -NrOfHits 1))[0].n

    Write-Step ("  ID {0:N0} .. {1:N0} | gesamt {2:N0} Zeilen | Sollmenge Fokuslaender {3:N0}" -f `
                 $minId, $maxId, $nAll, $nExp)

    # --- Startfenster aus der tatsaechlichen ID-Dichte ableiten ------------
    # Die Dichte schwankt stark zwischen den Jahrgaengen:
    #   2025: ID 162.744.190 .. 184.519.240 bei 10,8 Mio. Zeilen -> ~50 %
    #   2021: ID          1 .. 149.695.089 bei  9,9 Mio. Zeilen -> ~6,6 %
    # Ein festes Fenster waere fuer 2021 rund zehnmal zu klein.
    $span = [double]($maxId - $minId + 1)
    if ($WindowSize -gt 0) {
        $win = [int64]$WindowSize
    } else {
        $idProZeile = $span / [Math]::Max(1.0, [double]$nExp)
        $win = [int64][Math]::Round($idProZeile * $TargetRows)
    }
    if ($win -lt $MinWindow) { $win = $MinWindow }
    if ($win -gt $MaxWindow) { $win = $MaxWindow }

    # Obergrenze an die tatsaechliche Dichte koppeln statt an einen festen Wert.
    # Ohne das schaukelt sich das Fenster ueber leeren Laenderbloecken auf das
    # Vielfache auf und wird danach in vielen Schritten wieder halbiert - jede
    # dieser Halbierungen verwirft eine Antwort mit 100.000 Zeilen.
    $winStart = $win
    $winMax   = [int64][Math]::Min($MaxWindow, $winStart * 4)
    Write-Step ("  ID-Dichte {0:N2} IDs je Zielzeile -> Startfenster {1:N0}, Obergrenze {2:N0} (Ziel {3:N0} Zeilen/Request)" -f `
                 ($span / [Math]::Max(1.0, [double]$nExp)), $win, $winMax, $TargetRows)

    # --- Fortschritt wiederaufnehmen --------------------------------------
    $cursor  = $minId
    $written = [int64]0

    if ((Test-Path $statePath) -and -not $Force) {
        $st = Read-State -Path $statePath
        if ($null -eq $st) { throw "Stand nicht lesbar: $statePath - mit -Force neu starten." }
        $cursor  = [int64]$st.cursor
        $written = [int64]$st.written
        Write-Step ("  Wiederaufnahme bei ID {0:N0} ({1:N0} Zeilen laut Stand)" -f $cursor, $written) 'Yellow'

        # CSV auf den gesicherten Stand zurueckschneiden, bevor angehaengt wird.
        Write-Step '  pruefe CSV gegen den gesicherten Stand ...'
        $vorhanden = Set-CsvRowCount -Path $csvPath -DataRows $written
        if ($vorhanden -lt 0) {
            throw "CSV fehlt, obwohl ein Stand existiert: $csvPath - mit -Force neu starten."
        }
        elseif ($vorhanden -gt $written) {
            Write-Step ("  CSV enthielt {0:N0} Zeilen, {1:N0} davon nach dem gesicherten Stand -> abgeschnitten" -f `
                         $vorhanden, ($vorhanden - $written)) 'Yellow'
        }
        elseif ($vorhanden -lt $written) {
            throw ("CSV hat nur {0:N0} Zeilen, der Stand nennt {1:N0}. Datei unvollstaendig - mit -Force neu starten." -f `
                   $vorhanden, $written)
        }
        else {
            Write-Step '  CSV und Stand stimmen ueberein.'
        }
    }
    else {
        [System.IO.File]::WriteAllText($csvPath, $header + "`r`n", $utf8NoBom)
    }

    # --- Fensterschleife ---------------------------------------------------
    $requests       = 0
    $schemaGeprueft = $false
    $yearStart = Get-Date
    $writer    = New-Object System.IO.StreamWriter($csvPath, $true, $utf8NoBom)

    try {
        while ($cursor -le $maxId) {

            $hi = $cursor + $win
            $q  = "SELECT $selectList FROM $table " +
                  "WHERE ID >= $cursor AND ID < $hi AND MS IN ($countryList)"

            $rows = @(Invoke-Disco -Query $q -NrOfHits $MaxRows)
            $requests++

            # Zeilenlimit erreicht -> Antwort ist abgeschnitten, Fenster halbieren
            # und dasselbe Fenster erneut abfragen (kein Datenverlust).
            if ($rows.Count -ge $MaxRows) {
                if ($win -le $MinWindow) { throw "Fenster bereits bei $win und immer noch am Limit - Abbruch." }
                $win = [int64][Math]::Max($MinWindow, [Math]::Floor($win / 2))
                Write-Warning ("  Zeilenlimit bei ID {0:N0} erreicht - Fenster auf {1:N0} halbiert" -f $cursor, $win)
                continue
            }

            # Leerer Bereich: statt das Fenster blind zu vervierfachen, die
            # Quelle nach der naechsten passenden ID fragen. Das ueberspringt
            # eine Luecke beliebiger Groesse in genau einem billigen Request
            # und verhindert das Aufschaukeln des Fensters.
            if ($rows.Count -eq 0) {
                $nxt = @(Invoke-Disco -NrOfHits 1 -Query `
                    "SELECT MIN(ID) AS mn FROM $table WHERE ID >= $hi AND MS IN ($countryList)")
                if ($nxt.Count -eq 0 -or $null -eq $nxt[0].mn) {
                    $cursor = $maxId + 1          # dahinter kommt nichts mehr
                } else {
                    $cursor = [int64]$nxt[0].mn
                    $win    = $winStart           # Fenster auf den Schaetzwert zuruecksetzen
                }
                $requests++
                continue
            }

            # Einmal je Jahrgang pruefen, ob die Quelle wirklich alle
            # angeforderten Spalten liefert. Stillschweigend leere Spalten
            # waeren genau die Art Fehler, die erst im Bericht auffaellt.
            if (-not $schemaGeprueft -and $rows.Count -gt 0) {
                $vorhanden = @($rows[0].PSObject.Properties.Name)
                $fehlend   = @($Columns.Values | Where-Object { $vorhanden -notcontains $_ })
                if ($fehlend.Count -gt 0) {
                    Write-Warning ("  Jahrgang {0}: Quelle liefert diese Spalten NICHT: {1}" -f $year, ($fehlend -join ', '))
                } else {
                    Write-Step ("  Schemapruefung ok - alle {0} Spalten vorhanden" -f $Columns.Count)
                }
                $schemaGeprueft = $true
            }

            foreach ($r in $rows) {
                $line = New-Object System.Text.StringBuilder
                $first = $true
                foreach ($name in $Columns.Values) {
                    if (-not $first) { [void]$line.Append(',') }
                    # Zugriff ueber PSObject.Properties statt $r.$name: liefert
                    # $null statt einer Exception, falls die EEA in einem
                    # Jahrgang eine Spalte gar nicht ausliefert. Die Spalte
                    # bleibt dann leer, statt den ganzen Lauf abzubrechen.
                    $prop = $r.PSObject.Properties[$name]
                    [void]$line.Append((ConvertTo-CsvField $(if ($prop) { $prop.Value } else { $null })))
                    $first = $false
                }
                $writer.WriteLine($line.ToString())
            }
            $written += $rows.Count
            $cursor   = $hi

            # --- Fenster nachregeln -------------------------------------------
            # Ziel: konstant rund $TargetRows Zeilen je Request. Die ID-Dichte
            # schwankt innerhalb eines Jahrgangs (Nachmeldungen liegen am oberen
            # ID-Rand), deshalb wird nach jedem Request neu geschaetzt.
            # Aenderung pro Schritt auf Faktor 4 begrenzt, damit einzelne
            # Ausreisser das Fenster nicht aufschaukeln.
            if ($rows.Count -gt 0) {
                $faktor = [double]$TargetRows / [double]$rows.Count
                $faktor = [Math]::Max(0.25, [Math]::Min(4.0, $faktor))
                $win    = [int64][Math]::Round($win * $faktor)
            }
            if ($win -lt $MinWindow) { $win = $MinWindow }
            if ($win -gt $winMax)    { $win = $winMax }

            # Stand nach JEDEM Fenster sichern, nicht nur alle 20.
            # Sonst zeigt die state-Datei einen aelteren Cursor an als die CSV
            # tatsaechlich enthaelt - beim Wiederaufsetzen wuerden die Fenster
            # dazwischen ein zweites Mal geschrieben und die Datei haette
            # Dubletten. Der Schreibaufwand ist gegen die Requestdauer nichts.
            $writer.Flush()
            [void](Save-State -Path $statePath -Cursor $cursor -Written $written)

            if ($requests % 10 -eq 0) {
                $pct  = [Math]::Min(100, [Math]::Round(100.0 * ($cursor - $minId) / ($maxId - $minId), 1))
                $rate = [Math]::Round($written / [Math]::Max(1, (New-TimeSpan $yearStart (Get-Date)).TotalSeconds))
                Write-Progress -Activity "co2cars $year" -Status `
                    ("{0:N0} Zeilen | {1} % | {2:N0} Zeilen/s | Fenster {3:N0}" -f $written, $pct, $rate, $win) `
                    -PercentComplete $pct
            }
        }
    }
    finally {
        $writer.Flush(); $writer.Close(); $writer.Dispose()
        Write-Progress -Activity "co2cars $year" -Completed
    }

    [void](Save-State -Path $statePath -Cursor $cursor -Written $written -Finished $true)

    $sizeMb  = [Math]::Round((Get-Item $csvPath).Length / 1MB, 1)
    $elapsed = (New-TimeSpan $yearStart (Get-Date))
    $ok      = ($written -eq $nExp)

    Write-Step ("  fertig: {0:N0} Zeilen (Soll {1:N0}) | {2} MB | {3} Requests | {4}" -f `
                 $written, $nExp, $sizeMb, $requests, $elapsed.ToString('hh\:mm\:ss')) `
               $(if ($ok) { 'Green' } else { 'Red' })

    if (-not $ok) {
        Write-Warning ("  ABWEICHUNG in {0}: {1:N0} Zeilen Differenz. Nicht stillschweigend akzeptieren - " +
                       "im Logbuch vermerken und Ursache klaeren." -f $year, ($nExp - $written))
    }

    $summary += [pscustomobject]@{
        Jahr      = $year
        Tabelle   = $TableByYear[$year]
        Soll      = $nExp
        Ist       = $written
        Differenz = $nExp - $written
        MB        = $sizeMb
        Requests  = $requests
        Dauer     = $elapsed.ToString('hh\:mm\:ss')
    }
}

Write-Host ''
Write-Step ("Gesamtlauf {0}" -f (New-TimeSpan $runStart (Get-Date)).ToString('hh\:mm\:ss')) 'Green'
$summary | Format-Table -AutoSize

$logPath = Join-Path $OutDir '_download_co2cars_log.csv'
$summary | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8
Write-Step "Protokoll: $logPath"
