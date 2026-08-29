# APK 构建脚本 - 解决 pub.dev 镜像 + compileSdk=36 + pub cache 修补
# PowerShell 版本

$ErrorActionPreference = 'Continue'

# 1. 设置环境变量
$env:JAVA_HOME = "D:\android\vis tudio\3\Android\openjdk\jdk-21.0.8"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
$env:ANDROID_NDK_HOME = "D:\android\ansdk\ndk\27.0.12077973"
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"

# 进入项目
Set-Location D:\android\example\legado_flutter

Write-Host "=== [1/5] 修补 pub cache: file_picker-11.0.3 / 12.1.2 / android_file_picker-1.0.3 / flutter_plugin_android_lifecycle-2.0.34-35 ===" -ForegroundColor Cyan

# file_picker 11.0.3
$fp11 = "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\file_picker-11.0.3\android\build.gradle"
if (Test-Path $fp11) {
    (Get-Content $fp11) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $fp11
    Write-Host "  patched: file_picker-11.0.3" -ForegroundColor Green
}

# file_picker 12.1.2 (melos 拆分后 build.gradle 路径变了)
$fp12Candidates = @(
    "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\file_picker-12.1.2\packages\file_picker\android\build.gradle",
    "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\file_picker-12.1.2\android\build.gradle"
)
foreach ($fp12 in $fp12Candidates) {
    if (Test-Path $fp12) {
        (Get-Content $fp12) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $fp12
        Write-Host "  patched: $fp12" -ForegroundColor Green
    }
}

# android_file_picker 1.0.3 (新独立包)
$afp13Candidates = @(
    "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\android_file_picker-1.0.3\packages\file_picker_android\android\build.gradle",
    "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\android_file_picker-1.0.3\android\build.gradle"
)
foreach ($afp13 in $afp13Candidates) {
    if (Test-Path $afp13) {
        (Get-Content $afp13) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $afp13
        Write-Host "  patched: $afp13" -ForegroundColor Green
    }
}

# flutter_plugin_android_lifecycle 2.0.34, 2.0.35
foreach ($ver in @('2.0.34', '2.0.35')) {
    $lcp = "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\flutter_plugin_android_lifecycle-$ver\android\build.gradle.kts"
    if (Test-Path $lcp) {
        (Get-Content $lcp) -replace 'compileSdk = flutter\.compileSdkVersion', 'compileSdk = 36' | Set-Content $lcp
        Write-Host "  patched: flutter_plugin_android_lifecycle-$ver" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== [2/5] flutter clean ===" -ForegroundColor Cyan
flutter clean

Write-Host ""
Write-Host "=== [3/5] flutter pub get (走 pub.flutter-io.cn 镜像) ===" -ForegroundColor Cyan
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
flutter pub get

Write-Host ""
Write-Host "=== [4/5] 重新修补可能刚被 pub get 拉下的新版本 ===" -ForegroundColor Cyan
# pub get 可能拉下 12.1.2 + 1.0.3 + 2.0.35 等新版，重新打补丁
foreach ($fp12 in $fp12Candidates) {
    if (Test-Path $fp12) {
        (Get-Content $fp12) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $fp12
    }
}
foreach ($afp13 in $afp13Candidates) {
    if (Test-Path $afp13) {
        (Get-Content $afp13) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $afp13
    }
}
# 重新扫所有 lifecycle 版本
Get-ChildItem "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\flutter_plugin_android_lifecycle-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $lcp = Join-Path $_.FullName "android\build.gradle.kts"
    if (Test-Path $lcp) {
        (Get-Content $lcp) -replace 'compileSdk = flutter\.compileSdkVersion', 'compileSdk = 36' | Set-Content $lcp
    }
}
Get-ChildItem "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\file_picker-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $fp = Join-Path $_.FullName "android\build.gradle"
    if (Test-Path $fp) {
        (Get-Content $fp) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $fp
    }
}
Get-ChildItem "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\android_file_picker-*" -ErrorAction SilentlyContinue | ForEach-Object {
    $afp = Join-Path $_.FullName "android\build.gradle"
    if (Test-Path $afp) {
        (Get-Content $afp) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $afp
    }
}
Write-Host "  all pub cache builds patched to compileSdk=36" -ForegroundColor Green

Write-Host ""
Write-Host "=== [5/5] flutter build apk ===" -ForegroundColor Cyan
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
flutter build apk

Write-Host ""
Write-Host "=== done ===" -ForegroundColor Green
