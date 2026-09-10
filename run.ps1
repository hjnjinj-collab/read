# ============================================
# 一键运行（开发模式，带热重载）
# 自动初始化 Visual Studio 编译环境后 flutter run
# ============================================

$gitUsrBin = "C:\Program Files\Git\usr\bin"
if (Test-Path $gitUsrBin) { $env:Path += ";$gitUsrBin" }

if (-not [Environment]::GetEnvironmentVariable("PROGRAMFILES(X86)", "Process")) {
    [Environment]::SetEnvironmentVariable("PROGRAMFILES(X86)", "C:\Program Files (x86)", "Process")
}

$vsWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$vcVars = $null
$vsCMakeBin = $null
$msvcBinPath = $null
if (Test-Path $vsWhere) {
    $vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if ($vsPath) {
        $vcVars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
        $vsCMakeBin = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
        $msvcDir = Get-ChildItem "$vsPath\VC\Tools\MSVC\*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($msvcDir) { $msvcBinPath = Join-Path $msvcDir.FullName "bin\Hostx64\x64" }
    }
}

$pathPrefix = ""
if ($vsCMakeBin -and (Test-Path $vsCMakeBin)) {
    if (-not ($env:Path -like "*$vsCMakeBin*")) {
        $env:Path = "$vsCMakeBin;$env:Path"
    }
}
$env:TrackFileAccess = "false"

flutter run -d windows
