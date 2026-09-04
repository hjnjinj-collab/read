#!/usr/bin/env pwsh
# 快速验证脚本 - 检查修复是否生效

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  M12 修复快速验证" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 检查修改的文件
$files = @(
    "lib\core\services\measure_text_service.dart",
    "lib\features\reader\presentation\widgets\reader_page_widget.dart"
)

Write-Host "检查修改的文件..." -ForegroundColor Yellow
$allExist = $true
foreach ($file in $files) {
    if (Test-Path $file) {
        Write-Host "  ✓ $file" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $file 不存在" -ForegroundColor Red
        $allExist = $false
    }
}

if (-not $allExist) {
    Write-Host ""
    Write-Host "错误：部分文件不存在，请检查工作目录" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "验证关键修改..." -ForegroundColor Yellow

# 检查 measure_text_service.dart 中的关键修改
$content1 = Get-Content "lib\core\services\measure_text_service.dart" -Raw
if ($content1 -match "text\.substring\(0, i\)" -and $content1 -match "_isLowSurrogate") {
    Write-Host "  ✓ measure_text_service.dart: substring 方法已应用" -ForegroundColor Green
} else {
    Write-Host "  ✗ measure_text_service.dart: 修改未生效" -ForegroundColor Red
}

# 检查 reader_page_widget.dart 中的关键修改
$content2 = Get-Content "lib\features\reader\presentation\widgets\reader_page_widget.dart" -Raw
if ($content2 -notmatch "_maybeFlushMeasurements" -and $content2 -match "flushToRust\(\)") {
    Write-Host "  ✓ reader_page_widget.dart: 节流已移除，立即 flush 已应用" -ForegroundColor Green
} else {
    Write-Host "  ✗ reader_page_widget.dart: 修改未生效" -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "下一步：" -ForegroundColor Yellow
Write-Host "  1. 运行构建脚本: .\fix_sync.ps1"
Write-Host "  2. 启动应用测试: flutter run -d windows"
Write-Host "  3. 或运行完整测试: .\test_fix.ps1"
Write-Host ""
Write-Host "期望结果：" -ForegroundColor Yellow
Write-Host "  - 左右边距视觉上对称"
Write-Host "  - rustW ≈ skiaW (偏差 ≤2px)"
Write-Host "  - 含英文/标点的行不再有 11.2px 偏差"
Write-Host ""
Write-Host "详细说明请查看: M12_FIX_REPORT.md" -ForegroundColor Gray
Write-Host ""
