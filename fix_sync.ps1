# ============================================
# Flutter-Rust 同步修复脚本 (PowerShell)
# 用于解决 Content hash 不匹配问题
# ============================================

# 修复 PATH：添加 Git usr\bin 目录（用于 rquickjs-sys 的 patch 命令）
$gitUsrBin = "C:\Program Files\Git\usr\bin"
if (Test-Path $gitUsrBin) {
    $env:Path += ";$gitUsrBin"
    Write-Host "✓ 已添加 patch 到 PATH" -ForegroundColor Green
}

# 修复 PROGRAMFILES(X86) 环境变量（Flutter Windows 构建需要）
if (-not [Environment]::GetEnvironmentVariable("PROGRAMFILES(X86)", "Process")) {
    [Environment]::SetEnvironmentVariable("PROGRAMFILES(X86)", "C:\Program Files (x86)", "Process")
    Write-Host "✓ 已设置 PROGRAMFILES(X86) 环境变量" -ForegroundColor Green
}

# 初始化 Visual Studio 编译环境（flutter build windows 需要 MSVC）
# 使用 vcvars64.bat 完整初始化（包含正确的 LIB/INCLUDE 路径）
$vsWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$vcVars = $null
$vsCMakeBin = $null
$msvcBinPath = $null
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if ($vsPath) {
        $vcVars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
        # VS 自带 CMake（必须优先于 flutter 捆绑的旧 CMake，否则 VS2026
        # 生成器不被识别 → "No CMAKE_CXX_COMPILER could be found"）
        $vsCMakeBin = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
        # 最新版 MSVC 编译器 bin 目录
        $msvcDir = Get-ChildItem "$vsPath\VC\Tools\MSVC\*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($msvcDir) { $msvcBinPath = Join-Path $msvcDir.FullName "bin\Hostx64\x64" }

        if (Test-Path $vcVars) {
            Push-Location $env:TEMP
            cmd /c "`"$vcVars`" >nul 2>&1 && set" | ForEach-Object {
                if ($_ -match "^([^=]+)=(.*)$") {
                    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
                }
            }
            Pop-Location
            Write-Host "✓ 已初始化 Visual Studio 编译环境" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Flutter-Rust 同步修复脚本" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. 关闭相关进程
Write-Host "[1/8] 关闭相关进程..." -ForegroundColor Yellow
Get-Process | Where-Object {$_.Name -like "*legado*"} | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process | Where-Object {$_.Name -like "*flutter*"} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# 2. 清理 Flutter 缓存
Write-Host "[2/8] 清理 Flutter 缓存..." -ForegroundColor Yellow
flutter clean
Start-Sleep -Seconds 1

# 3. 清理 Rust 缓存
Write-Host "[3/8] 清理 Rust 缓存..." -ForegroundColor Yellow
Push-Location rust
cargo clean
Pop-Location
Start-Sleep -Seconds 1

# 4. 获取依赖
Write-Host "[4/8] 获取依赖..." -ForegroundColor Yellow
flutter pub get
Start-Sleep -Seconds 1

# 5. 重新生成 FFI 绑定
Write-Host "[5/7] 重新生成 FFI 绑定..." -ForegroundColor Yellow
flutter_rust_bridge_codegen generate
Start-Sleep -Seconds 2

# 6. 编译 Rust 代码
Write-Host "[6/7] 编译 Rust 代码..." -ForegroundColor Yellow
Push-Location rust
cargo build --release
Pop-Location

# 7. 复制 DLL 到正确位置
Write-Host "[7/7] 复制 DLL 文件..." -ForegroundColor Yellow
$sourceDll = "rust\target\release\bridge.dll"
$targetDll = "rust\crates\bridge\target\release\bridge.dll"
$targetDir = Split-Path -Parent $targetDll
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}
Copy-Item -Path $sourceDll -Destination $targetDll -Force
Write-Host "  已复制: $sourceDll -> $targetDll" -ForegroundColor Gray

# 8. 构建应用
# 三个关键点（针对 VS2026 装在含空格路径的本机环境）：
# ① VS 自带 CMake 必须在 PATH 最前——flutter 捆绑的旧 CMake 不认识
#    "Visual Studio 18 2026" 生成器，会报 "No CMAKE_CXX_COMPILER"
# ② TrackFileAccess=false——FileTracker 在本机环境会崩溃（路径形式
#    不合法 → MSB4018 → 编译器测试失败 → 同样报 No CMAKE_CXX_COMPILER）
# ③ 不走 cmd 链——纯 PowerShell 修改 $env:Path，无引号/%PATH% 展开陷阱
Write-Host "[8/8] 构建 Windows 应用..." -ForegroundColor Yellow
if ($vsCMakeBin -and (Test-Path $vsCMakeBin)) {
    if (-not ($env:Path -like "*$vsCMakeBin*")) {
        $env:Path = "$vsCMakeBin;$env:Path"
    }
    Write-Host "  ✓ VS CMake 已置顶 PATH" -ForegroundColor Gray
}
$env:TrackFileAccess = "false"

flutter build windows --debug
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "✗ Windows 构建失败（上方错误信息）" -ForegroundColor Red
    Read-Host "按 Enter 退出"
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  修复完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "运行应用:" -ForegroundColor Cyan
Write-Host "  flutter run -d windows"
Write-Host ""
Write-Host "或直接运行:" -ForegroundColor Cyan
Write-Host "  build\windows\x64\runner\Debug\legado_flutter.exe"
Write-Host ""

Read-Host "按 Enter 退出"
