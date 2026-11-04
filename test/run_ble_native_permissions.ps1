param([switch]$CompileAndroid)

$ErrorActionPreference = 'Stop'
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cacheRoot = Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1'
$compilerModules = @(
    'org.jetbrains.kotlin/kotlin-compiler-embeddable/2.4.0',
    'org.jetbrains.kotlin/kotlin-build-tools-api/2.4.0',
    'org.jetbrains.kotlin/kotlin-stdlib/2.4.0',
    'org.jetbrains.kotlin/kotlin-script-runtime/2.4.0',
    'org.jetbrains.kotlin/kotlin-daemon-embeddable/2.4.0',
    'org.jetbrains.kotlin/kotlin-reflect/1.6.10',
    'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
    'org.jetbrains/annotations/23.0.0'
)
$compilerJars = @($compilerModules | ForEach-Object {
    Get-ChildItem -LiteralPath (Join-Path $cacheRoot $_) -Recurse -Filter '*.jar' |
        Select-Object -ExpandProperty FullName
})
$stdlibJar = @($compilerJars | Where-Object { $_ -match 'kotlin-stdlib-2.4.0.jar$' })[0]
$checkOutput = Join-Path $appRoot 'build/ble_permission_checks'
New-Item -ItemType Directory -Force -Path $checkOutput | Out-Null
$checkJar = Join-Path $checkOutput 'permission-tests.jar'
$sourceRoot = Join-Path $appRoot 'android/app/src/main/kotlin/com/mymg/app'
$testRoot = Join-Path $appRoot 'android/app/src/test/kotlin/com/mymg/app'
& java -cp ($compilerJars -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
    -no-stdlib -no-reflect -classpath $stdlibJar -jvm-target 17 `
    -d $checkJar (Join-Path $sourceRoot 'BlePermissionRequests.kt') `
    (Join-Path $testRoot 'BlePermissionRequestsTest.kt')
if ($LASTEXITCODE -ne 0) { throw 'Native permission regression compilation failed' }
& java -cp ($checkJar + ';' + $stdlibJar) com.mymg.app.BlePermissionRequestsTestKt
if ($LASTEXITCODE -ne 0) { throw 'Native permission regressions failed' }

if ($CompileAndroid) {
    # Reuse real cached AndroidX API jars and the previous app compilation for
    # unchanged local classes. Outputs go to a separate verification jar.
    $transforms = Join-Path $env:USERPROFILE '.gradle/caches/9.3.1/transforms'
    $androidxJars = @(rg --files $transforms -g '*api.jar' |
        Where-Object { [IO.Path]::GetFileName($_) -match '^(fragment|activity|lifecycle|savedstate|core|annotation|collection|loader|versionedparcelable|customview|viewpager|concurrent|tracing|navigationevent)-' } |
        Sort-Object { [IO.Path]::GetFileName($_) } -Descending |
        Group-Object { [IO.Path]::GetFileName($_) -replace '-\d.*$', '' } |
        ForEach-Object {
            $_.Group | Sort-Object {
                if ([IO.Path]::GetFileName($_) -match '-(\d+\.\d+\.\d+)') {
                    [version]$Matches[1]
                } else { [version]'0.0.0' }
            } -Descending | Select-Object -First 1
        })
    $plainAndroidxJars = @(
        'androidx.lifecycle/lifecycle-common-jvm/2.11.0',
        'androidx.annotation/annotation-jvm/1.11.0',
        'androidx.arch.core/core-common/2.2.0'
    ) | ForEach-Object {
        Get-ChildItem -LiteralPath (Join-Path $cacheRoot $_) -Recurse -Filter '*.jar' |
            Select-Object -ExpandProperty FullName
    }
    $compileClasspath = @(
        $stdlibJar,
        (Join-Path $env:LOCALAPPDATA 'Android/Sdk/platforms/android-36/android.jar'),
        'C:/src/flutter/bin/cache/artifacts/engine/android-arm64-release/flutter.jar',
        (Join-Path $appRoot 'build/app/tmp/kotlin-classes/release'),
        (Join-Path $appRoot 'build/app/intermediates/compile_r_class_jar/release/generateReleaseRFile/R.jar')
    ) + $androidxJars + $plainAndroidxJars
    $androidSources = @(
        'BlePermissionRequests.kt', 'BlePermissionController.kt',
        'MymgAppInfo.kt', 'MainActivity.kt', 'QuickControlActivity.kt',
        'MymgBleScanner.kt'
    ) | ForEach-Object { Join-Path $sourceRoot $_ }
    & java -cp ($compilerJars -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
        -no-stdlib -no-reflect -classpath ($compileClasspath -join ';') -jvm-target 17 `
        -d (Join-Path $checkOutput 'android-permission-check.jar') @androidSources
    if ($LASTEXITCODE -ne 0) { throw 'Android source compilation failed' }
    Write-Output 'Six Android permission/app-info sources compiled against real SDK dependencies'
}
