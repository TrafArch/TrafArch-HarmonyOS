Set-StrictMode -Version Latest

function Read-TrafArchHarmonyVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $text = [IO.File]::ReadAllText($resolved)
    $nameMatch = [regex]::Match($text, '"versionName"\s*:\s*"([^"]*)"')
    $codeMatch = [regex]::Match($text, '"versionCode"\s*:\s*([0-9]+)')
    if (!$nameMatch.Success -or [string]::IsNullOrWhiteSpace($nameMatch.Groups[1].Value)) {
        throw "App versionName is missing from $resolved."
    }
    if (!$codeMatch.Success) {
        throw "App versionCode is missing from $resolved."
    }

    $versionCode = [long]0
    if (![long]::TryParse($codeMatch.Groups[1].Value, [ref]$versionCode) -or
        $versionCode -lt 1 -or $versionCode -gt [int]::MaxValue) {
        throw "App versionCode must be between 1 and $([int]::MaxValue)."
    }
    return [pscustomobject]@{
        Path = $resolved
        Name = $nameMatch.Groups[1].Value
        Code = $versionCode
    }
}

function Write-TrafArchHarmonyBuildCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$VersionCode
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $text = [IO.File]::ReadAllText($resolved)
    $codeMatch = [regex]::Match($text, '("versionCode"\s*:\s*)([0-9]+)')
    if (!$codeMatch.Success) {
        throw "App versionCode is missing from $resolved."
    }
    $codeGroup = $codeMatch.Groups[2]
    $updated = $text.Substring(0, $codeGroup.Index) +
        $VersionCode.ToString([Globalization.CultureInfo]::InvariantCulture) +
        $text.Substring($codeGroup.Index + $codeGroup.Length)

    $bytes = [IO.File]::ReadAllBytes($resolved)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $staging = Join-Path (Split-Path -Parent $resolved) (
        '.version-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $staging + '.bak'
    try {
        [IO.File]::WriteAllText($staging, $updated, [Text.UTF8Encoding]::new($hasBom))
        [IO.File]::Replace($staging, $resolved, $backup)
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Force
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

function Step-TrafArchHarmonyBuildCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$ExpectedCode
    )

    $current = Read-TrafArchHarmonyVersion -Path $Path
    if ($current.Code -ne $ExpectedCode) {
        throw "Build version changed during the build (expected $ExpectedCode, found $($current.Code))."
    }
    if ($current.Code -ge [int]::MaxValue) {
        throw "App versionCode cannot advance beyond $([int]::MaxValue)."
    }
    $next = $current.Code + 1
    Write-TrafArchHarmonyBuildCode -Path $Path -VersionCode $next
    return $next
}

function Write-TrafArchHarmonyProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$VersionName,
        [Parameter(Mandatory = $true)][long]$VersionCode,
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        [Parameter(Mandatory = $true)][string]$FlutterRoot
    )

    if ($VersionName.IndexOfAny([char[]]"`r`n=") -ge 0) {
        throw 'App versionName cannot contain a newline or equals sign.'
    }
    $lines = @(
        ('hwsdk.dir=' + $SdkRoot.Replace('\', '/')),
        ('flutter.sdk=' + $FlutterRoot.Replace('\', '/')),
        ('flutter.versionName=' + $VersionName),
        ('flutter.versionCode=' + $VersionCode.ToString(
            [Globalization.CultureInfo]::InvariantCulture))
    )
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
}
