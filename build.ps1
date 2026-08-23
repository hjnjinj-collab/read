# Legado Flutter 构建脚本
# 使用方法: powershell -ExecutionPolicy Bypass -File build.ps1

param(
    [switch]$SkipRust,
    [switch]$SkipCodegen,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ProjectRoot = "D:\android\example\legado_flutter"

function Write-Step {
    param($Message)
    Write-Host "`n==== $Message ====" -ForegroundColor Cyan
}

function Write-Success {
    param($Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Error {
    param($Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

try {
    Set-Location $ProjectRoot

    if ($Clean) {
        Write-Step "清理项目"
        
        Write-Host "清理 Flutter..."
        flutter clean
        
        Write-Host "清理 Rust..."
        Set-Location rust
        cargo clean
        Set-Location ..
        
        Write-Success "清理完成"
    }

    Write-Step "步骤 1/4: 检查环境"
    
    # 检查 Flutter
    Write-Host "检查 Flutter..."
    $flutterVersion = flutter --version 2>&1 | Select-String "Flutter"
    if ($flutterVersion) {
        Write-Success "Flutter 已安装: $flutterVersion"
    } else {
        throw "Flutter 未安装或不在 PATH 中"
    }
    
    # 检查 Rust
    Write-Host "检查 Rust..."
    $rustVersion = cargo --version 2>&1
    if ($rustVersion) {
        Write-Success "Rust 已安装: $rustVersion"
    } else {
        throw "Rust 未安装或不在 PATH 中"
    }

    Write-Step "步骤 2/4: 安装 Flutter 依赖"
    flutter pub get
    Write-Success "Flutter 依赖安装完成"

    if (-not $SkipCodegen) {
        Write-Step "步骤 3/4: 运行代码生成"
        dart run build_runner build --delete-conflicting-outputs
        Write-Success "代码生成完成"
    } else {
        Write-Host "跳过代码生成 (--SkipCodegen)" -ForegroundColor Yellow
    }

    if (-not $SkipRust) {
        Write-Step "步骤 4/4: 构建 Rust 代码"
        Set-Location rust
        
        Write-Host "构建 book_parser..."
        cargo build --package book_parser
        Write-Success "book_parser 构建完成"
        
        Write-Host "构建 reader_core..."
        cargo build --package reader_core
        Write-Success "reader_core 构建完成"
        
        Write-Host "构建 layout_engine..."
        cargo build --package layout_engine
        Write-Success "layout_engine 构建完成"
        
        Write-Host "构建 bridge..."
        cargo build --package bridge
        Write-Success "bridge 构建完成"
        
        Set-Location ..
        Write-Success "所有 Rust crate 构建完成"
    } else {
        Write-Host "跳过 Rust 构建 (--SkipRust)" -ForegroundColor Yellow
    }

    Write-Host "`n" -NoNewline
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "✓ 构建成功完成！" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`n运行以下命令启动应用:" -ForegroundColor Cyan
    Write-Host "  flutter run" -ForegroundColor Yellow
    Write-Host "`n或运行测试:" -ForegroundColor Cyan
    Write-Host "  cd rust" -ForegroundColor Yellow
    Write-Host "  cargo test --package reader_core --test pipeline_demo -- --nocapture" -ForegroundColor Yellow

} catch {
    Write-Host "`n" -NoNewline
    Write-Error "构建失败: $_"
    Write-Host "`n请查看错误信息并修复问题后重试" -ForegroundColor Yellow
    exit 1
}
