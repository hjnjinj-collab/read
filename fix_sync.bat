@echo off
REM ============================================
REM Flutter-Rust 同步修复脚本
REM 用于解决 Content hash 不匹配问题
REM ============================================

echo.
echo ========================================
echo   Flutter-Rust 同步修复脚本
echo ========================================
echo.

REM 1. 关闭相关进程
echo [1/6] 关闭相关进程...
taskkill /F /IM legado_flutter.exe 2>nul
taskkill /F /IM flutter.exe 2>nul
taskkill /F /IM dart.exe 2>nul
timeout /t 2 /nobreak >nul

REM 2. 清理 Flutter 缓存
echo [2/6] 清理 Flutter 缓存...
flutter clean
timeout /t 1 /nobreak >nul

REM 3. 清理 Rust 缓存
echo [3/6] 清理 Rust 缓存...
cd rust
cargo clean
cd ..
timeout /t 1 /nobreak >nul

REM 4. 获取依赖
echo [4/6] 获取依赖...
flutter pub get
timeout /t 1 /nobreak >nul

REM 5. 重新生成 FFI 绑定
echo [5/6] 重新生成 FFI 绑定...
flutter_rust_bridge_codegen generate
timeout /t 2 /nobreak >nul

REM 6. 构建应用
echo [6/6] 构建 Windows 应用...
flutter build windows --debug

echo.
echo ========================================
echo   修复完成！
echo ========================================
echo.
echo 运行应用:
echo   flutter run -d windows
echo.
echo 或直接运行:
echo   build\windows\x64\runner\Debug\legado_flutter.exe
echo.

pause
