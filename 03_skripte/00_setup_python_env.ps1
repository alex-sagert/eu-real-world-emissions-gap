<#
.SYNOPSIS
    Legt das virtuelle Python-Environment fuer die Streamlit-App an.

.BESCHREIBUNG
    Geprueft am 07.08.2026: Python 3.11 ist installiert, streamlit / pandas /
    psycopg2-binary / sqlalchemy / plotly fehlen im globalen Interpreter.
    Dieses Skript legt .venv im Projektordner an und installiert 05_streamlit\requirements.txt.
#>

[CmdletBinding()]
param(
    [string]$PythonExe = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    [string]$VenvPath  = (Join-Path $PSScriptRoot '..\.venv')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PythonExe)) {
    $cand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cand) { throw "Python 3.11 nicht gefunden. Pfad ueber -PythonExe angeben." }
    $PythonExe = $cand.Source
    Write-Warning "Erwarteter Pfad fehlt, verwende stattdessen: $PythonExe"
}

$ver = & $PythonExe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))"
Write-Host "Python: $ver ($PythonExe)" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $VenvPath)) {
    Write-Host "Lege venv an: $VenvPath" -ForegroundColor Cyan
    & $PythonExe -m venv $VenvPath
}

$venvPy  = Join-Path $VenvPath 'Scripts\python.exe'
$reqPath = Join-Path $PSScriptRoot '..\05_streamlit\requirements.txt'

& $venvPy -m pip install --upgrade pip
& $venvPy -m pip install -r $reqPath

Write-Host ''
& $venvPy -m pip list --format=columns
Write-Host ''
Write-Host 'Aktivieren mit:' -ForegroundColor Green
Write-Host "  $VenvPath\Scripts\Activate.ps1"
Write-Host 'App starten mit:' -ForegroundColor Green
Write-Host "  $venvPy -m streamlit run .\05_streamlit\app.py"
