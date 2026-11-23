$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is required. Install App Installer from Microsoft Store and retry."
}

winget install --id Derailed.k9s --exact --accept-source-agreements --accept-package-agreements
if (-not (Get-Command k9s -ErrorAction SilentlyContinue)) {
    Write-Host 'K9s was installed. Open a new PowerShell window if this window cannot find it yet.'
} else {
    k9s version
}
