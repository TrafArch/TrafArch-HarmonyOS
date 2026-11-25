param(
    [Parameter(Mandatory = $true)][string]$FlutterRoot,
    [string]$DevEcoRoot = 'C:\Program Files\Huawei\DevEco Studio',
    [string]$SqliteArchive,
    [switch]$PrepareOnly,
    [ValidateSet('debug', 'release')][string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$FlutterRoot = (Resolve-Path -LiteralPath $FlutterRoot).Path
. (Join-Path $PSScriptRoot 'version.ps1')
$revision = 'c5880c605eb77e82d5585cef24d7b4228d84a84d'
$actualRevision = git -C $FlutterRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualRevision -ne $revision) {
    throw "Use the Flutter OHOS SDK at $revision."
}

$sdk = Join-Path $DevEcoRoot 'sdk'
$null = Resolve-Path -LiteralPath (Join-Path $sdk 'default/openharmony/native/sysroot')
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$ohpm = Join-Path $DevEcoRoot 'tools/ohpm/bin/ohpm.bat'
$hvigor = Join-Path $DevEcoRoot 'tools/hvigor/bin/hvigorw.bat'
$npm = Join-Path $DevEcoRoot 'tools/node/npm.cmd'
$env:DEVECO_SDK_HOME = $sdk
$env:JAVA_HOME = Join-Path $DevEcoRoot 'jbr'
$env:FLUTTER_OHOS_STORAGE_BASE_URL = 'https://repo.huaweicloud.com/flutter-ohos'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:PATH = @(
    (Join-Path $DevEcoRoot 'jbr/bin'),
    (Join-Path $DevEcoRoot 'tools/ohpm/bin'),
    (Join-Path $DevEcoRoot 'tools/node'),
    (Join-Path $DevEcoRoot 'tools/hvigor/bin'),
    (Join-Path $sdk 'default/openharmony/toolchains'),
    $env:PATH
) -join ';'

$outputDir = Join-Path $repo 'build/harmony'
$toolchain = Join-Path $outputDir 'toolchain'
[void][IO.Directory]::CreateDirectory($toolchain)
$buildLock = $null
$pushedLocation = $false
try {
    try {
        $buildLock = [IO.File]::Open(
            (Join-Path $outputDir '.build.lock'),
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch [IO.IOException] {
        throw 'Another Harmony build is already running for this project.'
    }
    $archive = if ($SqliteArchive) { (Resolve-Path -LiteralPath $SqliteArchive).Path } else { Join-Path $toolchain 'sqlite-amalgamation-3540000.zip' }
    if (!(Test-Path -LiteralPath $archive)) {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://sqlite.org/2026/sqlite-amalgamation-3540000.zip' -OutFile $archive -TimeoutSec 60
    }
    $expected = '68E913B0FE8EC6B4E5F391C594A28872884E80D6CD042A1E50C957BE46B5AA4D'
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $expected) {
        throw 'SQLite source archive SHA-256 does not match.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $toolchain -Force

    Push-Location -LiteralPath $repo
    $pushedLocation = $true
    & $flutter precache --ohos
    if ($LASTEXITCODE -ne 0) { throw 'Flutter OHOS engine preparation failed.' }
    & $flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    $configPath = Join-Path $repo '.dart_tool/package_config.json'
    $packages = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $sqlite = $packages.packages | Where-Object name -eq 'sqlite3'
    $packageRoot = ([Uri]$sqlite.rootUri).LocalPath
    if ((Split-Path -Leaf $packageRoot) -ne 'sqlite3-3.9.1') {
        throw 'Revalidate the Windows cross-compile workaround before upgrading sqlite3.'
    }
    $patched = Join-Path $toolchain 'sqlite3-3.9.1'
    [void][IO.Directory]::CreateDirectory($patched)
    Get-ChildItem -LiteralPath $packageRoot -Force | Copy-Item -Destination $patched -Recurse -Force
    $hook = Join-Path $patched 'hook/build.dart'
    $hookSource = [IO.File]::ReadAllText($hook)
    $oldPath = "input.outputDirectory.resolve('sqlite.map').path"
    $oldDispatch = 'final sqlite = SqliteBinary.forBuild(input);'
    if (!$hookSource.Contains($oldPath) -or !$hookSource.Contains($oldDispatch)) { throw 'SQLite hook logic changed.' }
    $dispatch = @'
final code = input.config.code;
    final compiler = code.cCompiler?.compiler;
    final ohos = code.targetOS == OS.linux && compiler != null &&
        compiler.path.contains('/openharmony/native/llvm/bin/');
    final sqlite = ohos
        ? CompileSqlite(
            sourceFiles: [(await Isolate.resolvePackageUri(Uri.parse('package:sqlite3/sqlite3.dart')))!
                .resolve('../sqlite-amalgamation-3540000/sqlite3.c').toFilePath()],
            defines: CompilerDefines.defaults(false),
            additionalIncludes: [],
            additionalFlags: [
              '--target=${switch (code.targetArchitecture) {
                Architecture.arm64 => 'aarch64-linux-ohos',
                Architecture.x64 => 'x86_64-linux-ohos',
                _ => throw UnsupportedError('Unsupported HarmonyOS ABI: ${code.targetArchitecture}'),
              }}',
              '--sysroot=${compiler.resolve('../../sysroot').toFilePath()}',
            ],
            additionalLibraryDirectories: [],
            additionalLibraries: [],
          )
        : SqliteBinary.forBuild(input);
'@
    $sqliteSource = Join-Path $patched 'sqlite-amalgamation-3540000'
    [void][IO.Directory]::CreateDirectory($sqliteSource)
    foreach ($name in @('sqlite3.c','sqlite3.h','sqlite3ext.h')) {
        Copy-Item -LiteralPath (Join-Path $toolchain "sqlite-amalgamation-3540000/$name") -Destination $sqliteSource -Force
    }
    $hookSource = $hookSource.Replace("import 'dart:io';", "import 'dart:io';`nimport 'dart:isolate';")
    [IO.File]::WriteAllText($hook, $hookSource.Replace($oldDispatch, $dispatch).Replace($oldPath, "input.outputDirectory.resolve('sqlite.map').toFilePath()"))
    $sqlite.rootUri = ([Uri]($patched + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri
    [IO.File]::WriteAllText($configPath, ($packages | ConvertTo-Json -Depth 12))

    $pluginSource = Join-Path $FlutterRoot 'packages/flutter_tools/hvigor'
    $pluginDir = Join-Path $toolchain 'flutter-hvigor-plugin'
    [void][IO.Directory]::CreateDirectory($pluginDir)
    foreach ($item in @('index.ts','package.json','src')) {
        Copy-Item -LiteralPath (Join-Path $pluginSource $item) -Destination $pluginDir -Recurse -Force
    }
    $pluginManifestPath = Join-Path $pluginDir 'package.json'
    $pluginManifest = Get-Content -Raw -LiteralPath $pluginManifestPath | ConvertFrom-Json
    $pluginManifest.PSObject.Properties.Remove('devDependencies')
    [IO.File]::WriteAllText($pluginManifestPath, ($pluginManifest | ConvertTo-Json -Depth 4))
    $plugin = Join-Path $pluginDir 'src/plugin/flutter-hvigor-plugin.ts'
    $originalPlugin = [IO.File]::ReadAllText($plugin)
    $oldProperties = "path.join(flutterProjectPath, ohosDir, 'local.properties')"
    if (!$originalPlugin.Contains($oldProperties)) { throw 'Flutter Hvigor project layout changed.' }
    $rootPlugin = $originalPlugin.Replace($oldProperties, "path.join(flutterProjectPath, '.flutter-harmony.properties')")
    $archArgument = 'flutterArgs.push(`-dOhosArchs=${targetPlatforms.join('' '')}`)'
    if (!$rootPlugin.Contains($archArgument)) { throw 'Flutter Hvigor ABI argument changed.' }
    $rootPlugin = $rootPlugin.Replace($archArgument, 'flutterArgs.push(`"-dOhosArchs=${targetPlatforms.join('' '')}"`)')
    $rootPlugin = $rootPlugin.Replace('const sdkPath = properties[''flutter.sdk'']', 'const sdkPath = properties[''flutter.sdk'']; process.env.DEVECO_SDK_HOME = properties[''hwsdk.dir'']')
    [IO.File]::WriteAllText($plugin, $rootPlugin)
    $manifest = @{ private = $true; dependencies = @{ 'flutter-hvigor-plugin' = 'file:./build/harmony/toolchain/flutter-hvigor-plugin' } }
    [IO.File]::WriteAllText((Join-Path $repo 'package.json'), ($manifest | ConvertTo-Json -Depth 3))
    & $npm install --offline --no-audit --no-fund --ignore-scripts
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the local Flutter Hvigor plugin.' }

    $appScopePath = Join-Path $repo 'AppScope/app.json5'
    $appVersion = Read-TrafArchHarmonyVersion -Path $appScopePath
    Write-TrafArchHarmonyProperties -Path (Join-Path $repo '.flutter-harmony.properties') `
        -VersionName $appVersion.Name -VersionCode $appVersion.Code `
        -SdkRoot $sdk -FlutterRoot $FlutterRoot
    $harDir = Join-Path $repo 'entry/.flutter-engine'
    [void][IO.Directory]::CreateDirectory($harDir)
    foreach ($har in @('flutter_embedding_debug.har','arm64_v8a_debug.har')) {
        Copy-Item -LiteralPath (Join-Path $FlutterRoot "bin/cache/artifacts/engine/ohos-arm64/$har") -Destination $harDir -Force
    }
    Copy-Item -LiteralPath (Join-Path $FlutterRoot 'bin/cache/artifacts/engine/ohos-x64/x86_64_debug.har') -Destination $harDir -Force
    & $ohpm install --all --registry 'https://ohpm.openharmony.cn/ohpm/' --strict_ssl true
    if ($LASTEXITCODE -ne 0) { throw 'Root OHPM installation failed.' }
    Write-Host "DevEco project: $repo"
    if ($PrepareOnly) { return }

    & $hvigor assembleHap -p product=default -p "buildMode=$Mode" --no-daemon
    if ($LASTEXITCODE -ne 0) { throw 'Flutter OHOS build failed.' }
    $hap = Join-Path $repo 'entry/build/default/outputs/default/entry-default-unsigned.hap'
    if (!(Test-Path -LiteralPath $hap)) { throw 'The unsigned HAP was not found.' }
    $requiredAbis = [ordered]@{ 'arm64-v8a' = 183; 'x86_64' = 62 }
    $readelf = Join-Path $sdk 'default/openharmony/native/llvm/bin/llvm-readelf.exe'
    $package = [IO.Compression.ZipFile]::OpenRead($hap)
    try {
        foreach ($abi in $requiredAbis.Keys) {
            $names = @('libflutter.so', 'libsqlite3.so')
            if ($Mode -eq 'release') { $names += 'libapp.so' }
            foreach ($name in $names) {
                $entry = $package.GetEntry("libs/$abi/$name")
                if (!$entry) { throw "Missing HAP library: $abi/$name" }
                $reader = [IO.BinaryReader]::new($entry.Open())
                try { $header = $reader.ReadBytes(20) } finally { $reader.Dispose() }
                if ($header.Length -ne 20 -or [BitConverter]::ToUInt32($header, 0) -ne 0x464c457f -or $header[4] -ne 2 -or
                    $header[5] -ne 1 -or [BitConverter]::ToUInt16($header, 18) -ne $requiredAbis[$abi]) {
                    throw "Wrong ELF architecture: $abi/$name"
                }
                if ($name -eq 'libsqlite3.so') {
                    $library = Join-Path $toolchain "hap-check-$abi-libsqlite3.so"
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $library, $true)
                    $elf = & $readelf -d -V $library
                    if ($LASTEXITCODE -ne 0 -or ($elf -join "`n") -match 'libc\.so\.6|GLIBC_') {
                        throw "The packaged SQLite library is not an OHOS binary: $abi"
                    }
                }
            }
        }
        Write-Host 'Verified native libraries for arm64-v8a and x86_64.'
        foreach ($path in @('assets/data/TrafArch_Database_TU.sqlite', 'assets/data/TrafArch_Database_CU.sqlite',
            'assets/data/reference_manifest.json', 'assets/data/card_provider_registry.json',
            'assets/Line_Icon/icons.json', 'third_party/railmapgen_palette/tu_colors.json',
            'assets/suica/suica_stationcode.db', 'assets/suica/manifest.json')) {
            $entry = $package.GetEntry("resources/rawfile/flutter_assets/$path")
            if (!$entry) { throw "Missing bundled asset: $path" }
            $stream = $entry.Open()
            try {
                $bundledHash = (Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash
            } finally {
                $stream.Dispose()
            }
            if ($bundledHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repo $path)).Hash) {
                throw "Bundled asset changed: $path"
            }
        }
    } finally {
        $package.Dispose()
    }
    $output = Join-Path $outputDir "TrafArch-ohos-arm64-x64-$Mode-unsigned.hap"
    [IO.File]::Copy($hap, $output, $true)
    Write-Host "Unsigned HAP: $output"
    $signed = Join-Path $repo 'entry/build/default/outputs/default/entry-default-signed.hap'
    $product = (Get-Content -Raw -LiteralPath (Join-Path $repo 'build-profile.json5') | ConvertFrom-Json).app.products |
        Where-Object name -eq 'default'
    if ($product.signingConfig -and (Test-Path -LiteralPath $signed)) {
        Write-Host "Signed HAP for installation: $signed"
    }
    $nextVersionCode = Step-TrafArchHarmonyBuildCode `
        -Path $appScopePath -ExpectedCode $appVersion.Code
    Write-TrafArchHarmonyProperties -Path (Join-Path $repo '.flutter-harmony.properties') `
        -VersionName $appVersion.Name -VersionCode $nextVersionCode `
        -SdkRoot $sdk -FlutterRoot $FlutterRoot
    Write-Host "Built HAP version: $($appVersion.Name) ($($appVersion.Code)); next build: $nextVersionCode."

} finally {
    if ($pushedLocation) {
        Pop-Location
    }
    if ($null -ne $buildLock) {
        $buildLock.Dispose()
    }
}
