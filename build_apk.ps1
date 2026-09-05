# APK 构建脚本 - 端到端：Rust 编译 + pub cache 修补 + APK 打包
# PowerShell 版本
#
# 修复 2026-08-29 黑屏 bug：APK 缺 libbridge.so（Rust 未为 Android 编译）
# 详细：docs/bugfixes/2026-08-29_APK启动黑屏_缺失libbridge.so.md
#
# A25b 改版：按 ABI 拆分 APK（--split-per-abi）——fat APK 含全部平台
# 体积大；拆分后每个 APK 只含单 ABI，真机装对应版本即可。
# 用法：
#   .\build_apk.ps1                              # 3 ABI 全部拆分构建
#   .\build_apk.ps1 -Abis arm64-v8a              # 只构建 arm64（真机常用，最快）

param(
    [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64')]
    [string[]]$Abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64')
)

$ErrorActionPreference = 'Continue'

# 1. 设置环境变量
$env:JAVA_HOME = "D:\android\vis tudio\3\Android\openjdk\jdk-21.0.8"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
$env:ANDROID_NDK_HOME = "D:\android\ansdk\ndk\27.0.12077973"
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"

# 进入项目
Set-Location D:\android\example\legado_flutter

# ===== 前置检查 =====
Write-Host "=== [0/6] 前置检查 ===" -ForegroundColor Cyan

# 0a. cargo-ndk 是否装好
$ndk = Get-Command cargo-ndk -ErrorAction SilentlyContinue
if (-not $ndk) {
    Write-Host "  ✗ cargo-ndk 未安装" -ForegroundColor Red
    Write-Host "  请先跑：cargo install cargo-ndk" -ForegroundColor Yellow
    Write-Host "  （一次性安装，约 5-10 分钟下载 + 编译）" -ForegroundColor Yellow
    $install = Read-Host "  是否现在自动安装？(y/N)"
    if ($install -eq 'y' -or $install -eq 'Y') {
        Write-Host "  正在安装 cargo-ndk ..." -ForegroundColor Cyan
        cargo install cargo-ndk
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ✗ cargo-ndk 安装失败" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  退出" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "  ✓ cargo-ndk 已安装: $($ndk.Source)" -ForegroundColor Green
}

# 0b. NDK 路径存在
if (-not (Test-Path $env:ANDROID_NDK_HOME)) {
    Write-Host "  ✗ NDK 路径不存在: $env:ANDROID_NDK_HOME" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ NDK: $env:ANDROID_NDK_HOME" -ForegroundColor Green

# 0c. Java 路径
if (-not (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
    Write-Host "  ✗ JAVA_HOME 错误: $env:JAVA_HOME" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ JAVA: $env:JAVA_HOME" -ForegroundColor Green

# 0d. cargo-ndk 通过环境变量指定 NDK（避免命令行跨 shell 丢失）
$env:ANDROID_NDK_HOME = $env:ANDROID_NDK_HOME

# 0e. ABI 列表（来自 -Abis 参数）→ Flutter target-platform 映射
$abis = $Abis
$abiArgs = ($abis | ForEach-Object { "-t $_" }) -join ' '
$tpMap = @{
    'arm64-v8a'   = 'android-arm64'
    'armeabi-v7a' = 'android-arm'
    'x86_64'      = 'android-x64'
}
$targetPlatforms = ($abis | ForEach-Object { $tpMap[$_] }) -join ','

# ===== 步骤 1：清理 =====
Write-Host ""
Write-Host "=== [1/6] 清理 Flutter 缓存 ===" -ForegroundColor Cyan
flutter clean
Write-Host "=== [1/6] 清理上次 jniLibs（全 ABI 清空，避免 stale so 混入） ===" -ForegroundColor Cyan
foreach ($abi in @('arm64-v8a', 'armeabi-v7a', 'x86_64')) {
    $dir = "android\app\src\main\jniLibs\$abi"
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force
    }
}
foreach ($abi in $abis) {
    New-Item -ItemType Directory -Path "android\app\src\main\jniLibs\$abi" -Force | Out-Null
}

# ===== 步骤 2：pub get（用镜像） =====
Write-Host ""
Write-Host "=== [2/6] flutter pub get (走 pub.flutter-io.cn 镜像) ===" -ForegroundColor Cyan
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
flutter pub get

# ===== 步骤 3：修补 pub cache 中所有 plugin 的 compileSdk =====
Write-Host ""
Write-Host "=== [3/6] 修补 pub cache: file_picker / android_file_picker / flutter_plugin_android_lifecycle ===" -ForegroundColor Cyan
foreach ($fp in (Get-ChildItem "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\file_picker-*" -ErrorAction SilentlyContinue)) {
    $f = Join-Path $fp.FullName "android\build.gradle"
    if (Test-Path $f) {
        (Get-Content $f) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $f
    }
    # melos 拆分路径 file_picker 12.x：packages\file_picker\android\build.gradle
    $f2 = Join-Path $fp.FullName "packages\file_picker\android\build.gradle"
    if (Test-Path $f2) {
        (Get-Content $f2) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $f2
    }
}
foreach ($afp in (Get-ChildItem "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\android_file_picker-*" -ErrorAction SilentlyContinue)) {
    $f = Join-Path $afp.FullName "android\build.gradle"
    if (Test-Path $f) {
        (Get-Content $f) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $f
    }
    $f2 = Join-Path $afp.FullName "packages\file_picker_android\android\build.gradle"
    if (Test-Path $f2) {
        (Get-Content $f2) -replace 'compileSdk flutter\.compileSdkVersion', 'compileSdk 36' | Set-Content $f2
    }
}
foreach ($lcp in (Get-ChildItem "C:\Users\25644\AppData\Local\Pub\Cache\hosted\pub.dev\flutter_plugin_android_lifecycle-*" -ErrorAction SilentlyContinue)) {
    $f = Join-Path $lcp.FullName "android\build.gradle.kts"
    if (Test-Path $f) {
        (Get-Content $f) -replace 'compileSdk = flutter\.compileSdkVersion', 'compileSdk = 36' | Set-Content $f
    }
}
Write-Host "  ✓ pub cache 修补完毕" -ForegroundColor Green

# ===== 步骤 4：Rust 按所选 ABI 编译（核心修复） =====
Write-Host ""
Write-Host "=== [4/6] cargo ndk 编译 Rust bridge（$($abis -join ' / ')） ===" -ForegroundColor Cyan
Write-Host "  目标 ABI: $abiArgs" -ForegroundColor Gray
Write-Host "  NDK: $env:ANDROID_NDK_HOME" -ForegroundColor Gray
Write-Host "  jniLibs 输出: android\app\src\main\jniLibs\" -ForegroundColor Gray
Write-Host "  ⚠ 首次编译 ~25 分钟（Rust + quickjs/rusqlite/bzip2/zstd C 库 × $($abis.Count) ABI）" -ForegroundColor Yellow
Write-Host "  二次增量 ~2 分钟" -ForegroundColor Gray

# rust/crates/bridge 是 cdylib，cargo ndk 在 workspace 根调，自动找 lib name
Push-Location rust
try {
    cargo ndk $abiArgs.Split(' ') -o ../android/app/src/main/jniLibs/ build --release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ cargo ndk 失败（exit $LASTEXITCODE）" -ForegroundColor Red
        Pop-Location
        exit 1
    }
} finally {
    Pop-Location
}

# 验证所选 ABI 下都有 libbridge.so
$missingAbis = @()
foreach ($abi in $abis) {
    $so = "android\app\src\main\jniLibs\$abi\libbridge.so"
    if (-not (Test-Path $so)) {
        $missingAbis += $abi
    } else {
        $size = [math]::Round((Get-Item $so).Length / 1MB, 2)
        Write-Host "  ✓ $abi/libbridge.so ($size MB)" -ForegroundColor Green
    }
}
if ($missingAbis.Count -gt 0) {
    Write-Host "  ✗ 缺失 ABI: $($missingAbis -join ', ')" -ForegroundColor Red
    Write-Host "    cargo ndk 输出可能没复制成功；检查 rust\target\<abi>\release\libbridge.so" -ForegroundColor Yellow
    exit 1
}

# ===== 步骤 5：flutter build apk（按 ABI 拆分） =====
Write-Host ""
Write-Host "=== [5/6] flutter build apk --split-per-abi ===" -ForegroundColor Cyan
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
# --split-per-abi：每个 ABI 独立 APK（app-<abi>-release.apk）；
# --target-platform 与所选 ABI 对齐，避免编不需要的平台
flutter build apk --release --split-per-abi --target-platform $targetPlatforms

# ===== 步骤 6：验证（逐 ABI APK + 单 libbridge.so） =====
Write-Host ""
Write-Host "=== [6/6] 验证分 ABI APK ===" -ForegroundColor Cyan
Add-Type -A 'System.IO.Compression.FileSystem'
$failed = $false
foreach ($abi in $abis) {
    $apk = "build\app\outputs\flutter-apk\app-$abi-release.apk"
    if (-not (Test-Path $apk)) {
        Write-Host "  ✗ 未生成: $apk" -ForegroundColor Red
        $failed = $true
        continue
    }
    $apkSize = [math]::Round((Get-Item $apk).Length / 1MB, 2)
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk).Path)
    try {
        $bridgeEntries = @($zip.Entries | Where-Object { $_.FullName -eq "lib/$abi/libbridge.so" })
        if ($bridgeEntries.Count -eq 1) {
            Write-Host "  ✓ app-$abi-release.apk ($apkSize MB, libbridge.so ×1)" -ForegroundColor Green
        } else {
            Write-Host "  ✗ app-$abi-release.apk 内 lib/$abi/libbridge.so 数量异常：$($bridgeEntries.Count)" -ForegroundColor Red
            $failed = $true
        }
    } finally {
        $zip.Dispose()
    }
}
if ($failed) { exit 1 }

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "  分 ABI APK（真机装对应版本；现代手机一般 arm64-v8a）：" -ForegroundColor Green
foreach ($abi in $abis) {
    Write-Host "    build\app\outputs\flutter-apk\app-$abi-release.apk" -ForegroundColor Green
}
Write-Host "  下一步：adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" -ForegroundColor Cyan
