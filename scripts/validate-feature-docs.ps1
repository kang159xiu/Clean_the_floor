param()

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$manifestPath = Join-Path $repoRoot "docs/features/manifest.json"
$errors = New-Object System.Collections.Generic.List[string]

function Add-ValidationError([string]$message) {
    $script:errors.Add($message)
}

function Get-RelativePath([string]$fullPath) {
    $normalizedRoot = $script:repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $normalizedPath = [System.IO.Path]::GetFullPath($fullPath)
    if (-not $normalizedPath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside repository: $fullPath"
    }
    return $normalizedPath.Substring($normalizedRoot.Length).Replace('\', '/')
}

function Resolve-RepoPath([string]$relativePath) {
    return [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot $relativePath))
}

function Get-UniqueStrings($values) {
    return @($values | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function Compare-StringSets([string]$leftName, $leftValues, [string]$rightName, $rightValues) {
    $left = Get-UniqueStrings $leftValues
    $right = Get-UniqueStrings $rightValues
    foreach ($value in $left) {
        if ($right -notcontains $value) {
            Add-ValidationError "$leftName contains '$value' but $rightName does not."
        }
    }
    foreach ($value in $right) {
        if ($left -notcontains $value) {
            Add-ValidationError "$rightName contains '$value' but $leftName does not."
        }
    }
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Feature manifest is missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$features = @($manifest.features)
$requiredSections = @($manifest.requiredSections | ForEach-Object { [string]$_ })
if ($manifest.schemaVersion -ne 1) {
    Add-ValidationError "Unsupported feature manifest schemaVersion '$($manifest.schemaVersion)'."
}
if ($features.Count -ne 15) {
    Add-ValidationError "Expected 15 active feature domains, found $($features.Count)."
}

$featureIds = @{}
$documentOwners = @{}
$primaryOwners = @{}
$remoteOwners = @{}
$snapshotOwners = @{}
$persistentOwners = @{}

foreach ($feature in $features) {
    $featureId = [string]$feature.id
    if ([string]::IsNullOrWhiteSpace($featureId)) {
        Add-ValidationError "Feature with empty id found."
        continue
    }
    if ($featureIds.ContainsKey($featureId)) {
        Add-ValidationError "Duplicate feature id '$featureId'."
    } else {
        $featureIds[$featureId] = $feature
    }
    if ([string]$feature.status -ne "active") {
        Add-ValidationError "Current feature '$featureId' must have status 'active'."
    }

    $document = ([string]$feature.document).Replace('\', '/')
    if ($documentOwners.ContainsKey($document)) {
        Add-ValidationError "Feature document '$document' is shared by '$featureId' and '$($documentOwners[$document])'."
    } else {
        $documentOwners[$document] = $featureId
    }
    $documentPath = Resolve-RepoPath $document
    if (-not (Test-Path -LiteralPath $documentPath -PathType Leaf)) {
        Add-ValidationError "Feature '$featureId' document does not exist: $document"
    } else {
        $content = Get-Content -LiteralPath $documentPath -Raw -Encoding UTF8
        foreach ($section in $requiredSections) {
            $pattern = "(?m)^##\s+" + [regex]::Escape($section) + "\s*$"
            if (-not [regex]::IsMatch($content, $pattern)) {
                Add-ValidationError "Feature '$featureId' is missing section '## $section'."
            }
        }
    }

    foreach ($source in @($feature.primarySources)) {
        $relativeSource = ([string]$source).Replace('\', '/')
        if ($primaryOwners.ContainsKey($relativeSource)) {
            Add-ValidationError "Primary source '$relativeSource' belongs to both '$featureId' and '$($primaryOwners[$relativeSource])'."
        } else {
            $primaryOwners[$relativeSource] = $featureId
        }
        if (-not (Test-Path -LiteralPath (Resolve-RepoPath $relativeSource) -PathType Leaf)) {
            Add-ValidationError "Feature '$featureId' references missing primary source '$relativeSource'."
        }
    }
    foreach ($source in @($feature.relatedSources)) {
        $relativeSource = ([string]$source).Replace('\', '/')
        if (-not (Test-Path -LiteralPath (Resolve-RepoPath $relativeSource) -PathType Leaf)) {
            Add-ValidationError "Feature '$featureId' references missing related source '$relativeSource'."
        }
    }
    foreach ($dependency in @($feature.dependencies)) {
        if ([string]::IsNullOrWhiteSpace([string]$dependency)) {
            Add-ValidationError "Feature '$featureId' has an empty dependency."
        }
    }

    foreach ($remote in @($feature.remotes)) {
        $name = [string]$remote
        if ($remoteOwners.ContainsKey($name)) {
            Add-ValidationError "Remote '$name' belongs to both '$featureId' and '$($remoteOwners[$name])'."
        } else {
            $remoteOwners[$name] = $featureId
        }
    }
    foreach ($field in @($feature.snapshotFields)) {
        $name = [string]$field
        if ($snapshotOwners.ContainsKey($name)) {
            Add-ValidationError "Snapshot field '$name' belongs to both '$featureId' and '$($snapshotOwners[$name])'."
        } else {
            $snapshotOwners[$name] = $featureId
        }
    }
    foreach ($field in @($feature.persistentFields)) {
        $name = [string]$field
        if ($persistentOwners.ContainsKey($name)) {
            Add-ValidationError "Persistent field '$name' belongs to both '$featureId' and '$($persistentOwners[$name])'."
        } else {
            $persistentOwners[$name] = $featureId
        }
    }
}

foreach ($feature in $features) {
    foreach ($dependency in @($feature.dependencies)) {
        if (-not $featureIds.ContainsKey([string]$dependency)) {
            Add-ValidationError "Feature '$($feature.id)' references unknown dependency '$dependency'."
        }
    }
}

$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "src") -Recurse -File -Filter "*.luau" | ForEach-Object {
    Get-RelativePath $_.FullName
} | Sort-Object)
foreach ($source in $sourceFiles) {
    if (-not $primaryOwners.ContainsKey($source)) {
        Add-ValidationError "Luau source has no primary feature owner: $source"
    }
}
foreach ($source in @($primaryOwners.Keys)) {
    if ($sourceFiles -notcontains $source) {
        Add-ValidationError "Manifest primary source is not in the Luau inventory: $source"
    }
}

$serverInit = Get-Content -LiteralPath (Join-Path $repoRoot "src/server/init.server.luau") -Raw -Encoding UTF8
$clientInit = Get-Content -LiteralPath (Join-Path $repoRoot "src/client/init.client.luau") -Raw -Encoding UTF8
$serverRemoteMatches = [regex]::Matches(
    $serverInit,
    'getOrCreate\(\s*remotesFolder,\s*"Remote(?:Event|Function)",\s*"([^"]+)"\s*\)',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$clientRemoteMatches = [regex]::Matches($clientInit, 'getRemote\("([^"]+)"\)')
$serverRemotes = @($serverRemoteMatches | ForEach-Object { $_.Groups[1].Value })
$clientRemotes = @($clientRemoteMatches | ForEach-Object { $_.Groups[1].Value })
Compare-StringSets "server Remote declarations" $serverRemotes "client Remote declarations" $clientRemotes
Compare-StringSets "runtime Remote declarations" $serverRemotes "feature manifest Remote ownership" @($remoteOwners.Keys)

$playerDataPath = Join-Path $repoRoot "src/server/Services/PlayerDataService.luau"
$playerData = Get-Content -LiteralPath $playerDataPath -Raw -Encoding UTF8
$schemaMatch = [regex]::Match($playerData, '(?m)^local DATA_SCHEMA_VERSION = (\d+)\s*$')
if (-not $schemaMatch.Success) {
    Add-ValidationError "Could not extract DATA_SCHEMA_VERSION from PlayerDataService."
} elseif ([int]$schemaMatch.Groups[1].Value -ne [int]$manifest.mainDataSchemaVersion) {
    Add-ValidationError "PlayerDataService schema is $($schemaMatch.Groups[1].Value), manifest says $($manifest.mainDataSchemaVersion)."
}

$snapshotMatch = [regex]::Match(
    $playerData,
    '(?ms)^function PlayerDataService:GetSnapshot\(player\).*?^\treturn \{(?<body>.*?)^\t\}\r?\nend'
)
if (-not $snapshotMatch.Success) {
    Add-ValidationError "Could not extract PlayerDataService:GetSnapshot return table."
    $snapshotFields = @()
} else {
    $snapshotFields = @([regex]::Matches($snapshotMatch.Groups['body'].Value, '(?m)^\t\t([A-Za-z][A-Za-z0-9_]*)\s*=') | ForEach-Object {
        $_.Groups[1].Value
    })
}
Compare-StringSets "GetSnapshot fields" $snapshotFields "feature manifest snapshot ownership" @($snapshotOwners.Keys)

$persistentMatch = [regex]::Match(
    $playerData,
    '(?ms)^function PlayerDataService:_savePersistentData\(player, state, maximumAttempts\).*?^\tlocal payload = \{(?<body>.*?)^\t\}\r?\n'
)
if (-not $persistentMatch.Success) {
    Add-ValidationError "Could not extract PlayerDataService persistent payload."
    $persistentFields = @()
} else {
    $persistentFields = @([regex]::Matches($persistentMatch.Groups['body'].Value, '(?m)^\t\t([A-Za-z][A-Za-z0-9_]*)\s*=') | ForEach-Object {
        $_.Groups[1].Value
    })
}
Compare-StringSets "persistent payload fields" $persistentFields "feature manifest persistent ownership" @($persistentOwners.Keys)

$studioContractPath = Join-Path $repoRoot "docs/05_STUDIO_OBJECT_CONTRACT.md"
$studioContract = Get-Content -LiteralPath $studioContractPath -Raw -Encoding UTF8
$studioHeadings = @([regex]::Matches($studioContract, '(?m)^#{2,3}\s+(.+?)\s*$') | ForEach-Object {
    $_.Groups[1].Value.Trim()
})
foreach ($feature in $features) {
    foreach ($section in @($feature.studioContractSections)) {
        if ($studioHeadings -notcontains [string]$section) {
            Add-ValidationError "Feature '$($feature.id)' references missing Studio contract section '$section'."
        }
    }
}

foreach ($archived in @($manifest.archivedSystems)) {
    $document = Resolve-RepoPath ([string]$archived.document)
    if (-not (Test-Path -LiteralPath $document -PathType Leaf)) {
        Add-ValidationError "Archived system '$($archived.id)' references missing document '$($archived.document)'."
    }
    if (-not $featureIds.ContainsKey([string]$archived.replacement)) {
        Add-ValidationError "Archived system '$($archived.id)' references unknown replacement '$($archived.replacement)'."
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Feature documentation validation FAILED ($($errors.Count) errors):" -ForegroundColor Red
    foreach ($validationError in $errors) {
        Write-Host " - $validationError" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Feature documentation validation passed." -ForegroundColor Green
Write-Host " Features: $($features.Count)"
Write-Host " Luau sources: $($sourceFiles.Count)"
Write-Host " Remotes: $((Get-UniqueStrings $serverRemotes).Count)"
Write-Host " Snapshot fields: $((Get-UniqueStrings $snapshotFields).Count)"
Write-Host " Persistent fields: $((Get-UniqueStrings $persistentFields).Count)"
Write-Host " Main data schema: $($manifest.mainDataSchemaVersion)"
