<#
.SYNOPSIS
    ProcMon 自动化采集脚本：启动采集 → 运行目标命令 → 停止采集 → 导出 XML
.DESCRIPTION
    供 AI 自主调用，完成 ProcMon 采集全链路，输出 XML 路径供 ProcmonMCP 加载分析。
.EXAMPLE
    .\capture.ps1 -TargetCommand "D:\...\SdkMinCallDemo.exe --init"
    .\capture.ps1 -TargetCommand "D:\...\SdkMinCallDemo.exe --compile-probe" -TimeoutSeconds 30
    .\capture.ps1 -TargetCommand "D:\...\SdkMinCallDemo.exe" -FilterConfig "D:\filters.pmc"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCommand,

    [string]$OutputDir = "",

    [string]$ProcmonPath = "",

    [string]$FilterConfig = "",

    [string]$ProcessName = "",

    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

# --- 查找 Procmon64.exe ---
function Find-Procmon {
    param([string]$Hint)
    if ($Hint -and (Test-Path $Hint)) { return $Hint }

    $candidates = @(
        "D:\01_Software\08_开发工具\Procmon64.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\Procmon64.exe",
        "C:\Sysinternals\Procmon64.exe",
        "C:\SysinternalsSuite\Procmon64.exe",
        "C:\Tools\Procmon64.exe",
        "$env:USERPROFILE\Downloads\Procmon64.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }

    $found = Get-Command Procmon64.exe -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    return $null
}

# --- 等待 ProcMon 进程完全退出 ---
function Wait-ProcmonExit {
    param([int]$MaxSeconds = 30)
    for ($i = 0; $i -lt $MaxSeconds; $i++) {
        $proc = Get-Process -Name "Procmon64" -ErrorAction SilentlyContinue
        if (-not $proc) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

$procmon = Find-Procmon $ProcmonPath
if (-not $procmon) {
    Write-Error "找不到 Procmon64.exe，请通过 -ProcmonPath 指定路径"
    exit 1
}
Write-Host "[capture] Procmon64: $procmon"

# --- 准备输出目录 ---
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $OutputDir) {
    $OutputDir = Join-Path $PSScriptRoot "captures\capture-$timestamp"
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$pmlFile = Join-Path $OutputDir "capture.pml"
$xmlFile = Join-Path $OutputDir "capture.xml"
$manifestFile = Join-Path $OutputDir "manifest.json"

Write-Host "[capture] 输出目录: $OutputDir"

# --- 终止已有 ProcMon 实例并等待完全退出 ---
$existingProcmon = Get-Process -Name "Procmon64" -ErrorAction SilentlyContinue
if ($existingProcmon) {
    Write-Host "[capture] 终止已有 ProcMon 实例..."
    & $procmon /Terminate 2>$null
    if (-not (Wait-ProcmonExit 15)) {
        Write-Host "[capture] 警告：旧 ProcMon 实例未能在 15 秒内退出"
    }
}

# --- 处理过滤器：-ProcessName 快捷参数 或 -FilterConfig 自定义 PMC ---
$venvPython = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
$genFilterScript = Join-Path $PSScriptRoot "gen-filter.py"

if (-not $FilterConfig -and $ProcessName) {
    $autoFilterPath = Join-Path $OutputDir "auto-filter.pmc"
    Write-Host "[capture] 为进程 '$ProcessName' 自动生成过滤器..."
    & $venvPython $genFilterScript -o $autoFilterPath --process $ProcessName
    if ($LASTEXITCODE -eq 0 -and (Test-Path $autoFilterPath)) {
        $FilterConfig = $autoFilterPath
    } else {
        Write-Host "[capture] 警告：过滤器生成失败，将采集全部事件"
    }
} elseif (-not $FilterConfig -and -not $ProcessName) {
    $targetExeName = [System.IO.Path]::GetFileName(($TargetCommand -split ' ', 2)[0])
    if ($targetExeName) {
        $autoFilterPath = Join-Path $OutputDir "auto-filter.pmc"
        Write-Host "[capture] 从目标命令自动提取进程名 '$targetExeName'，生成过滤器..."
        & $venvPython $genFilterScript -o $autoFilterPath --process $targetExeName
        if ($LASTEXITCODE -eq 0 -and (Test-Path $autoFilterPath)) {
            $FilterConfig = $autoFilterPath
        } else {
            Write-Host "[capture] 警告：过滤器生成失败，将采集全部事件"
        }
    }
}

# --- 构建 ProcMon 启动参数 ---
$procmonArgs = @("/AcceptEula", "/Quiet", "/Minimized", "/BackingFile", $pmlFile)
if ($FilterConfig -and (Test-Path $FilterConfig)) {
    $procmonArgs += @("/LoadConfig", $FilterConfig)
    Write-Host "[capture] 使用过滤器: $FilterConfig"
} else {
    Write-Host "[capture] 未指定过滤器，采集全部事件（XML 可能较大）"
}

# --- 启动 ProcMon 采集 ---
Write-Host "[capture] 启动 ProcMon 采集..."
Start-Process -FilePath $procmon -ArgumentList $procmonArgs -NoNewWindow
Start-Sleep -Seconds 4

$procmonRunning = Get-Process -Name "Procmon64" -ErrorAction SilentlyContinue
if (-not $procmonRunning) {
    Write-Error "ProcMon 启动失败"
    exit 2
}
Write-Host "[capture] ProcMon 已启动 (PID: $($procmonRunning.Id))"

# --- 解析并运行目标命令 ---
Write-Host "[capture] 运行目标: $TargetCommand"
$startTime = Get-Date

$parts = $TargetCommand -split ' ', 2
$targetExe = $parts[0]
$targetArgs = if ($parts.Length -gt 1) { $parts[1] } else { "" }

$targetProc = $null
try {
    if ($targetArgs) {
        $targetProc = Start-Process -FilePath $targetExe -ArgumentList $targetArgs -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $OutputDir "stdout.txt") -RedirectStandardError (Join-Path $OutputDir "stderr.txt")
    } else {
        $targetProc = Start-Process -FilePath $targetExe -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $OutputDir "stdout.txt") -RedirectStandardError (Join-Path $OutputDir "stderr.txt")
    }
} catch {
    Write-Host "[capture] 目标命令启动失败: $_"
    & $procmon /Terminate 2>$null
    exit 3
}

Write-Host "[capture] 目标进程 PID: $($targetProc.Id)，等待完成（超时 ${TimeoutSeconds}s）..."

$exited = $targetProc.WaitForExit($TimeoutSeconds * 1000)
$endTime = Get-Date
$exitCode = if ($exited) { $targetProc.ExitCode } else { -1 }

if (-not $exited) {
    Write-Host "[capture] 目标进程超时，强制终止"
    try { $targetProc.Kill() } catch {}
}

$elapsed = ($endTime - $startTime).TotalSeconds
Write-Host "[capture] 目标进程退出码: $exitCode，耗时: $([math]::Round($elapsed, 1))s"

# --- 停止 ProcMon 并等待进程完全退出、释放文件锁 ---
Start-Sleep -Seconds 2
Write-Host "[capture] 停止 ProcMon..."
& $procmon /Terminate

if (-not (Wait-ProcmonExit 30)) {
    Write-Host "[capture] 警告：ProcMon 未能在 30 秒内退出，尝试强制终止"
    Get-Process -Name "Procmon64" -ErrorAction SilentlyContinue | Stop-Process -Force -Confirm:$false
    Start-Sleep -Seconds 3
}

# 额外等待文件锁释放
Start-Sleep -Seconds 3
Write-Host "[capture] ProcMon 已停止"

# --- 导出 XML ---
Write-Host "[capture] 导出 XML..."
if (-not (Test-Path $pmlFile)) {
    Write-Error "PML 文件未生成: $pmlFile"
    exit 4
}

$pmlSize = (Get-Item $pmlFile).Length
Write-Host "[capture] PML 大小: $([math]::Round($pmlSize / 1MB, 1)) MB"

# 启动导出（ProcMon 新实例加载 PML 并导出 XML）
Start-Process -FilePath $procmon -ArgumentList @("/AcceptEula", "/Quiet", "/OpenLog", $pmlFile, "/SaveAs", $xmlFile) -NoNewWindow

# 等待导出完成：ProcMon 进程退出 + XML 文件大小稳定
Write-Host "[capture] 等待 XML 导出完成..."
$exportWait = 0
$lastXmlSize = -1
while ($exportWait -lt 120) {
    Start-Sleep -Seconds 3
    $exportWait += 3

    $procmonStillRunning = Get-Process -Name "Procmon64" -ErrorAction SilentlyContinue

    if (Test-Path $xmlFile) {
        $currentXmlSize = (Get-Item $xmlFile).Length
        if (-not $procmonStillRunning -and $currentXmlSize -gt 0 -and $currentXmlSize -eq $lastXmlSize) {
            Write-Host "[capture] XML 导出完成（文件大小稳定 $([math]::Round($currentXmlSize / 1MB, 1)) MB）"
            break
        }
        $lastXmlSize = $currentXmlSize
    } elseif (-not $procmonStillRunning) {
        # ProcMon 已退出但 XML 不存在，等几秒看是否延迟写入
        Start-Sleep -Seconds 5
        if (-not (Test-Path $xmlFile)) {
            Write-Host "[capture] 错误：ProcMon 已退出但 XML 未生成，尝试重新导出..."
            Start-Process -FilePath $procmon -ArgumentList @("/AcceptEula", "/Quiet", "/OpenLog", $pmlFile, "/SaveAs", $xmlFile) -NoNewWindow
            Start-Sleep -Seconds 5
        }
    }

    if ($exportWait % 15 -eq 0) {
        Write-Host "[capture] 导出进行中... (${exportWait}s)"
    }
}

# 最终等待 ProcMon 退出
Wait-ProcmonExit 15 | Out-Null

if (-not (Test-Path $xmlFile) -or (Get-Item $xmlFile).Length -eq 0) {
    Write-Error "XML 导出失败: $xmlFile"
    exit 5
}

$xmlSize = (Get-Item $xmlFile).Length
Write-Host "[capture] XML 大小: $([math]::Round($xmlSize / 1MB, 1)) MB"

# --- 读取 stdout/stderr ---
$stdout = if (Test-Path (Join-Path $OutputDir "stdout.txt")) { Get-Content (Join-Path $OutputDir "stdout.txt") -Raw } else { "" }
$stderr = if (Test-Path (Join-Path $OutputDir "stderr.txt")) { Get-Content (Join-Path $OutputDir "stderr.txt") -Raw } else { "" }

# --- 写 manifest ---
$manifest = @{
    timestamp = $timestamp
    target_command = $TargetCommand
    target_exit_code = $exitCode
    target_timed_out = (-not $exited)
    elapsed_seconds = [math]::Round($elapsed, 1)
    pml_file = $pmlFile
    xml_file = $xmlFile
    pml_size_bytes = $pmlSize
    xml_size_bytes = $xmlSize
    filter_config = $FilterConfig
    procmon_path = $procmon
    stdout = if ($stdout) { $stdout.Trim() } else { "" }
    stderr = if ($stderr) { $stderr.Trim() } else { "" }
} | ConvertTo-Json -Depth 3

Set-Content -Path $manifestFile -Value $manifest -Encoding UTF8

Write-Host ""
Write-Host "========================================="
Write-Host "[capture] 采集完成"
Write-Host "[capture] XML 路径: $xmlFile"
Write-Host "[capture] Manifest: $manifestFile"
Write-Host "[capture] 目标退出码: $exitCode"
Write-Host "========================================="
Write-Host ""
Write-Host "下一步：AI 通过 MCP 工具 load_file 加载以下路径即可分析："
Write-Host $xmlFile
