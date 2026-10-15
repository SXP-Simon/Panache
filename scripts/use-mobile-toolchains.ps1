# 将此脚本点导入当前 PowerShell；不修改系统 PATH 或其它项目的 SDK 配置。
param(
    [string]$ToolchainRoot = (Join-Path $env:LOCALAPPDATA 'HandwriteToolchains'),
    [string]$FlutterRoot = '',
    [string]$AndroidSdk = '',
    [switch]$EnterApp
)

$ErrorActionPreference = 'Stop'
if (!$FlutterRoot) { $FlutterRoot = Join-Path $ToolchainRoot 'flutter-3.47.5' }
if (!$AndroidSdk) { $AndroidSdk = Join-Path $ToolchainRoot 'android-sdk' }
if (!(Test-Path (Join-Path $FlutterRoot 'bin/flutter.bat'))) {
    throw 'Flutter SDK 未找到；使用 -FlutterRoot 指定 Flutter SDK 目录。'
}
$env:CARGO_HOME = Join-Path $ToolchainRoot 'cargo'
$env:RUSTUP_HOME = Join-Path $ToolchainRoot 'rustup'
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PATH = "$FlutterRoot\bin;$env:CARGO_HOME\bin;$AndroidSdk\platform-tools;$AndroidSdk\emulator;$AndroidSdk\cmdline-tools\latest\bin;$env:PATH"

# Rust 主机构建依赖 MSVC；通过安装器定位，避免钉死本机 VS 和 Windows SDK 版本。
$taskVsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (Test-Path $taskVsWhere) {
    $taskVsRoot = & $taskVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($taskVsRoot) {
        $taskMsvc = Get-ChildItem (Join-Path $taskVsRoot 'VC/Tools/MSVC') -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        $taskKit = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
        $taskKitVersion = Get-ChildItem (Join-Path $taskKit 'Include') -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        if ($taskMsvc -and $taskKitVersion) {
            $env:PATH = "$($taskMsvc.FullName)\bin\Hostx64\x64;$taskKit\bin\$($taskKitVersion.Name)\x64;$env:PATH"
            $env:CC_x86_64_pc_windows_msvc = "$($taskMsvc.FullName)\bin\Hostx64\x64\cl.exe"
            $env:INCLUDE = "$($taskMsvc.FullName)\include;$($taskKitVersion.FullName)\ucrt;$($taskKitVersion.FullName)\shared;$($taskKitVersion.FullName)\um;$($taskKitVersion.FullName)\winrt"
            $env:LIB = "$($taskMsvc.FullName)\lib\x64;$taskKit\Lib\$($taskKitVersion.Name)\ucrt\x64;$taskKit\Lib\$($taskKitVersion.Name)\um\x64"
        }
    }
}
Write-Host "Flutter: $FlutterRoot"
Write-Host "Android SDK: $AndroidSdk"
Write-Host "Rust: $env:RUSTUP_HOME"
if ($EnterApp) {
    # Windows LSP 对非 ASCII 路径的 Content-Length 计算可能截断初始化消息。
    # 使用指向真实工作树的 junction，无需移动仓库或复制源码。
    $taskRepository = Split-Path $PSScriptRoot -Parent
    $taskWorkspace = Join-Path $ToolchainRoot 'flutter-project'
    if (!(Test-Path $taskWorkspace)) {
        New-Item -ItemType Junction -Path $taskWorkspace -Target $taskRepository | Out-Null
    }
    $taskWorkspaceInfo = Get-Item $taskWorkspace
    if ($taskWorkspaceInfo.LinkType -ne 'Junction' -or
        [IO.Path]::GetFullPath($taskWorkspaceInfo.Target).TrimEnd('\') -ne [IO.Path]::GetFullPath($taskRepository).TrimEnd('\')) {
        throw "工作目录 $taskWorkspace 已存在且不指向当前仓库；请使用另一个 -ToolchainRoot。"
    }
    Set-Location (Join-Path $taskWorkspace 'app')
}
