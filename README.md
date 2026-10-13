# 西电校园网自动登录

Windows 校园网自动认证小工具，适配西安电子科技大学 `w.xidian.edu.cn` 的深澜 SRun 认证。连接校园 Wi-Fi 后检测认证状态，在换位置或认证失效时自动登录。Clash Party / Mihomo TUN 可以保持开启。

![设置窗口，账号信息为空](docs/settings.png)

## 使用

需要 Windows 10/11 和 **PowerShell 7.4 或更新版本（.NET 8+）**。

1. 下载项目或 `git clone`，在 PowerShell 7 中运行安装脚本，例如：

   ```powershell
   ./Install.ps1 -Destination D:\XidianCampusLogin
   ```

2. 在本地设置窗口填写学校网页所使用的上网账号、密码，点击“保存设置”。密码不需要写入源码。
3. 默认 SSID 为 `stu-xdwlan`。多个校园 SSID 用英文逗号分隔；只添加可信的校园 Wi-Fi。
4. 点击“转为后台”或关闭窗口即可隐藏设置窗口。程序继续自动认证，登录 Windows 后自动在后台启动。

安装会编译 `CampusLogin.exe`，并创建桌面和开始菜单的“西电校园网自动登录”入口。启动入口和计划任务直接运行这个 Windows GUI 程序；后台 PowerShell 和网络检查命令均使用 `CreateNoWindow` 启动，不创建终端。即使完全隐藏图标，点击入口也能唤回已经运行的窗口，不会产生重复的认证进程。手动打开程序请使用快捷方式或 `CampusLogin.exe`；`Start.cmd` 保留为命令行兼容入口。

安装脚本会将 PowerShell 7 运行环境复制到安装目录的 `runtime/`，开机运行不再依赖 Codex 的缓存。这个目录不提交到 GitHub。`Launch.ps1` 优先使用独立运行环境，也兼容标准 PowerShell 7 安装及现有 Codex 附带的运行环境。可从 [PowerShell 官方安装文档](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) 安装 PowerShell 7。

## 界面与后台运行

- 根据显示 DPI 和字体自动排版，支持缩放及窗口大小变化。文字自动换行，窄窗口时按钮换行，空间不足时可滚动。
- **在任务栏显示图标**：控制设置窗口打开时的任务栏入口。
- **显示托盘图标**：控制右下角通知区域图标。关闭该选项仍会进行后台认证，可从开始菜单重新打开设置。
- **登录 Windows 后在后台启动**：安装当前用户的启动入口与计划任务，在登录、休眠恢复时启动守护进程。允许电池供电，没有运行时长上限，也不要求 Windows 先判断网络已可用。
- **退出程序**：停止窗口及后台认证。右上角关闭按钮只隐藏窗口。
- 守护进程等待子进程退出通知，窗口或检测进程异常退出后恢复它们。计划任务管理常驻守护进程，只包含登录和恢复唤醒触发，没有每分钟保活任务；守护进程失败时才由 Windows 按失败重启规则恢复。各进程使用互斥锁避免重复运行。主动点击“退出程序”会停止恢复，重新打开程序或下次登录 Windows 时恢复运行。
- 如果系统禁止当前用户创建计划任务，会保留启动入口并在 `autostart-state.json` 中记录 `StartupOnly`；此模式不能保证守护进程自身退出后的恢复。

## 认证与代理直连

开机、恢复唤醒、Wi-Fi/IP/联网状态变化以及手动请求会触发检查。Windows 连接变化和恢复通知直接唤醒等待线程；确认联网后不再定时访问网站、不执行网络命令、不定时写心跳文件。没有校园 Wi-Fi、暂停认证或缺少账号时也等待事件。只有已连接校园网但仍无法正常使用时，才安排有退避间隔的恢复重试。界面通过文件变化通知更新，守护进程通过子进程退出通知恢复，不使用空闲轮询。

认证区域从学校实际返回的跳转页面获取，包括 HTTP 重定向、网页脚本、以及 HTTP 200 页面中自动提交到 `index_N.html` 的表单。读取对应区域的 `ac_id`，避免访问门户首页后误用默认区域 1。程序缓存当前 SSID、IP 和网关下的已确认入口；新跳转优先，IP 或网关改变后重新识别。不能识别入口时会明确显示状态，不猜测区域编号。

学校在线状态与直连外网检测分别核对。旧在线记录仍被跳转到认证页时重新认证；若学校明确返回“IP 已在线”，仅在在线账号、IP 都与本机配置一致时更新该失效会话。普通外网故障显示为连接受限，继续检测，不显示为联网成功。

DNS 和 HTTPS TCP 套接字使用当前校园网物理网卡，并设置 Windows `IP_UNICAST_IF`。HTTP 客户端关闭系统代理，DNS 直接查询校园网卡下发的服务器。程序不改动全局代理、Clash 配置、hosts 或系统路由表。

只向 `https://w.xidian.edu.cn` 提交账号信息，保留 HTTPS 证书校验。程序读取学校页面的当前 `acid` 与 IP，使用学校页面对应的 challenge、HMAC-MD5、SRBX1 和 SHA-1 协议。登录后再次核对学校在线状态，并进行校园网卡直连外网检测。

认证失败后按 60、120、240、480、900 秒退避。明确的账号、余额或在线设备数错误会暂停自动提交；未知网关错误仍会重试。保存设置或点击“立即检测”可以手动重试。

程序负责连接校园 Wi-Fi 后的网页认证，Wi-Fi 的连接和漫游由 Windows 管理。浏览器自行打开的认证页面仍按浏览器及代理软件原配置访问。

## 本地数据

程序目录下的 `data/` 保存本机设置、状态和日志：

| 文件 | 用途 |
| --- | --- |
| `settings.json` | 账号、Windows 用户加密的密码、SSID 与图标选项 |
| `status.json` | 校园网检测状态 |
| `ui-state.json` | 窗口和图标状态，仅启动及可见性改变时更新 |
| `supervisor-state.json` / `supervisor.log` | 守护进程启动信息和进程恢复记录，不定时写心跳 |
| `event-subscriptions.json` | Windows 恢复、连接状态及 Wi-Fi 事件订阅结果 |
| `autostart-state.json` / `startup.log` | 自启模式与启动失败类型 |
| `portal-route.json` | 当前网络的认证区域入口 |
| `last-auth-result.json` / `diagnostic.log` | 认证结果代码、失败阶段与异常类型，不保存认证请求地址或密码 |
| `activity.log` | 状态变化日志，不记录账号、密码或认证请求地址 |

安装时会限制数据目录权限。密码通过当前 Windows 用户的 DPAPI 加密，本用户权限下的其他程序仍可能解密。`data/` 已加入 `.gitignore`，不要手动将配置或日志提交到公开仓库。

从旧版更新时，安装脚本会在目标目录没有配置的情况下迁移 `%LOCALAPPDATA%\XidianCampusLogin` 中已有的配置和日志；迁移后密码仍由原 Windows 用户使用。不要把一个用户的加密密码作为共享配置分发。

## 检测与测试

独立只读诊断（先从设置窗口退出后台程序）：

```powershell
./Monitor.ps1 -Diagnose
```

运行回归检查：

```powershell
./tests/Test.ps1
# 无交互桌面的环境
./tests/Test.ps1 -SkipUi
```

检查包括 GUI 可执行文件的 PE 子系统、真实子进程的零控制台窗口句柄、原生命令输出读取、重复恢复触发、真实 Windows PowerShell 5.1 兼容入口、协议测试向量、认证区域表单与跳转解析、区域缓存失效、JSONP 时间戳、旧版设置兼容、图标设置保存、Windows 密码加密和布局尺寸。模拟网络测试覆盖掉线认证、两小时休眠恢复、旧在线记录、失效会话更新、外网故障、错误退避与诊断信息脱敏。测试均使用虚构账号和密码，不会提交校园网登录。

2026-10-13 在用户授权下进行了真实注销与自动重新认证：Clash Party / Mihomo TUN 保持开启，学校返回 `login_ok`，再次确认在线状态和直连外网恢复，一次完整测试用时约 18 秒。也实际验证了检测程序、窗口和守护进程被结束后的恢复。真实跨区域漫游以及合盖两小时后的完整场景尚需自然使用验证；休眠间隔及入口变化已通过模拟回归检查。

此次修复的两个实际故障：Windows PowerShell 5.1 将旧启动脚本的无 BOM 中文误读为语法错误，导致开机未启动；检测程序没有读取学校 HTTP 200 自动提交表单，实际区域 8 被误当作默认区域 1。启动脚本现在仅含 ASCII，并对系统入口单独测试。

## 停用

取消“登录 Windows 后在后台启动”并保存，再点击“退出程序”。之后可移除程序目录及桌面、开始菜单快捷方式。删除 `data/` 会同时删除本地账号配置。

Windows 接口参考：[IPPROTO_IP socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options)。

2026-10-13 终端闪窗及空闲活动修复：删除每分钟保活任务、固定网络轮询和界面心跳轮询，改用系统事件和进程退出事件。后台启动使用 GUI 子系统入口与 `CreateNoWindow`，自动启动失败只记录错误类型。测试运行真实后台进程，使用合成网络结果，在超过旧检测间隔的 20 秒空闲期内确认状态与日志没有写入；也验证了进程退出恢复和手动请求唤醒。修复已安装到本机 D 盘，实际计划任务没有周期触发，恢复、Wi-Fi 及联网状态通知均订阅成功。在真实已联网状态下观察 45 秒，状态和日志没有写入，三个后台进程合计 CPU 时间约 0.03 秒，窗口保持隐藏。尚未在真实重启、合盖两小时以及游戏场景中验证，也未测量实际电池耗电。

Windows 事件及无控制台启动参考：[网络连接变化](https://learn.microsoft.com/en-us/windows/win32/api/netlistmgr/nn-netlistmgr-inetworkconnectionevents)、[恢复唤醒](https://learn.microsoft.com/en-us/windows/win32/api/powerbase/nf-powerbase-powerregistersuspendresumenotification)、[进程创建标志](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags)。
