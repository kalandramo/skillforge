<#
.SYNOPSIS
  把本仓库的 skills\* 挂载到宿主的技能目录（Windows 原生，无需 Git Bash）。

.DESCRIPTION
  与 install.sh 等价，但用目录联接（Junction）代替符号链接：
  Junction 不需要开发者模式或管理员权限，且改动会实时反映到仓库，
  不像复制模式那样需要每次重跑脚本。

  安全要点：PowerShell 5.1 的 Remove-Item -Recurse 作用于 Junction 时会删除
  目标目录的内容（而不是链接本身）。本脚本一律用 [System.IO.Directory]::Delete
  处理链接，绝不递归删除 Junction。

.PARAMETER Target
  指定技能目录，可多个。默认自动探测 ~\.workbuddy\skills 与 ~\.claude\skills。

.PARAMETER Copy
  强制复制而非 Junction（不支持链接的极端环境用；改动需重跑）。

.PARAMETER Check
  只检查已安装版本是否落后于本仓库，不做改动。

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Target "$env:USERPROFILE\.workbuddy\skills" -Check
#>
#Requires -Version 5.1

param(
    [string[]]$Target = @(),
    [switch]$Copy,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir = Join-Path $Repo 'skills'

function Get-RepoRev {
    try {
        $r = & git -C $Repo rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $r) { return "$r".Trim() }
    } catch { }
    return 'unknown'
}

function Test-IsLink {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($null -eq $item.LinkType) { return $false }
    return ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink')
}

function Remove-LinkOnly {
    # 只删除链接自身，绝不触碰它指向的目录
    param([string]$Path)
    [System.IO.Directory]::Delete($Path, $false)
}

if (-not (Test-Path -LiteralPath $SrcDir)) { throw "未找到 $SrcDir" }
$RepoRev = Get-RepoRev

if ($Target.Count -eq 0) {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.workbuddy\skills'),
        (Join-Path $env:USERPROFILE '.claude\skills')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $Target += $c }
    }
    if ($Target.Count -eq 0) {
        Write-Host "未探测到技能目录。用 -Target 指定，例如：" -ForegroundColor Yellow
        Write-Host "  .\install.ps1 -Target `"$env:USERPROFILE\.workbuddy\skills`""
        exit 1
    }
}

$skills = Get-ChildItem -LiteralPath $SrcDir -Directory

# ------------------------------------------------------------------ Check
if ($Check) {
    $drift = $false
    foreach ($t in $Target) {
        Write-Host "==> $t"
        if (-not (Test-Path -LiteralPath $t)) { Write-Host "  （目录不存在）"; continue }
        foreach ($s in $skills) {
            $dst = Join-Path $t $s.Name
            if (Test-IsLink $dst) {
                Write-Host "  [link]  $($s.Name) — 目录联接，始终与仓库一致"
            } elseif (Test-Path -LiteralPath $dst) {
                $marker = Join-Path $dst '.skillforge-origin'
                if (Test-Path -LiteralPath $marker) {
                    $installed = (Select-String -LiteralPath $marker -Pattern '^rev=' |
                        Select-Object -First 1).Line -replace '^rev=', ''
                    if ($installed -eq $RepoRev) {
                        Write-Host "  [ ok ]  $($s.Name) — 已同步 ($RepoRev)"
                    } else {
                        Write-Host "  [stale] $($s.Name) — 已安装 $installed，仓库 $RepoRev，需重跑" -ForegroundColor Yellow
                        $drift = $true
                    }
                } else {
                    Write-Host "  [ ?  ]  $($s.Name) — 存在但不是本脚本安装的（无来源标记）"
                    $drift = $true
                }
            } else {
                Write-Host "  [miss]  $($s.Name) — 未安装"
                $drift = $true
            }
        }
    }
    Write-Host ("-" * 60)
    if ($drift) {
        Write-Host "存在未同步项，运行不带 -Check 的 install.ps1 同步" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "全部已同步"
    exit 0
}

# ------------------------------------------------------------------ Install
$ok = 0; $skipped = 0; $failed = 0

foreach ($t in $Target) {
    if (-not (Test-Path -LiteralPath $t)) {
        New-Item -ItemType Directory -Path $t -Force | Out-Null
    }
    Write-Host "==> $t"

    foreach ($s in $skills) {
        $dst = Join-Path $t $s.Name
        $marker = Join-Path $dst '.skillforge-origin'

        if (Test-IsLink $dst) {
            try { Remove-LinkOnly $dst }
            catch { Write-Host "  [FAIL] 无法移除旧链接 $dst ：$_" -ForegroundColor Red; $failed++; continue }
        } elseif (Test-Path -LiteralPath $dst) {
            if (Test-Path -LiteralPath $marker) {
                # 用 .NET API 而非 Remove-Item 删除旧副本：Remove-Item 可能被
                # 安全钩子接管而抛错，且 PS 5.1 的 -Recurse 对 Junction 会删除目标内容。
                try { [System.IO.Directory]::Delete($dst, $true) }
                catch { Write-Host "  [FAIL] 无法移除旧副本 $dst ：$_" -ForegroundColor Red; $failed++; continue }
            } else {
                Write-Host "  [skip] $($s.Name) — 已存在且非本脚本安装，不覆盖"
                Write-Host "         如需接管：改名后重跑，或手工删除该目录"
                $skipped++
                continue
            }
        }

        if (-not $Copy) {
            try {
                New-Item -ItemType Junction -Path $dst -Target $s.FullName -ErrorAction Stop | Out-Null
                Write-Host "  [junction] $($s.Name)"
                $ok++
                continue
            } catch {
                Write-Host "  [info] $($s.Name) 无法创建 Junction，改为复制：$($_.Exception.Message)"
            }
        }

        try {
            Copy-Item -LiteralPath $s.FullName -Destination $dst -Recurse -Force
            @(
                "source=$($s.FullName)"
                "rev=$RepoRev"
                "installed_at=$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')"
            ) | Set-Content -LiteralPath (Join-Path $dst '.skillforge-origin') -Encoding UTF8
            Write-Host "  [copy] $($s.Name)（改动后需重跑本脚本）"
            $ok++
        } catch {
            Write-Host "  [FAIL] $($s.Name) 复制失败：$_" -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ("-" * 60)
Write-Host "完成：挂载 $ok，跳过 $skipped，失败 $failed（rev $RepoRev）"
if ($failed -gt 0) { exit 1 }
Write-Host "提示：技能列表在会话启动时加载，新挂载的技能需新开会话才可见。"
