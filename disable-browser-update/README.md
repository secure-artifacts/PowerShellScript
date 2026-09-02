# 浏览器自动更新管理工具

一个 PowerShell GUI 工具，用于禁用/恢复 Windows 上各浏览器的自动更新。

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue) ![Windows](https://img.shields.io/badge/Windows-10%2F11-lightgrey)

## 为什么不是「关掉更新服务」那么简单

网上流传的做法是打开 `services.msc`，把 `gupdate` / `gupdatem` 两个服务设为禁用。**这个方法现在基本失效了**，原因有三：

1. **服务名会变。** Chrome 早已改用新版 GoogleUpdater，服务名形如 `GoogleUpdaterService152.0.7933.0` —— **带更新器自身的版本号**，每次更新器自升级都会变。写死名字一个都匹配不到。

2. **光禁服务不够。** Chrome 启动时若发现更新器缺失，会自行重装，服务换个版本号又活了。必须同时写策略注册表才能真正兜住。

3. **触发点不止一个。** 光禁服务，浏览器还有计划任务、按需更新器等其它路径能拉起更新，必须一并处理。

所以本工具采用三管齐下：

| 手段 | 作用 |
|---|---|
| **更新服务** | 停止并设为「禁用」（服务名用通配符匹配，兼容新旧更新器） |
| **计划任务** | 禁用每用户 / 机器级的更新检查任务 |
| **策略注册表** | 写 `Policies` 键，防止浏览器启动时重装更新器 |

## 支持的浏览器

| 浏览器 | 服务 | 计划任务 | 策略键 |
|---|---|---|---|
| Google Chrome | `gupdate` / `gupdatem` / `GoogleUpdater*Service*` | ✓ | `Policies\Google\Update` |
| Microsoft Edge | `edgeupdate` / `edgeupdatem` | ✓ | `Policies\Microsoft\EdgeUpdate` |
| Brave | `brave` / `bravem` | ✓ | `Policies\BraveSoftware\Update` |
| Vivaldi | —（无更新服务） | `VivaldiUpdateCheck*` | —（无策略键） |

Chrome / Edge / Brave 三家的策略键均已确认有效（Brave 的路径是通过扫描 `goopdate.dll` 中硬编码的字符串验证的）。Vivaldi 没有更新服务、也没有策略键，只靠禁用计划任务拦截更新检查。

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

## 已知限制

- **用户级安装的手动更新拦不住。** 界面「安装范围」列会标出每个浏览器是**系统级**还是**用户级**：
  - **系统级**（装在 `Program Files`，需管理员安装）—— 策略 `UpdateDefault=0` 生效，后台和手动更新都能锁死。打开「关于」页面会显示「更新已被管理员禁用」。
  - **用户级**（装在 `%LOCALAPPDATA%`，免管理员安装）—— 后台自动更新能被禁用任务拦住，但**手动打开「关于」页面触发的更新拦不住**（那条按需路径不认机器级策略）。
  - 若要彻底锁定用户级浏览器，把它**卸载后以管理员重装成系统级**（见下方安装说明），或改用 ACL 硬锁。
- **「检查」和「安装」是两回事。** 系统级下 `UpdateDefault=0` 会挡住安装（即使手动检查也会显示「已被管理员禁用」）。
- **Edge 是 Windows 组件**，禁用更新后系统累积更新仍可能把它带回来。
- 提权服务（`*Elevation*`）已列入黑名单，永不禁用。它与更新无关，是浏览器安装/卸载时提权用的。

## 装成系统级（推荐）

用户级安装是因为当初没用管理员权限装。要彻底锁定，用管理员重装成系统级：

```powershell
# 先在 设置 → 应用 里卸载现有 Brave（数据保留在 %LOCALAPPDATA%，不受影响）
# 再用管理员 PowerShell 装系统级：
winget install --id Brave.Brave --exact --scope machine
```

装完验证 `Test-Path 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'` 返回 `True` 即为系统级。Chrome / Edge 同理（`--scope machine`）。

## ⚠️ 安全提示

长期不更新浏览器**有实质安全风险** —— 绝大多数在野漏洞利用都以浏览器为入口。本工具适合的场景是：

- 需要固定版本以保证自动化脚本 / 测试环境的一致性
- 需要避免版本变动破坏特定的扩展或工作流

如果只是嫌更新烦，**不建议长期禁用**。折中做法是禁用后定期手动检查。

## 授权

MIT
