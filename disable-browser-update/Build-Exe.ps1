<#
.SYNOPSIS
    把 Disable-BrowserUpdate.ps1 编译成单文件 exe

.DESCRIPTION
    用 Windows 自带的 csc.exe 编译，不下载、不依赖任何第三方模块，全过程可审查。

    原理：生成一段 C# 宿主代码，把脚本以 Base64 形式嵌入其中，运行时在进程内
    创建 PowerShell Runspace 执行。同时嵌入 requireAdministrator 清单，
    双击即自动请求提权（脚本内的自提权逻辑因此不会被触发）。

    编译为 /target:winexe，不会出现控制台窗口。

.PARAMETER Source
    要打包的 .ps1，默认为同目录下的 Disable-BrowserUpdate.ps1

.PARAMETER Output
    输出的 exe 路径，默认为同目录下的 DisableBrowserUpdate.exe

.NOTES
    ⚠️ 杀软误报警告
    本脚本的行为特征（停用服务 + 禁用计划任务 + 改注册表 + 请求管理员权限）
    正好落在杀软启发式规则的可疑区间。打包成未签名 exe 后被拦截的概率很高，
    且首次运行会触发 SmartScreen。自用场景建议直接跑 .ps1 或用快捷方式。
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Output
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在 param 默认值中不一定可用，放到这里解析
$root = if ($PSScriptRoot) { $PSScriptRoot }
        elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
        else { (Get-Location).Path }
if (-not $Source) { $Source = Join-Path $root 'Disable-BrowserUpdate.ps1' }
if (-not $Output) { $Output = Join-Path $root '禁用浏览器更新.exe' }

# ---------------------------------------------------------------- 环境检查
if (-not (Test-Path $Source)) { throw "找不到源脚本: $Source" }

$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64' -Filter 'csc.exe' -Recurse -ErrorAction SilentlyContinue |
       Sort-Object FullName | Select-Object -Last 1
if (-not $csc) { throw '找不到 csc.exe，需要 .NET Framework 4.x' }

# PowerShell 宿主 API 所在的引用程序集
$smaCandidates = @(
    'C:\Program Files (x86)\Reference Assemblies\Microsoft\WindowsPowerShell\3.0\System.Management.Automation.dll'
    [System.Reflection.Assembly]::GetAssembly([powershell]).Location
)
$sma = $smaCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $sma) { throw '找不到 System.Management.Automation.dll' }

Write-Host "csc.exe : $($csc.FullName)"
Write-Host "SMA     : $sma"
Write-Host "源脚本  : $Source"

# ---------------------------------------------------------------- 生成中间文件
$work = Join-Path $env:TEMP ("build_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    # 以 UTF-8 编码嵌入，避免中文界面在宿主里变成乱码
    $scriptBytes = [System.IO.File]::ReadAllBytes($Source)
    $b64 = [Convert]::ToBase64String($scriptBytes)

    # Base64 串很长，切成多行拼接，避免单行过长导致 csc 处理异常
    $chunks = [regex]::Matches($b64, '.{1,200}') | ForEach-Object { '            "' + $_.Value + '"' }
    $b64Literal = $chunks -join " +`r`n"

    $manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:asm.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" />
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}" />
    </application>
  </compatibility>
</assembly>
'@

    $csharp = @"
using System;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

static class Launcher
{
    // 被打包的 PowerShell 脚本（UTF-8 + BOM，Base64 编码）
    private static readonly string ScriptBase64 =
$b64Literal;

    [STAThread]
    static void Main()
    {
        string script;
        try
        {
            byte[] raw = Convert.FromBase64String(ScriptBase64);
            // 跳过 UTF-8 BOM，否则第一行会多出一个不可见字符导致解析失败
            int offset = (raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) ? 3 : 0;
            script = Encoding.UTF8.GetString(raw, offset, raw.Length - offset);
        }
        catch (Exception ex)
        {
            MessageBox.Show("无法解出内嵌脚本:\n" + ex.Message, "启动失败",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        try
        {
            using (Runspace rs = RunspaceFactory.CreateRunspace())
            {
                // WinForms 必须在 STA 线程上跑，Runspace 也要显式声明
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions  = PSThreadOptions.UseCurrentThread;
                rs.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    ps.Invoke();

                    if (ps.HadErrors && ps.Streams.Error.Count > 0)
                    {
                        StringBuilder sb = new StringBuilder();
                        int n = 0;
                        foreach (ErrorRecord e in ps.Streams.Error)
                        {
                            if (n++ >= 10) { sb.AppendLine("..."); break; }
                            sb.AppendLine(e.ToString());
                        }
                        MessageBox.Show(sb.ToString(), "脚本执行出错",
                            MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "运行失败",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
"@

    $csPath  = Join-Path $work 'Launcher.cs'
    $manPath = Join-Path $work 'app.manifest'
    [System.IO.File]::WriteAllText($csPath,  $csharp,   [System.Text.UTF8Encoding]::new($true))
    [System.IO.File]::WriteAllText($manPath, $manifest, [System.Text.UTF8Encoding]::new($false))

    # ------------------------------------------------------------ 编译
    $args = @(
        '/nologo'
        '/target:winexe'          # winexe = 不带控制台窗口
        "/out:$Output"
        "/win32manifest:$manPath"
        "/reference:$sma"
        '/reference:System.Windows.Forms.dll'
        '/reference:System.Drawing.dll'
        '/optimize+'
        $csPath
    )
    Write-Host "`n编译中..."
    $out = & $csc.FullName @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "编译失败 (exit $LASTEXITCODE)"
    }
    $out | Where-Object { $_ } | ForEach-Object { Write-Host $_ }

    $info = Get-Item $Output
    Write-Host "`n完成: $($info.FullName)" -ForegroundColor Green
    Write-Host ("大小: {0:N0} KB" -f ($info.Length / 1KB)) -ForegroundColor Green
    Write-Host "`n提示: exe 未经代码签名，首次运行会触发 SmartScreen 警告；" -ForegroundColor Yellow
    Write-Host "      且因行为特征敏感，可能被杀软误报。" -ForegroundColor Yellow
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
