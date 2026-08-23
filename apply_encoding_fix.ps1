# 编码问题快速修复脚本
# Phase 2: 增强编码检测

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  Phase 2: 增强编码检测" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# 步骤 1: 添加 chardetng 依赖
Write-Host "[1/3] 添加 chardetng 依赖..." -ForegroundColor Yellow

$cargoTomlPath = "rust\crates\book_parser\Cargo.toml"
$cargoContent = Get-Content $cargoTomlPath -Raw

if ($cargoContent -notmatch "chardetng") {
    Write-Host "正在添加 chardetng = `"0.1`" 到 Cargo.toml..." -ForegroundColor Gray
    
    # 在 dependencies 部分添加
    $cargoContent = $cargoContent -replace '(\[dependencies\])', "`$1`nchardetng = `"0.1`""
    Set-Content -Path $cargoTomlPath -Value $cargoContent -Encoding UTF8
    
    Write-Host "✓ chardetng 依赖已添加" -ForegroundColor Green
} else {
    Write-Host "✓ chardetng 依赖已存在" -ForegroundColor Green
}

# 步骤 2: 备份原文件
Write-Host ""
Write-Host "[2/3] 备份原始文件..." -ForegroundColor Yellow

$txtParserPath = "rust\crates\book_parser\src\txt_parser.rs"
$backupPath = "$txtParserPath.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

Copy-Item $txtParserPath $backupPath
Write-Host "✓ 原文件已备份到: $backupPath" -ForegroundColor Green

# 步骤 3: 提示手动修改
Write-Host ""
Write-Host "[3/3] 需要手动修改代码..." -ForegroundColor Yellow
Write-Host ""
Write-Host "请按照以下步骤修改 txt_parser.rs:" -ForegroundColor White
Write-Host ""
Write-Host "1. 在文件顶部添加 import:" -ForegroundColor Cyan
Write-Host "   use chardetng::EncodingDetector;" -ForegroundColor Gray
Write-Host ""
Write-Host "2. 在 TxtParser 结构体中添加字段:" -ForegroundColor Cyan
Write-Host "   detected_encoding: Option<&'static Encoding>," -ForegroundColor Gray
Write-Host "   encoding_name: String," -ForegroundColor Gray
Write-Host ""
Write-Host "3. 重写 decode_text() 函数（参考 docs\ENCODING_FIX_PLAN.md 中的代码）" -ForegroundColor Cyan
Write-Host ""
Write-Host "4. 修改 get_chapter_content_internal() 复用检测到的编码" -ForegroundColor Cyan
Write-Host ""
Write-Host "详细代码请参考: docs\ENCODING_FIX_PLAN.md" -ForegroundColor Yellow
Write-Host ""
Write-Host "修改完成后，运行:" -ForegroundColor White
Write-Host "  .\fix_sync.ps1" -ForegroundColor Gray
Write-Host "  flutter test test\encoding_diagnosis_test.dart" -ForegroundColor Gray
Write-Host ""
