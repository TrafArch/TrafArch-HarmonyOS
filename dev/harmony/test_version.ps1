$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'version.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testRoot = Join-Path $repoRoot 'build/harmony/version-test'
[void][IO.Directory]::CreateDirectory($testRoot)
$appPath = Join-Path $testRoot 'app.json5'
$propertiesPath = Join-Path $testRoot '.flutter-harmony.properties'
try {
    $source = @"
{
  "app": {
    "bundleName": "com.kajolno.TrafArch",
    "versionCode": 2217,
    "versionName": "2.0.0"
  }
}
"@
    [IO.File]::WriteAllText($appPath, $source, [Text.UTF8Encoding]::new($false))

    $version = Read-TrafArchHarmonyVersion -Path $appPath
    if ($version.Name -ne '2.0.0' -or $version.Code -ne 2217) {
        throw 'Version parsing returned unexpected values.'
    }

    $next = Step-TrafArchHarmonyBuildCode -Path $appPath -ExpectedCode 2217
    if ($next -ne 2218) {
        throw "Expected the next build code to be 2218, got $next."
    }
    $advanced = Read-TrafArchHarmonyVersion -Path $appPath
    if ($advanced.Name -ne '2.0.0' -or $advanced.Code -ne 2218) {
        throw 'Version increment changed the version name or used the wrong code.'
    }
    if ([IO.File]::ReadAllText($appPath).Contains('"versionCode": 2217')) {
        throw 'The original version code remains after incrementing.'
    }

    Write-TrafArchHarmonyProperties -Path $propertiesPath -VersionName $advanced.Name `
        -VersionCode $advanced.Code -SdkRoot 'C:\sdk' -FlutterRoot 'D:\flutter'
    $properties = [IO.File]::ReadAllLines($propertiesPath)
    if ($properties[-1] -ne 'flutter.versionCode=2218' -or
        $properties[-2] -ne 'flutter.versionName=2.0.0') {
        throw 'Flutter version properties were not updated for the next build.'
    }

    $rejected = $false
    try {
        [void](Step-TrafArchHarmonyBuildCode -Path $appPath -ExpectedCode 2217)
    } catch {
        $rejected = $_.Exception.Message.Contains('changed during the build')
    }
    if (!$rejected) {
        throw 'A stale build code expectation was not rejected.'
    }

    Write-Host 'Harmony build number checks passed.'
} finally {
    if (Test-Path -LiteralPath $appPath) {
        Remove-Item -LiteralPath $appPath -Force
    }
    if (Test-Path -LiteralPath $propertiesPath) {
        Remove-Item -LiteralPath $propertiesPath -Force
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Force
    }
}
