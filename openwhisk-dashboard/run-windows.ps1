param(
    [string]$BindHost = $(if ($env:DASHBOARD_BIND_HOST) { $env:DASHBOARD_BIND_HOST } else { '0.0.0.0' }),
    [int]$Port = $(if ($env:DASHBOARD_PORT) { [int]$env:DASHBOARD_PORT } else { 9000 })
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = if ($env:VENV_DIR) { $env:VENV_DIR } else { Join-Path $ScriptDir '.venv' }
$Python = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path $Python)) {
    throw "Dashboard virtualenv is missing. Run .\install-windows.ps1 first."
}
if (-not (Test-Path (Join-Path $ScriptDir '.env'))) {
    throw ".env is missing. Run .\install-windows.ps1 and configure it."
}

Push-Location $ScriptDir
try {
    & $Python -m uvicorn dashboard:app --host $BindHost --port $Port --workers 1
    if ($LASTEXITCODE -ne 0) {
        throw "Dashboard exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
