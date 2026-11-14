param(
    [string]$BindHost = $(if ($env:GATEWAY_BIND_HOST) { $env:GATEWAY_BIND_HOST } else { '0.0.0.0' }),
    [int]$Port = $(if ($env:GATEWAY_PORT) { [int]$env:GATEWAY_PORT } else { 8080 }),
    [string]$TlsIp = $(if ($env:GATEWAY_TLS_IP) { $env:GATEWAY_TLS_IP } else { '100.74.202.23' }),
    [string]$CertFile = $(if ($env:GATEWAY_TLS_CERT) { $env:GATEWAY_TLS_CERT } else { Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'gateway.crt' }),
    [string]$KeyFile = $(if ($env:GATEWAY_TLS_KEY) { $env:GATEWAY_TLS_KEY } else { Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'gateway.key' }),
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

if (-not (Test-Path $CertFile) -or -not (Test-Path $KeyFile)) {
    $OpenSsl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if (-not $OpenSsl) {
        throw "openssl.exe is required to create the self-signed HTTPS certificate."
    }

    & $OpenSsl.Source req -x509 -newkey rsa:2048 -nodes `
        -keyout $KeyFile -out $CertFile -days 365 `
        -subj "/CN=$TlsIp" `
        -addext "subjectAltName=IP:$TlsIp,IP:127.0.0.1,DNS:localhost"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the self-signed HTTPS certificate."
    }
}

Push-Location $ScriptDir
try {
    $Arguments = @(
        '-m', 'uvicorn', 'gateway:app',
        '--host', $BindHost,
        '--port', $Port,
        '--ssl-certfile', $CertFile,
        '--ssl-keyfile', $KeyFile
    )
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
