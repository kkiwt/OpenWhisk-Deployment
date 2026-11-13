param(
    [string]$PythonCommand = 'py'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = if ($env:VENV_DIR) { $env:VENV_DIR } else { Join-Path $ScriptDir '.venv' }

if (-not (Get-Command $PythonCommand -ErrorAction SilentlyContinue)) {
    throw "Python launcher '$PythonCommand' was not found. Install Python 3 and retry."
}

& $PythonCommand -3 -m venv $VenvDir
$Python = Join-Path $VenvDir 'Scripts\python.exe'
& $Python -m pip install --upgrade pip
& $Python -m pip install -r (Join-Path $ScriptDir 'requirements.txt')

$EnvFile = Join-Path $ScriptDir '.env'
if (-not (Test-Path $EnvFile)) {
    Copy-Item (Join-Path $ScriptDir '.env.example') $EnvFile
    Write-Host 'Created .env from .env.example. Set DASHBOARD_URL and optionally INGEST_TOKEN.'
}

Write-Host "OpenWhisk Dashboard dependencies are installed in $VenvDir."
