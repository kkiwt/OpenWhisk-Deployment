param(
    [string]$BindHost = $(if ($env:GATEWAY_BIND_HOST) { $env:GATEWAY_BIND_HOST } else { '0.0.0.0' }),
    [int]$Port = $(if ($env:GATEWAY_PORT) { [int]$env:GATEWAY_PORT } else { 8080 }),
    [switch]$Reload
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir = if ($env:VENV_DIR) { $env:VENV_DIR } else { Join-Path $ScriptDir 'venv' }
$Python = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path $Python)) {
    throw "Gateway virtualenv is missing. Run .\install-windows.ps1 first."
}
if (-not (Test-Path (Join-Path $ScriptDir '.env'))) {
    throw ".env is missing. Run .\install-windows.ps1 and configure it."
}

Push-Location $ScriptDir
try {
    $Arguments = @('-m', 'uvicorn', 'gateway:app', '--host', $BindHost, '--port', $Port)
    if ($Reload) {
        $Arguments += '--reload'
    }
    & $Python @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Gateway exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
