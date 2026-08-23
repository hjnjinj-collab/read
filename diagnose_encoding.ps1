# 快速诊断脚本
# 用于立即定位章节内容乱码问题

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  Legado Flutter 编码诊断工具" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# 步骤 1: 检查 Rust 代码
Write-Host "[1/4] 检查 Rust 诊断模块..." -ForegroundColor Yellow
if (Test-Path "rust\crates\bridge\src\diagnostics.rs") {
    Write-Host "✓ diagnostics.rs 已创建" -ForegroundColor Green
} else {
    Write-Host "✗ diagnostics.rs 不存在，请先创建该文件" -ForegroundColor Red
    exit 1
}

# 步骤 2: 构建 Rust 代码
Write-Host ""
Write-Host "[2/4] 构建 Rust 代码（包含诊断 API）..." -ForegroundColor Yellow
Write-Host "提示: 这将需要 5-10 分钟..." -ForegroundColor Gray

$buildStart = Get-Date
.\fix_sync.ps1
$buildEnd = Get-Date
$buildTime = ($buildEnd - $buildStart).TotalSeconds

if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ 构建成功 (耗时: $([math]::Round($buildTime, 1))秒)" -ForegroundColor Green
} else {
    Write-Host "✗ 构建失败，请检查错误信息" -ForegroundColor Red
    exit 1
}

# 步骤 3: 创建 Flutter 测试文件
Write-Host ""
Write-Host "[3/4] 创建 Flutter 诊断测试..." -ForegroundColor Yellow

$testDir = "test"
if (-not (Test-Path $testDir)) {
    New-Item -ItemType Directory -Path $testDir | Out-Null
}

$testContent = @"
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/ffi/rust_bridge.dart/api.dart' as rust_api;

void main() {
  group('编码诊断测试', () {
    const testFilePath = r'D:\android\example\test_book.txt';

    test('1. 诊断文件编码', () async {
      print('\n========== 文件编码诊断 ==========');
      final result = await rust_api.diagnoseFileEncodingApi(
        filePath: testFilePath,
      );
      print(result);
      
      // 检查是否有解码错误
      if (result.contains('有解码错误: true') || result.contains('UTF-8-lossy')) {
        print('\n⚠️ 警告: 文件编码检测有问题！');
      } else {
        print('\n✓ 文件编码检测正常');
      }
    });

    test('2. 诊断章节内容', () async {
      print('\n========== 章节内容诊断 ==========');
      
      // 打开书籍
      final bookId = await rust_api.parseTxtFile(
        filePath: testFilePath,
        bookName: 'test_book',
      );
      
      // 获取章节数量
      final chapters = await rust_api.getChapters(bookId: bookId);
      print('总章节数: `${chapters.length}`\n');
      
      // 诊断前3章
      for (int i = 0; i < (chapters.length < 3 ? chapters.length : 3); i++) {
        print('--- 章节 `$i`: `${chapters[i].title}` ---');
        final result = await rust_api.diagnoseChapterEncodingApi(
          bookId: bookId,
          chapterIndex: i,
        );
        print(result);
        
        if (result.contains('替换字符(�):') && 
            !result.contains('替换字符(�): 0')) {
          print('⚠️ 警告: 章节 `$i` 包含乱码字符！\n');
        }
      }
    });

    test('3. 对比原始和处理后内容', () async {
      print('\n========== 内容处理对比 ==========');
      
      final bookId = await rust_api.parseTxtFile(
        filePath: testFilePath,
        bookName: 'test_book',
      );
      
      // 对比第一章
      final result = await rust_api.compareRawAndProcessedContent(
        bookId: bookId,
        chapterIndex: 0,
      );
      print(result);
      
      // 检查是否引入新的乱码
      final lines = result.split('\n');
      for (final line in lines) {
        if (line.contains('替换字符变化:') && line.contains('+')) {
          print('\n⚠️ 警告: 内容处理引入了乱码字符！');
          break;
        }
      }
    });
  });
}
"@

$testFilePath = "$testDir\encoding_diagnosis_test.dart"
Set-Content -Path $testFilePath -Value $testContent -Encoding UTF8
Write-Host "✓ 测试文件已创建: $testFilePath" -ForegroundColor Green

# 步骤 4: 运行诊断测试
Write-Host ""
Write-Host "[4/4] 运行诊断测试..." -ForegroundColor Yellow
Write-Host "提示: 测试输出将显示编码诊断信息" -ForegroundColor Gray
Write-Host ""

flutter test $testFilePath --plain-name="编码诊断"

# 总结
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "  诊断完成！" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "下一步:" -ForegroundColor Yellow
Write-Host "1. 查看上方的诊断输出" -ForegroundColor White
Write-Host "2. 检查是否有 '⚠️ 警告' 标记" -ForegroundColor White
Write-Host "3. 根据警告类型，参考以下文档:" -ForegroundColor White
Write-Host "   - docs\ENCODING_FIX_PLAN.md (修复计划)" -ForegroundColor Gray
Write-Host "   - docs\ENCODING_DIAGNOSIS_GUIDE.md (诊断指南)" -ForegroundColor Gray
Write-Host ""
Write-Host "如果发现乱码问题，请开始执行修复 Phase 2-4" -ForegroundColor Yellow
Write-Host ""
