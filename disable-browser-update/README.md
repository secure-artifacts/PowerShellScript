# 浏览器自动更新管理工具

一个 PowerShell GUI 工具，用于禁用/恢复 Windows 上各浏览器的自动更新。

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue) ![Windows](https://img.shields.io/badge/Windows-10%2F11-lightgrey)

## 为什么不是「关掉更新服务」那么简单

网上流传的做法是打开 `services.msc`，把 `gupdate` / `gupdatem` 两个服务设为禁用。**这个方法现在基本失效了**，原因有三：

1. **服务名会变。** Chrome 早已改用新版 GoogleUpdater，服务名形如 `GoogleUpdaterService152.0.7933.0` —— **带更新器自身的版本号**，每次更新器自升级都会变。写死名字一个都匹配不到。

2. **光禁服务不够。** Chrome 启动时若发现更新器缺失，会自行重装，服务换个版本号又活了。必须同时写策略注册表才能真正兜住。

3. **有些浏览器根本没有更新服务。** 比如 Vivaldi，只靠计划任务检查更新，禁服务对它完全无效。

所以本工具采用三管齐下：

| 手段 | 作用 |
|---|---|
| **更新服务** | 停止并设为「禁用」（服务名用通配符匹配，兼容新旧更新器） |
| **计划任务** | 禁用（覆盖 Vivaldi 这类没有服务的浏览器） |
| **策略注册表** | 写 `Policies` 键，防止浏览器启动时重装更新器 |

## 支持的浏览器

| 浏览器 | 服务 | 计划任务 | 策略键 |
|---|---|---|---|
| Google Chrome | `gupdate` / `gupdatem` / `GoogleUpdater*Service*` | ✓ | `Policies\Google\Update` |
| Microsoft Edge | `edgeupdate` / `edgeupdatem` | ✓ | `Policies\Microsoft\EdgeUpdate` |
| Brave | `brave` / `bravem` | ✓ | `Policies\BraveSoftware\Update` |
| Mozilla Firefox | `MozillaMaintenance` | — | `Policies\Mozilla\Firefox` |
| Vivaldi | — | `VivaldiUpdateCheck*` | — |
| Opera | — | `Opera scheduled*` | — |
| Yandex Browser | `YandexBrowser*` | ✓ | `Policies\Yandex\Update` ⚠️ |

⚠️ Yandex 的策略键是按 Omaha 惯例推断的，**尚未实证**。Chrome / Edge / Brave 三家的策略键均已确认（Brave 的路径是通过扫描 `goopdate.dll` 中硬编码的字符串验证的）。

## 使用方法

双击 `启动.bat`，或者：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Disable-BrowserUpdate.ps1"
```

需要管理员权限，脚本会自动请求提权。

界面上会列出**已安装**的浏览器及其版本和当前状态：

- 🟢 **已禁用更新** —— 所有更新组件均已关闭
- 🔴 **更新开启中** —— 尚有组件在运行
- 🟠 **未发现组件** —— 探测不到更新机制（可能是浏览器换了新的更新方式，需要更新本工具的匹配规则）

勾选复选框，或直接点击行选中（Ctrl / Shift 可多选），然后点「禁用更新」或「恢复更新」。

## 可以还原

禁用前，每个服务和计划任务的原始状态会备份到：

```
%ProgramData%\DisableBrowserUpdate\backup.json
```

点「恢复更新」会按备份值还原（备份丢失时按厂商默认值兜底），并清除写入的策略项。如果策略键在清空后变成空壳，会一并删除，不会留下垃圾。

## 怎么确认真的生效了

打开浏览器的「关于」页面时，可能仍会弹出 UAC 提权框（比如 `Microsoft Edge Update`）。**这恰恰说明禁用生效了** —— 正常情况下更新检查由常驻服务静默完成，不弹框；服务被禁用后，浏览器只能退回到按需提权的更新器，于是才有了这个弹窗。点「否」即可。

要严格验证的话，看更新器记录的「最后成功检查」时间戳：

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\BraveSoftware\Update\ClientState' | ForEach-Object {
    $v = Get-ItemProperty $_.PSPath
    [pscustomobject]@{
        Ver  = $v.pv
        Last = [DateTimeOffset]::FromUnixTimeSeconds([int64]$v.LastCheckSuccess).ToLocalTime()
    }
}
```

在打开「关于」页面前后各跑一次，时间戳没变说明检查被拦住了。把路径中的 `BraveSoftware\Update` 换成 `Microsoft\EdgeUpdate` 可查 Edge。

> **注意**：Chrome 的新版 GoogleUpdater 不再往 `ClientState` 写这个值，改为记录在 `GoogleUpdater\updater.log` 中。

## 已知限制

- **「检查」和「安装」是两回事。** Omaha 系更新器对**用户主动发起**的检查是刻意豁免频率限制的，所以手动打开「关于」页面时仍会产生一次真实的网络检查。真正阻止**安装**的是 `UpdateDefault=0` 策略。
- **Edge 是 Windows 组件**，禁用更新后系统累积更新仍可能把它带回来。
- **Firefox 的更新控制完全依赖 `DisableAppUpdate` 策略。** 本工具不会去动 `Firefox Default Browser Agent` 计划任务 —— 那是默认浏览器检测的遥测任务，与更新无关。
- 提权服务（`*Elevation*`）已列入黑名单，永不禁用。它与更新无关，是浏览器安装/卸载时提权用的。

## ⚠️ 安全提示

长期不更新浏览器**有实质安全风险** —— 绝大多数在野漏洞利用都以浏览器为入口。本工具适合的场景是：

- 需要固定版本以保证自动化脚本 / 测试环境的一致性
- 需要避免版本变动破坏特定的扩展或工作流

如果只是嫌更新烦，**不建议长期禁用**。折中做法是禁用后定期手动检查。

## 打包成 exe

见 [`Build-Exe.ps1`](Build-Exe.ps1)，使用系统自带的 `csc.exe` 编译，不依赖任何第三方模块。

**但请先了解代价**：本脚本的行为特征（停用系统服务 + 禁用计划任务 + 改策略注册表 + 请求管理员权限）正好落在杀毒软件启发式规则的可疑区间。打包成未签名的 exe 后，被 Defender 拦截或触发 SmartScreen 警告的概率相当高。**以明文 `.ps1` 运行反而更顺畅**，因为脚本是可审查的。

如果只是自用，更推荐建一个指向 `powershell.exe` 的快捷方式（属性里勾选「以管理员身份运行」），体验与 exe 几乎无异，且零风险。

## 授权

MIT
