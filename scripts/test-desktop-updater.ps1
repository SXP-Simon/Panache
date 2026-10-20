# 仅在托管 CI 上以临时标准用户验证真实助手，生产助手始终拒绝提权。
param(
    [string]$DartExecutable = '',
    [string]$CompiledUpdater = $env:PANACHE_COMPILED_UPDATER,
    [string]$UpdaterDirectory = (Join-Path $PSScriptRoot '../app/updater')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$DartExecutable) { $DartExecutable = (Get-Command dart -ErrorAction Stop).Source }
$DartExecutable = (Resolve-Path -LiteralPath $DartExecutable).Path
# Flutter 的 dart.bat 会写共享 SDK 的锁文件；测试使用其真实 Dart 可执行文件。
if ([IO.Path]::GetExtension($DartExecutable) -eq '.bat') {
    $sdkDart = Join-Path (Split-Path $DartExecutable -Parent) 'cache/dart-sdk/bin/dart.exe'
    if (!(Test-Path -LiteralPath $sdkDart -PathType Leaf)) {
        throw 'Provide the native Dart SDK dart.exe with -DartExecutable.'
    }
    $DartExecutable = (Resolve-Path -LiteralPath $sdkDart).Path
}
$UpdaterDirectory = (Resolve-Path -LiteralPath $UpdaterDirectory).Path
if ($CompiledUpdater) { $CompiledUpdater = (Resolve-Path -LiteralPath $CompiledUpdater).Path }
if ($env:OS -ne 'Windows_NT') { throw 'This wrapper requires Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$elevated) {
    Push-Location $UpdaterDirectory
    try {
        if ($CompiledUpdater) { $env:PANACHE_COMPILED_UPDATER = $CompiledUpdater }
        else { Remove-Item Env:PANACHE_COMPILED_UPDATER -ErrorAction SilentlyContinue }
        & $DartExecutable pub get
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & $DartExecutable test --reporter expanded
        exit $LASTEXITCODE
    } finally { Pop-Location }
}

# 不能在开发机或自托管 runner 上创建账号、修改目录权限。
if ($env:CI -ne 'true' -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Elevated tests require an isolated GitHub-hosted Windows runner.'
}
if (!$env:RUNNER_TEMP -or !(Test-Path -LiteralPath $env:RUNNER_TEMP -PathType Container)) {
    throw 'RUNNER_TEMP must identify an existing job temporary directory.'
}
$temporaryParent = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$jobDirectory = Join-Path $temporaryParent ('panache-updater-test-' + [guid]::NewGuid().ToString('N'))
$accountName = 'PanacheT' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$accountCreated = $false
$sdkAclGranted = $false
try {
    New-Item -ItemType Directory -Path $jobDirectory | Out-Null
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = ConvertTo-SecureString ('Aa1!' + [Convert]::ToBase64String($bytes)) -AsPlainText -Force
    $account = New-LocalUser -Name $accountName -Password $password -AccountNeverExpires -PasswordNeverExpires
    $accountCreated = $true
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    Add-LocalGroupMember -Group $usersGroup -Member $account
    $credential = [pscredential]::new("$env:COMPUTERNAME\$accountName", $password)
    # 使用独立源码副本，避免不同用户共享 .dart_tool、pub cache 或实际用户资料。
    $checkout = Join-Path $jobDirectory 'updater'
    New-Item -ItemType Directory -Path $checkout | Out-Null
    foreach ($name in @('bin', 'lib', 'test', 'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml')) {
        Copy-Item -LiteralPath (Join-Path $UpdaterDirectory $name) -Destination $checkout -Recurse
    }
    $helper = ''
    if ($CompiledUpdater) {
        $helper = Join-Path $jobDirectory 'panache-updater.exe'
        Copy-Item -LiteralPath $CompiledUpdater -Destination $helper
    }
    $configuration = @{
        dart = $DartExecutable; checkout = $checkout; helper = $helper
        cache = (Join-Path $jobDirectory 'pub-cache'); temporary = (Join-Path $jobDirectory 'temporary')
    }
    foreach ($directory in @($configuration.cache, $configuration.temporary)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $configuration | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $jobDirectory 'config.json') -Encoding utf8
    $childScript = Join-Path $jobDirectory 'child.ps1'
    @'
param([string]$ConfigurationPath)
$ErrorActionPreference = 'Stop'
try {
    $who = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The test child must run as a standard user.'
    }
    $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
    $env:PUB_CACHE = $configuration.cache
    $env:TEMP = $configuration.temporary
    $env:TMP = $configuration.temporary
    if ($configuration.helper) { $env:PANACHE_COMPILED_UPDATER = $configuration.helper }
    else { Remove-Item Env:PANACHE_COMPILED_UPDATER -ErrorAction SilentlyContinue }
    Set-Location -LiteralPath $configuration.checkout
    & $configuration.dart pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $configuration.dart test --reporter expanded
    exit $LASTEXITCODE
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
'@ | Set-Content -LiteralPath $childScript -Encoding utf8
    # 仅本次隔离目录可写，SDK 只提供读取与执行权限。
    & icacls.exe $jobDirectory /grant "*$($account.SID.Value):(OI)(CI)M" /T /Q
    if ($LASTEXITCODE -ne 0) { throw 'Unable to grant the test directory access.' }
    $dartSdk = Split-Path (Split-Path $DartExecutable -Parent) -Parent
    & icacls.exe $dartSdk /grant "*$($account.SID.Value):(OI)(CI)RX" /T /Q
    if ($LASTEXITCODE -ne 0) { throw 'Unable to grant read-only Dart SDK access.' }
    $sdkAclGranted = $true
    $stdout = Join-Path $jobDirectory 'stdout.log'
    $stderr = Join-Path $jobDirectory 'stderr.log'
    $shell = (Get-Process -Id $PID).Path
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigurationPath "{1}"' -f
        $childScript, (Join-Path $jobDirectory 'config.json')
    $child = Start-Process -FilePath $shell -ArgumentList $arguments -Credential $credential -LoadUserProfile `
        -WorkingDirectory $jobDirectory -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    while (!$child.WaitForExit(1000)) { }
    $child.WaitForExit()
    if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout | Write-Output }
    if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr | Write-Output }
    $exitCode = $child.ExitCode
    if ($null -eq $exitCode) { throw 'Test child did not provide an exit code.' }
} finally {
    if ($sdkAclGranted) {
        & icacls.exe $dartSdk /remove:g "*$($account.SID.Value)" /T /Q
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Unable to remove the temporary SDK access rule.' }
    }
    if ($accountCreated) { Remove-LocalUser -Name $accountName -ErrorAction Stop }
    # 不递归删除账号 profile、checkout 或用户资料；托管 runner 回收本 job 的临时目录。
}
exit $exitCode
