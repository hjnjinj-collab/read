# fix_patch_permanent.ps1 - 永久添加 patch 到用户 PATH
# 需要管理员权限

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "永久添加 Git patch 到系统 PATH" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# 检查 Git 安装
$gitUsrBin = "C:\Program Files\Git\usr\bin"
if (-not (Test-Path "$gitUsrBin\patch.exe")) {
    Write-Host "❌ 未找到 Git for Windows 安装" -ForegroundColor Red
    Write-Host "patch.exe 应该在: $gitUsrBin" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "请安装 Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ 找到 patch.exe: $gitUsrBin\patch.exe" -ForegroundColor Green
Write-Host ""

# 获取当前用户 PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")

# 检查是否已存在
if ($userPath -like "*$gitUsrBin*") {
    Write-Host "✓ $gitUsrBin 已在用户 PATH 中" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "验证 patch 命令..." -ForegroundColor Cyan
    
    # 刷新当前会话的 PATH
    $env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    
    try {
        $patchVersion = & patch --version 2>&1 | Select-Object -First 1
        Write-Host "✓ patch 可用: $patchVersion" -ForegroundColor Green
    } catch {
        Write-Host "⚠️  PATH 中有路径但命令不可用，请重启终端" -ForegroundColor Yellow
    }
    exit 0
}

# 添加到用户 PATH
Write-Host "正在添加到用户 PATH..." -ForegroundColor Cyan

try {
    [Environment]::SetEnvironmentVariable(
        "Path",
        "$userPath;$gitUsrBin",
        "User"
    )
    Write-Host "✓ 成功添加到用户 PATH" -ForegroundColor Green
    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host "✓ 配置完成！" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "重要：请关闭所有终端窗口，重新打开后运行：" -ForegroundColor Yellow
    Write-Host "  patch --version" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "然后即可正常编译 Rust 项目。" -ForegroundColor Cyan
} catch {
    Write-Host "❌ 添加失败: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "请以管理员权限运行此脚本，或手动添加到环境变量：" -ForegroundColor Yellow
    Write-Host "  1. Win + R 打开运行对话框" -ForegroundColor Cyan
    Write-Host "  2. 输入: sysdm.cpl" -ForegroundColor Cyan
    Write-Host "  3. 高级 -> 环境变量" -ForegroundColor Cyan
    Write-Host "  4. 用户变量 -> Path -> 编辑 -> 新建" -ForegroundColor Cyan
    Write-Host "  5. 添加: $gitUsrBin" -ForegroundColor Cyan
    exit 1
}
