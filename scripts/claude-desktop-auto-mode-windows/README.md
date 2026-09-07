# Claude Desktop 3P Auto Mode（Windows）

让 Claude Desktop 当前启用的第三方 Gateway profile 持续包含：

```json
"autoModeEnabled": true
```

适用于 CC Switch 本地路由和其他 Claude Desktop 3P Gateway。脚本通过
`configLibrary/_meta.json` 动态查找当前 profile，不绑定 profile ID、中转地址、
端口、API Key 或模型名称。

## 安装

在普通 PowerShell 中执行：

```powershell
.\claude-desktop-auto-mode.ps1 self-test
.\claude-desktop-auto-mode.ps1 install
```

安装操作会：

1. 将运行副本复制到 `%LOCALAPPDATA%\CCSwitchClaudeAutoMode`。
2. 创建当前用户登录启动项 `CCSwitchClaudeDesktopAutoMode`。
3. 立即修复当前 profile 并启动文件变化监听。

不需要管理员权限，也不会设置 `HKCU\SOFTWARE\Policies\Claude`。

## 查看状态

```powershell
.\claude-desktop-auto-mode.ps1 status
```

`AutoMode` 的常见值：

- `AlreadyEnabled`：当前 3P profile 已启用 Auto。
- `NeedsUpdate`：当前 3P profile 尚未启用 Auto；安装后会自动修复。
- `Updated`：本次检查已补入 Auto 字段。
- `NoActiveProfile`：当前没有启用 3P profile，通常表示正在使用官方模式。
- `NotGateway`：当前 profile 不是 Gateway，脚本不会修改。
- `Busy`：配置正在被其他程序写入，后台监听会自动重试。

## 卸载

```powershell
.\claude-desktop-auto-mode.ps1 uninstall
```

卸载只删除登录启动项和本机运行副本，不删除或改回 Claude Desktop profile。

## 工作边界

- 更换中转、端口、API Key 或模型后仍然有效。
- CC Switch 重写当前 profile 后会自动补回字段。
- 切到 Claude 官方模式时不执行任何修改。
- 保证 Auto 选项可用，不负责为每个新会话预选 Auto。
- 如果 Claude Desktop 将来更换 3P 配置目录或废弃 `autoModeEnabled` 字段，脚本需要同步更新。
