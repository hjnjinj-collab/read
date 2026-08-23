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
Write-Host "[8/8] 构建 Windows 应用..." -ForegroundColor Yellow
flutter build windows --debug

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
