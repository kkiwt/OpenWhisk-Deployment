$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required. Install App Installer from Microsoft Store and retry."
}

winget install --id GrafanaLabs.k6 --exact --accept-source-agreements --accept-package-agreements
if (-not (Get-Command k6 -ErrorAction SilentlyContinue)) {
    Write-Host 'k6 was installed. Open a new PowerShell window if this window cannot find it yet.'
} else {
    k6 version
}
