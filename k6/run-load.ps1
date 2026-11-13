param(
    [double]$Rate = $(if ($env:RATE) { [double]$env:RATE } else { 50 }),
    [string]$Duration = $(if ($env:DURATION) { $env:DURATION } else { '5m' }),
    [string]$GatewayUrl = $(if ($env:GATEWAY_URL) { $env:GATEWAY_URL } else { 'http://localhost:8080' }),
    [string]$OutputDir = $(if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { Join-Path $PSScriptRoot ("results\quick_{0}" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')) })
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command k6 -ErrorAction SilentlyContinue)) {
    throw "k6 is not installed. Run .\install-windows.ps1 first."
}
if ($Rate -le 0) {
    throw "Rate must be positive."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$Arguments = @(
    'run',
    '-e', "RATE=$Rate",
    '-e', "DURATION=$Duration",
    '-e', "GATEWAY_URL=$GatewayUrl",
    '-e', "TARGET_MODE=$(if ($env:TARGET_MODE) { $env:TARGET_MODE } else { 'gateway' })",
    '-e', "DIRECT_API_URL=$(if ($env:DIRECT_API_URL) { $env:DIRECT_API_URL } else { '' })",
    '-e', "DIRECT_AUTH=$(if ($env:DIRECT_AUTH) { $env:DIRECT_AUTH } else { '' })",
    '-e', "DIRECT_CLUSTER=$(if ($env:DIRECT_CLUSTER) { $env:DIRECT_CLUSTER } else { 'unknown' })",
    '-e', "DIRECT_NAMESPACE=$(if ($env:DIRECT_NAMESPACE) { $env:DIRECT_NAMESPACE } else { '_' })",
    '-e', "DRY_RUN=$(if ($env:DRY_RUN) { $env:DRY_RUN } else { '0' })",
    "--summary-export=$OutputDir\k6.json",
    (Join-Path $PSScriptRoot 'load.js')
)

Write-Host "Running K6 at $Rate req/s for $Duration against $GatewayUrl"
Write-Host "Output: $OutputDir"
& k6 @Arguments
if ($LASTEXITCODE -ne 0) {
    throw "k6 exited with code $LASTEXITCODE."
}
