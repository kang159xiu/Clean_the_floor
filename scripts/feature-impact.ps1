param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Query
)

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot "docs/features/manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$features = @($manifest.features)
$matchedAny = $false

function Test-ExactValue($values, [string]$needle) {
    foreach ($value in @($values)) {
        $text = ([string]$value).Replace('\', '/')
        if ($text.Equals($needle, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

foreach ($rawQuery in $Query) {
    $needle = ([string]$rawQuery).Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($needle)) {
        continue
    }
    Write-Host "Query: $needle" -ForegroundColor Cyan
    $exactMatches = @()
    $studioCandidates = @()
    $textMatches = @()
    foreach ($feature in $features) {
        if (
            (Test-ExactValue $feature.primarySources $needle) -or
            (Test-ExactValue $feature.relatedSources $needle) -or
            (Test-ExactValue $feature.remotes $needle) -or
            (Test-ExactValue $feature.snapshotFields $needle) -or
            (Test-ExactValue $feature.persistentFields $needle)
        ) {
            $exactMatches += $feature
            continue
        }

        foreach ($studioPathValue in @($feature.studioPaths)) {
            $studioPath = ([string]$studioPathValue).Replace('\', '/')
            if (
                -not [string]::IsNullOrWhiteSpace($studioPath) -and
                $needle.StartsWith($studioPath, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $studioCandidates += [pscustomobject]@{
                    Feature = $feature
                    PrefixLength = $studioPath.Length
                }
            }
        }

        $identityValues = @($feature.id, $feature.title, $feature.document, $feature.keywords)
        foreach ($value in $identityValues) {
            $text = ([string]$value).Replace('\', '/')
            if (
                -not [string]::IsNullOrWhiteSpace($text) -and
                (
                    $text.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $needle.IndexOf($text, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                )
            ) {
                $textMatches += $feature
                break
            }
        }
    }
    if ($exactMatches.Count -gt 0) {
        $matches = @($exactMatches | Sort-Object id -Unique)
    } elseif ($studioCandidates.Count -gt 0) {
        $longestPrefix = ($studioCandidates | Measure-Object PrefixLength -Maximum).Maximum
        $matches = @($studioCandidates | Where-Object PrefixLength -eq $longestPrefix | ForEach-Object Feature | Sort-Object id -Unique)
    } else {
        $matches = @($textMatches | Sort-Object id -Unique)
    }
    if ($matches.Count -eq 0) {
        Write-Host "  No feature mapping found." -ForegroundColor Yellow
        continue
    }
    $matchedAny = $true
    foreach ($feature in $matches) {
        Write-Host "  [$($feature.id)] $($feature.title)" -ForegroundColor Green
        Write-Host "    Document: $($feature.document)"
        if (@($feature.dependencies).Count -gt 0) {
            Write-Host "    Dependencies: $([string]::Join(', ', @($feature.dependencies)))"
        }
        Write-Host "    Minimum regression:"
        foreach ($check in @($feature.regressionChecks)) {
            Write-Host "      - $check"
        }
    }
}

if (-not $matchedAny) {
    exit 2
}
