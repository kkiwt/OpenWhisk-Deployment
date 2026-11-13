param(
    [string]$PythonCommand = 'py'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = if ($env:VENV_DIR) { $env:VENV_DIR } else { Join-Path $ScriptDir 'venv' }

if (-not (Get-Command $PythonCommand -ErrorAction SilentlyContinue)) {
    throw "Python launcher '$PythonCommand' was not found. Install Python 3 and retry."
}

& $PythonCommand -3 -m venv $VenvDir
& (Join-Path $VenvDir 'Scripts\python.exe') -m pip install --upgrade pip
& (Join-Path $VenvDir 'Scripts\python.exe') -m pip install -r (Join-Path $ScriptDir 'requirements.txt')

$EnvFile = Join-Path $ScriptDir '.env'
$ExampleFile = Join-Path $ScriptDir '.env.example'
if (-not (Test-Path $EnvFile)) {
    if (-not (Test-Path $ExampleFile)) {
        throw ".env.example is missing."
    }
    Copy-Item $ExampleFile $EnvFile
    Write-Host "Created .env from .env.example. Update cluster URLs and credentials before starting."
}

Write-Host "Gateway dependencies are installed in $VenvDir."
