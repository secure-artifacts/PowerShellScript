<#
.SYNOPSIS
    浏览器自动更新管理工具（GUI）

.DESCRIPTION
    通过三种手段禁用/恢复浏览器自动更新：
      1. 更新服务      —— 停止并设为「禁用」（等价于 services.msc 里手工操作）
      2. 计划任务      —— 禁用（有些浏览器如 Vivaldi 只有任务、没有服务）
      3. 策略注册表    —— 写 Policies 键，防止浏览器启动时重装更新器

    支持 Chrome / Edge / Brave / Firefox / Vivaldi / Opera / Yandex。
    原始状态会备份到 %ProgramData%\DisableBrowserUpdate\backup.json，可完整还原。

.NOTES
    需要管理员权限，脚本会自动请求提权。
#>

# ---------------------------------------------------------------- 提权
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        # -WindowStyle Hidden 必须传给提权后的实例，否则会多出一个空的控制台窗口挡在 GUI 后面
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`""
        )
    } catch {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        [System.Windows.Forms.MessageBox]::Show('本工具需要管理员权限运行。', '权限不足')
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:BackupDir  = Join-Path $env:ProgramData 'DisableBrowserUpdate'
$script:BackupFile = Join-Path $script:BackupDir 'backup.json'

# ---------------------------------------------------------------- 浏览器定义
# ServicePatterns / TaskPatterns 支持通配符 —— 新版 GoogleUpdater 的服务名带版本号，
# 每次更新器自升级都会变，所以必须用通配符而不是写死 gupdate / gupdatem。
$script:Browsers = @(
    @{
        Name            = 'Google Chrome'
        ExePaths        = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        )
        ServicePatterns = @('gupdate', 'gupdatem', 'GoogleUpdaterService*', 'GoogleUpdaterInternalService*')
        TaskPatterns    = @('GoogleUpdateTaskMachine*', 'GoogleUpdaterTask*')
        PolicyKey       = 'HKLM:\SOFTWARE\Policies\Google\Update'
        PolicyValues    = @{
            'UpdateDefault'                              = 0   # 0 = 完全禁止更新
            'AutoUpdateCheckPeriodMinutes'               = 0   # 0 = 不做周期性检查
            'DisableAutoUpdateChecksCheckboxValue'       = 1
            'Update{8A69D345-D564-463C-AFF1-A69D9E530F96}' = 0 # Chrome 的 AppID
        }
    }
    @{
        Name            = 'Microsoft Edge'
        ExePaths        = @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        )
        ServicePatterns = @('edgeupdate', 'edgeupdatem')
        TaskPatterns    = @('MicrosoftEdgeUpdateTask*')
        PolicyKey       = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
        PolicyValues    = @{
            'UpdateDefault'                              = 0
            'AutoUpdateCheckPeriodMinutes'               = 0
            'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' = 0 # Edge Stable 的 AppID
        }
    }
    @{
        Name            = 'Brave'
        ExePaths        = @(
            "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe"
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe"
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
        )
        ServicePatterns = @('brave', 'bravem', 'BraveUpdate*')
        TaskPatterns    = @('BraveSoftwareUpdateTask*')
        # 已实证：该路径硬编码在 goopdate.dll（Brave 的 Omaha 分支核心）及全部更新器二进制中，
        # UpdateDefault / AutoUpdateCheckPeriodMinutes 两个值名也在 goopdate.dll 内命中。
        PolicyKey       = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Update'
        PolicyValues    = @{
            'UpdateDefault'                = 0
            'AutoUpdateCheckPeriodMinutes' = 0
            # Brave Browser Stable 的 Omaha AppID（本机 Download 目录名与官方 wiki 双向印证）
            'Update{AFE6A462-C574-4B8A-AF43-4CC60DF4563B}' = 0
        }
    }
    @{
        Name            = 'Mozilla Firefox'
        NamePattern     = '^Mozilla Firefox'          # DisplayName 带语言/位数后缀，如「Mozilla Firefox (x64 zh-CN)」
        ExePaths        = @(
            "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
            "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
        )
        ServicePatterns = @('MozillaMaintenance')
        TaskPatterns    = @('Firefox Default Browser Agent*')
        PolicyKey       = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
        PolicyValues    = @{
            'DisableAppUpdate' = 1
        }
    }
    @{
        Name            = 'Vivaldi'
        ExePaths        = @(
            "$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe"
            "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe"
        )
        ServicePatterns = @()                      # Vivaldi 没有更新服务
        TaskPatterns    = @('VivaldiUpdateCheck*') # 只靠计划任务检查更新
        PolicyKey       = $null
        PolicyValues    = @{}
    }
    @{
        Name            = 'Opera'
        NamePattern     = '^Opera(\s+Stable)?\s'      # DisplayName 形如「Opera Stable 1xx.x.x.x」
        ExePaths        = @(
            "$env:LOCALAPPDATA\Programs\Opera\opera.exe"
            "$env:ProgramFiles\Opera\opera.exe"
            "${env:ProgramFiles(x86)}\Opera\opera.exe"
        )
        ServicePatterns = @()
        TaskPatterns    = @('Opera scheduled*')
        PolicyKey       = $null
        PolicyValues    = @{}
    }
    @{
        Name            = 'Yandex Browser'
        NamePattern     = '^Yandex|^Яндекс'          # 系统级安装时 DisplayName 是「Yandex (All Users)」
        ExePaths        = @(
            "$env:ProgramFiles\Yandex\YandexBrowser\Application\browser.exe"
            "${env:ProgramFiles(x86)}\Yandex\YandexBrowser\Application\browser.exe"
            "$env:LOCALAPPDATA\Yandex\YandexBrowser\Application\browser.exe"
        )
        # 服务实际叫 YandexBrowserService，不带 Update 字样
        ServicePatterns = @('YandexBrowser*', 'Yandex*Update*')
        TaskPatterns    = @('*Yandex Browser*', 'YandexBrowserUpdate*')
        # 未经验证：Yandex 更新器同为 Omaha 分支，键名按惯例推断，尚未实证
        PolicyKey       = 'HKLM:\SOFTWARE\Policies\Yandex\Update'
        PolicyValues    = @{
            'UpdateDefault'                = 0
            'AutoUpdateCheckPeriodMinutes' = 0
        }
    }
)

# ---------------------------------------------------------------- 备份 / 还原
function Get-Backup {
    if (Test-Path $script:BackupFile) {
        try {
            $obj = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $ht = @{}
            foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
            return $ht
        } catch { return @{} }
    }
    return @{}
}

function Save-Backup([hashtable]$Data) {
    if (-not (Test-Path $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $Data | ConvertTo-Json -Depth 5 | Out-File $script:BackupFile -Encoding utf8 -Force
}

# ---------------------------------------------------------------- 探测
function Get-BrowserVersion($Browser) {
    foreach ($p in $Browser.ExePaths) {
        if ($p -and (Test-Path $p)) {
            $v = (Get-Item $p).VersionInfo.ProductVersion
            if ($v) { return $v.Trim() }
        }
    }
    # 装在非标准路径时回退查注册表
    $uninstall = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    # DisplayName 常带后缀（如「Yandex (All Users)」），所以用 NamePattern 正则而非精确匹配。
    # 模式必须锚定，否则 'Microsoft Edge' 会误匹配到 'Microsoft Edge WebView2 Runtime'。
    $pattern = if ($Browser.NamePattern) { $Browser.NamePattern }
               else { '^' + [regex]::Escape($Browser.Name) + '$' }
    $hit = Get-ItemProperty $uninstall -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -match $pattern -and $_.DisplayVersion } |
           Sort-Object DisplayVersion -Descending | Select-Object -First 1
    if ($hit) { return $hit.DisplayVersion }
    return $null
}

function Get-BrowserServices($Browser) {
    $found = @()
    foreach ($pat in $Browser.ServicePatterns) {
        $found += Get-Service -Name $pat -ErrorAction SilentlyContinue
    }
    return $found | Sort-Object Name -Unique
}

function Get-BrowserTasks($Browser) {
    $found = @()
    foreach ($pat in $Browser.TaskPatterns) {
        $found += Get-ScheduledTask -TaskName $pat -ErrorAction SilentlyContinue
    }
    return $found | Sort-Object TaskName -Unique
}

function Test-PolicyApplied($Browser) {
    if (-not $Browser.PolicyKey) { return $null }   # 该浏览器没有策略支持
    if (-not (Test-Path $Browser.PolicyKey)) { return $false }
    foreach ($name in $Browser.PolicyValues.Keys) {
        $cur = (Get-ItemProperty -Path $Browser.PolicyKey -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -eq $cur -or $cur -ne $Browser.PolicyValues[$name]) { return $false }
    }
    return $true
}

function Get-BrowserStatus($Browser) {
    $version = Get-BrowserVersion $Browser
    if (-not $version) {
        return [pscustomobject]@{
            Name = $Browser.Name; Version = '-'; Installed = $false
            Status = '未安装'; Detail = ''
        }
    }

    $svcs   = @(Get-BrowserServices $Browser)
    $tasks  = @(Get-BrowserTasks   $Browser)
    $policy = Test-PolicyApplied $Browser

    $svcOn  = @($svcs  | Where-Object { $_.StartType -ne 'Disabled' }).Count
    $taskOn = @($tasks | Where-Object { $_.State     -ne 'Disabled' }).Count

    $parts = @()
    if ($svcs.Count)  { $parts += "服务 $($svcs.Count - $svcOn)/$($svcs.Count) 已禁用" }
    if ($tasks.Count) { $parts += "任务 $($tasks.Count - $taskOn)/$($tasks.Count) 已禁用" }
    if ($null -ne $policy) { $parts += $(if ($policy) { '策略已生效' } else { '策略未设置' }) }
    if (-not $parts.Count) { $parts += '未发现更新组件' }

    # 必须真的找到了组件才能判定「已禁用」。否则「一个组件都没找到」会被误判成已禁用，
    # 而实际上更可能是探测模式没覆盖到（比如浏览器换了新的更新机制）。
    $hasComponents = ($svcs.Count -gt 0) -or ($tasks.Count -gt 0) -or ($null -ne $policy)
    $blocked = $hasComponents -and ($svcOn -eq 0) -and ($taskOn -eq 0) -and ($policy -ne $false)
    $status  = if (-not $hasComponents) { '未发现组件' }
               elseif ($blocked)        { '已禁用更新' }
               else                     { '更新开启中' }

    return [pscustomobject]@{
        Name = $Browser.Name; Version = $version; Installed = $true
        Status = $status; Detail = ($parts -join '，')
    }
}

# ---------------------------------------------------------------- 执行
function Set-BrowserUpdate($Browser, [bool]$Disable, [System.Collections.ArrayList]$Log) {
    $backup = Get-Backup

    # --- 1. 服务
    foreach ($svc in Get-BrowserServices $Browser) {
        $key = "svc:$($svc.Name)"
        try {
            if ($Disable) {
                if (-not $backup.ContainsKey($key)) { $backup[$key] = [string]$svc.StartType }
                if ($svc.Status -ne 'Stopped') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                }
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                [void]$Log.Add("  [服务] $($svc.Name) -> 已停止并禁用")
            } else {
                # 没有备份记录时按厂商默认值还原：主服务 Automatic，带 m 后缀的辅助服务 Manual
                # 实测各厂商默认值：gupdatem / edgeupdatem / bravem 是 Manual，
                # MozillaMaintenance 是 Manual，其余（含 GoogleUpdaterInternalService）都是 Automatic。
                $orig = if ($backup.ContainsKey($key)) { $backup[$key] }
                        elseif ($svc.Name -match 'm$|Maintenance$') { 'Manual' } else { 'Automatic' }
                Set-Service -Name $svc.Name -StartupType $orig -ErrorAction Stop
                [void]$Log.Add("  [服务] $($svc.Name) -> 恢复为 $orig")
            }
        } catch {
            [void]$Log.Add("  [服务] $($svc.Name) 失败：$($_.Exception.Message)")
        }
    }

    # --- 2. 计划任务
    foreach ($task in Get-BrowserTasks $Browser) {
        $key = "task:$($task.TaskPath)$($task.TaskName)"
        try {
            if ($Disable) {
                if (-not $backup.ContainsKey($key)) { $backup[$key] = [string]$task.State }
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
                [void]$Log.Add("  [任务] $($task.TaskName) -> 已禁用")
            } else {
                Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
                [void]$Log.Add("  [任务] $($task.TaskName) -> 已启用")
            }
        } catch {
            [void]$Log.Add("  [任务] $($task.TaskName) 失败：$($_.Exception.Message)")
        }
    }

    # --- 3. 策略注册表（关键：防止浏览器启动时重装更新器）
    if ($Browser.PolicyKey) {
        try {
            if ($Disable) {
                if (-not (Test-Path $Browser.PolicyKey)) {
                    New-Item -Path $Browser.PolicyKey -Force | Out-Null
                }
                foreach ($n in $Browser.PolicyValues.Keys) {
                    New-ItemProperty -Path $Browser.PolicyKey -Name $n `
                        -Value $Browser.PolicyValues[$n] -PropertyType DWord -Force | Out-Null
                }
                [void]$Log.Add("  [策略] $($Browser.PolicyKey) -> 已写入 $($Browser.PolicyValues.Count) 项")
            } else {
                if (Test-Path $Browser.PolicyKey) {
                    foreach ($n in $Browser.PolicyValues.Keys) {
                        Remove-ItemProperty -Path $Browser.PolicyKey -Name $n -ErrorAction SilentlyContinue
                    }
                    [void]$Log.Add("  [策略] $($Browser.PolicyKey) -> 已清除")
                }
            }
        } catch {
            [void]$Log.Add("  [策略] 失败：$($_.Exception.Message)")
        }
    }

    Save-Backup $backup
}

# ---------------------------------------------------------------- GUI
$form = New-Object System.Windows.Forms.Form
$form.Text          = '浏览器自动更新管理工具'
$form.Size          = New-Object System.Drawing.Size(820, 560)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$list = New-Object System.Windows.Forms.ListView
$list.Location      = New-Object System.Drawing.Point(12, 12)
$list.Size          = New-Object System.Drawing.Size(780, 210)
$list.View          = 'Details'
$list.CheckBoxes    = $true
$list.FullRowSelect = $true
$list.GridLines     = $true
$list.MultiSelect   = $true
$list.HideSelection = $false   # 焦点移到按钮上时仍保持选中行高亮，否则看不出操作对象
[void]$list.Columns.Add('浏览器',   150)
[void]$list.Columns.Add('版本',     140)
[void]$list.Columns.Add('当前状态', 110)
[void]$list.Columns.Add('更新组件', 355)
$form.Controls.Add($list)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location   = New-Object System.Drawing.Point(12, 275)
$logBox.Size       = New-Object System.Drawing.Size(780, 195)
$logBox.Multiline  = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly   = $true
$logBox.Font       = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

$status = New-Object System.Windows.Forms.Label
$status.Location  = New-Object System.Drawing.Point(12, 480)
$status.Size      = New-Object System.Drawing.Size(780, 20)
$status.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($status)

function Add-Log([string]$Text) {
    $logBox.AppendText($Text + "`r`n")
}

function Refresh-List {
    $list.Items.Clear()
    $status.Text = '正在检测...'
    $form.Refresh()
    foreach ($b in $script:Browsers) {
        $s = Get-BrowserStatus $b
        if (-not $s.Installed) { continue }   # 只显示已安装的
        $item = New-Object System.Windows.Forms.ListViewItem($s.Name)
        [void]$item.SubItems.Add($s.Version)
        [void]$item.SubItems.Add($s.Status)
        [void]$item.SubItems.Add($s.Detail)
        $item.ForeColor = switch ($s.Status) {
            '已禁用更新' { [System.Drawing.Color]::ForestGreen }
            '未发现组件' { [System.Drawing.Color]::DarkOrange }   # 探测不到，既非成功也非失败
            default      { [System.Drawing.Color]::Firebrick }
        }
        $item.Tag = $b
        [void]$list.Items.Add($item)
    }
    Update-Hint
}

# 实时提示当前会对哪些浏览器生效，避免「以为选了其实没选」
function Update-Hint {
    $n = $list.Items.Count
    $targets = @(Get-TargetItems)
    if (-not $targets.Count) {
        $status.Text = "检测到 $n 个已安装的浏览器。勾选复选框，或直接点击行选中（Ctrl / Shift 可多选）。"
    } else {
        $from = if (@($list.CheckedItems).Count) { '已勾选' } else { '当前选中' }
        $status.Text = "检测到 $n 个浏览器；将对$from 的 $($targets.Count) 项生效：" +
                       (($targets | ForEach-Object { $_.Text }) -join '、')
    }
}

# 操作对象：优先取已勾选项；一个都没勾时退回到当前选中行。
# 用「优先」而非「合并」，是为了避免已勾选状态下点击其他行查看详情时误连带操作。
function Get-TargetItems {
    $checked = @($list.CheckedItems)
    if ($checked.Count) { return $checked }
    return @($list.SelectedItems)
}

function Invoke-Action([bool]$Disable) {
    $targets = @(Get-TargetItems)
    if (-not $targets.Count) {
        [System.Windows.Forms.MessageBox]::Show(
            '请先勾选，或直接点击选中要操作的浏览器。', '提示') | Out-Null
        return
    }
    $verb = if ($Disable) { '禁用' } else { '恢复' }
    $from = if (@($list.CheckedItems).Count) { '已勾选' } else { '当前选中' }
    $names = ($targets | ForEach-Object { '  · ' + $_.Text }) -join "`r`n"
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "确定要$verb 以下$from 浏览器的自动更新？`r`n`r`n$names",
        "确认$verb", 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $log = New-Object System.Collections.ArrayList
    foreach ($item in $targets) {
        [void]$log.Add("【$($item.Text)】$verb 中...")
        Set-BrowserUpdate -Browser $item.Tag -Disable $Disable -Log $log
    }
    [void]$log.Add("---- 完成 ----`r`n")
    Add-Log ($log -join "`r`n")
    Refresh-List
}

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text     = '刷新检测'
$btnRefresh.Location = New-Object System.Drawing.Point(12, 234)
$btnRefresh.Size     = New-Object System.Drawing.Size(100, 32)
$btnRefresh.Add_Click({ Refresh-List })
$form.Controls.Add($btnRefresh)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text     = '全选 / 全不选'
$btnAll.Location = New-Object System.Drawing.Point(120, 234)
$btnAll.Size     = New-Object System.Drawing.Size(110, 32)
$btnAll.Add_Click({
    $target = @($list.CheckedItems).Count -lt $list.Items.Count
    foreach ($i in $list.Items) { $i.Checked = $target }
})
$form.Controls.Add($btnAll)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text      = '禁用更新'
$btnDisable.Location  = New-Object System.Drawing.Point(560, 234)
$btnDisable.Size      = New-Object System.Drawing.Size(110, 32)
$btnDisable.BackColor = [System.Drawing.Color]::MistyRose
$btnDisable.Add_Click({ Invoke-Action $true })
$form.Controls.Add($btnDisable)

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Text      = '恢复更新'
$btnEnable.Location  = New-Object System.Drawing.Point(682, 234)
$btnEnable.Size      = New-Object System.Drawing.Size(110, 32)
$btnEnable.BackColor = [System.Drawing.Color]::Honeydew
$btnEnable.Add_Click({ Invoke-Action $false })
$form.Controls.Add($btnEnable)

$list.Add_ItemChecked({ Update-Hint })
$list.Add_SelectedIndexChanged({ Update-Hint })

$form.Add_Shown({ $form.Activate(); Refresh-List })
[void]$form.ShowDialog()
