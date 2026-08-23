# fix_patch.ps1 - 自动添加 patch 到 PATH 并编译
Write-Host "=============================" -ForegroundColor Cyan
Write-Host "修复 rquickjs-sys 编译问题" -ForegroundColor Cyan
Write-Host "=============================" -ForegroundColor Cyan
Write-Host ""

# 1. 检查 Git 安装
$gitUsrBin = "C:\Program Files\Git\usr\bin"
if (-not (Test-Path "$gitUsrBin\patch.exe")) {
    Write-Host "❌ 未找到 Git for Windows 安装" -ForegroundColor Red
    Write-Host "请安装 Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
    exit 1
}

# 2. 临时添加到 PATH
$env:PATH = "$env:PATH;$gitUsrBin"
Write-Host "✓ [1/4] 已添加 patch 到 PATH" -ForegroundColor Green

# 3. 验证 patch 可用
try {
    $patchVersion = & patch --version 2>&1 | Select-Object -First 1
    Write-Host "✓ [2/4] patch 可用: $patchVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ patch 命令仍然不可用" -ForegroundColor Red
    exit 1
}

# 4. 清理旧构建
Write-Host "⏳ [3/4] 清理旧构建..." -ForegroundColor Yellow
cd rust
cargo clean | Out-Null
cd ..
Write-Host "✓ [3/4] 清理完成" -ForegroundColor Green

# 5. 重新编译
Write-Host "⏳ [4/4] 编译 Rust 代码..." -ForegroundColor Yellow
cd rust
cargo build --release

if ($LASTEXITCODE -eq 0) {
    cd ..
    Write-Host ""
    Write-Host "=============================" -ForegroundColor Green
    Write-Host "✓ 编译成功！" -ForegroundColor Green
    Write-Host "=============================" -ForegroundColor Green
    Write-Host ""
    Write-Host "提示：如果需要永久生效，请运行以下命令（管理员权限）：" -ForegroundColor Cyan
    Write-Host ""
    Write-Host '$userPath = [Environment]::GetEnvironmentVariable("Path", "User")' -ForegroundColor Yellow
    Write-Host '[Environment]::SetEnvironmentVariable("Path", "$userPath;C:\Program Files\Git\usr\bin", "User")' -ForegroundColor Yellow
    Write-Host ""
    Write-Host "下一步：运行 .\fix_sync.ps1 完成完整构建" -ForegroundColor Cyan
} else {
    cd ..
    Write-Host ""
    Write-Host "=============================" -ForegroundColor Red
    Write-Host "❌ 编译失败" -ForegroundColor Red
    Write-Host "=============================" -ForegroundColor Red
    Write-Host ""
    Write-Host "请查看上方错误信息，或查阅文档：docs\BUG_FIXES.md #9" -ForegroundColor Yellow
    exit 1
}
