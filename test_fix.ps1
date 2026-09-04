# M12 修复测试脚本
# 用途：启动应用并验证左右边距是否对称

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "M12 修复验证 - 左右边距对称性测试" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "修复内容：" -ForegroundColor Yellow
Write-Host "1. 修改 feedPageTextsWithPrefixes：text.characters → text.substring(0, i)"
Write-Host "2. 移除 500ms 节流，paint 后立即 flush"
Write-Host "3. 对齐 Dart/Rust 字符边界切分方式"
Write-Host ""

Write-Host "启动应用中..." -ForegroundColor Green
Write-Host ""

# 启动应用并捕获输出
$logFile = "test_output.log"
Write-Host "日志将保存到: $logFile" -ForegroundColor Gray
Write-Host ""

# 使用 Start-Process 启动，输出重定向到文件
$proc = Start-Process -FilePath "flutter" -ArgumentList "run","-d","windows" -PassThru -NoNewWindow -RedirectStandardOutput $logFile -RedirectStandardError "${logFile}.err"

Write-Host "应用已启动 (PID: $($proc.Id))" -ForegroundColor Green
Write-Host ""
Write-Host "测试步骤：" -ForegroundColor Yellow
Write-Host "1. 打开测试书籍"
Write-Host "2. 观察首页左右边距是否对称"
Write-Host "3. 翻页 5-10 页，检查每页边距"
Write-Host "4. 按任意键停止应用并查看日志"
Write-Host ""

# 等待用户输入
Read-Host "完成测试后按 Enter 继续"

# 停止应用
if (!$proc.HasExited) {
    Write-Host "停止应用..." -ForegroundColor Yellow
    Stop-Process -Id $proc.Id -Force
}

# 分析日志
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "日志分析" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

if (Test-Path $logFile) {
    $geometryLines = Get-Content $logFile | Select-String "paint.geometry.first"
    
    if ($geometryLines.Count -gt 0) {
        Write-Host ""
        Write-Host "找到 $($geometryLines.Count) 条 geometry 日志：" -ForegroundColor Green
        Write-Host ""
        
        $totalDiff = 0
        $count = 0
        
        foreach ($line in $geometryLines | Select-Object -First 10) {
            if ($line -match "skiaW=([0-9.]+)\s+rustW=([0-9.]+)") {
                $skiaW = [double]$matches[1]
                $rustW = [double]$matches[2]
                $diff = $rustW - $skiaW
                $totalDiff += [Math]::Abs($diff)
                $count++
                
                $color = "Green"
                if ([Math]::Abs($diff) -gt 2) {
                    $color = "Red"
                } elseif ([Math]::Abs($diff) -gt 1) {
                    $color = "Yellow"
                }
                
                Write-Host "skiaW=$skiaW rustW=$rustW 偏差=$($diff.ToString('F1'))px" -ForegroundColor $color
            }
        }
        
        if ($count -gt 0) {
            $avgDiff = $totalDiff / $count
            Write-Host ""
            Write-Host "平均偏差: $($avgDiff.ToString('F2'))px" -ForegroundColor $(if ($avgDiff -le 2) { "Green" } else { "Red" })
            Write-Host ""
            
            if ($avgDiff -le 2) {
                Write-Host "✓ 修复成功！偏差在可接受范围内（≤2px）" -ForegroundColor Green
            } else {
                Write-Host "✗ 问题仍存在，平均偏差 >2px" -ForegroundColor Red
                Write-Host "  请检查 TESTING_GUIDE.txt 中的诊断步骤" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "未找到 geometry 日志，可能应用未正常运行" -ForegroundColor Red
    }
} else {
    Write-Host "日志文件不存在: $logFile" -ForegroundColor Red
}

Write-Host ""
Write-Host "完整日志已保存到: $logFile" -ForegroundColor Gray
