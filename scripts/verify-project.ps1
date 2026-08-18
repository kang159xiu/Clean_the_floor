param(
    [string]$OutputPath = (Join-Path $env:TEMP "CleanTheFloor-feature-docs-verify.rbxlx")
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

& (Join-Path $PSScriptRoot "validate-feature-docs.ps1")
$validationSucceeded = $?
if (-not $validationSucceeded) {
    exit 1
}

Push-Location $repoRoot
try {
    & rojo build default.project.json -o $OutputPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

Write-Host "Project verification passed." -ForegroundColor Green
Write-Host " Build: $OutputPath"
