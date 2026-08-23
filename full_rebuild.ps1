# ============================================
# 完全清理和重新构建脚本
# 用于解决 Content hash 不匹配问题
# ============================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  完全清理和重新构建" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. 关闭所有相关进程
Write-Host "[1/8] 关闭所有相关进程..." -ForegroundColor Yellow
Get-Process | Where-Object {$_.Name -like "*legado*"} | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process | Where-Object {$_.Name -like "*flutter*"} | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process | Where-Object {$_.Name -like "*dart*"} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Write-Host "  ✓ 进程已关闭" -ForegroundColor Green

# 2. 清理 Flutter 构建目录
Write-Host "[2/8] 清理 Flutter 构建目录..." -ForegroundColor Yellow
Remove-Item -Path "build" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path ".dart_tool" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  ✓ Flutter 构建目录已清理" -ForegroundColor Green

# 3. 清理 Rust target 目录
Write-Host "[3/8] 清理 Rust target 目录..." -ForegroundColor Yellow
Push-Location rust
Remove-Item -Path "target" -Recurse -Force -ErrorAction SilentlyContinue
Pop-Location
Write-Host "  ✓ Rust target 目录已清理" -ForegroundColor Green

# 4. 删除旧的生成文件
Write-Host "[4/8] 删除旧的生成文件..." -ForegroundColor Yellow
Remove-Item -Path "lib/core/ffi/rust_bridge.dart" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "rust/crates/bridge/src/frb_generated.rs" -Force -ErrorAction SilentlyContinue
Write-Host "  ✓ 旧的生成文件已删除" -ForegroundColor Green

# 5. 重新编译 Rust（Release 模式）
Write-Host "[5/8] 重新编译 Rust..." -ForegroundColor Yellow
Push-Location rust
cargo build --release --package bridge
Pop-Location
Write-Host "  ✓ Rust 编译完成" -ForegroundColor Green

# 6. 获取 Flutter 依赖
Write-Host "[6/8] 获取 Flutter 依赖..." -ForegroundColor Yellow
flutter pub get
Write-Host "  ✓ 依赖获取完成" -ForegroundColor Green

# 7. 重新生成 FFI 绑定
Write-Host "[7/8] 重新生成 FFI 绑定..." -ForegroundColor Yellow
flutter_rust_bridge_codegen generate
Write-Host "  ✓ FFI 绑定生成完成" -ForegroundColor Green

# 8. 重新构建 Flutter 应用
Write-Host "[8/8] 重新构建 Flutter 应用..." -ForegroundColor Yellow
flutter build windows --debug
Write-Host "  ✓ Flutter 构建完成" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  完全清理和重新构建完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "现在可以运行应用：" -ForegroundColor Cyan
Write-Host "  flutter run -d windows"
Write-Host ""
Write-Host "或直接运行：" -ForegroundColor Cyan
Write-Host "  build\windows\x64\runner\Debug\legado_flutter.exe"
Write-Host ""

Read-Host "按 Enter 退出"
