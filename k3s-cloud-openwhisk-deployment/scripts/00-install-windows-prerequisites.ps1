$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "Missing winget. Install App Installer from Microsoft Store and retry."
}

$packages = @('Git.Git', 'Kubernetes.kubectl', 'Helm.Helm', 'Tailscale.Tailscale')
foreach ($package in $packages) {
    winget install --id $package --exact --accept-source-agreements --accept-package-agreements
}

Write-Host 'Windows host has the k3s administration tools.'
Write-Host 'K3s nodes must run on Ubuntu VMs or WSL2; Windows is not a native k3s node.'
Write-Host 'Use SSH to the Linux VMs and set KUBECONFIG to use kubectl from Windows.'
