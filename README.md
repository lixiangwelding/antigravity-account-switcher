# Antigravity Account Switcher

macOS 菜单栏反重力（Google Antigravity）多账号切换器，一比一移植自 [jieguangzhou/CodexSwitcher](https://github.com/jieguangzhou/CodexSwitcher)（Codex 版），把 Codex 的 auth.json 机制替换为 Antigravity 的凭据机制。

## 功能（与 CodexSwitcher 对齐）

- 菜单栏一键切换反重力账号（AI 小人图标，配额低会变累/躺平 + 系统通知）
- 所有账号的 5小时 / 7天 配额进度条 + 重置时间
- 自动同步：在 Antigravity 里登录新 Google 账号后自动入库（监听凭据变化）
- 低配额告警（阈值可在设置里调）
- 开机自启、刷新间隔、切换后自动重启 Antigravity 均可配置

## 构建 / 运行

```bash
bash build.sh
open "build/Antigravity Switcher.app"
```

## 原理

| | CodexSwitcher（原版） | 本项目（反重力版） |
|---|---|---|
| 活动凭据 | `~/.codex/auth.json` | 钥匙串 `gemini/antigravity`（go-keyring-base64）+ `~/.gemini/jetski-standalone-oauth-token`（双写） |
| 账号库 | `~/.codex/accounts/*.json` | `~/.antigravity-switcher/accounts/*.json`（token 快照 + `.meta.json` 存邮箱） |
| 账号名 | id_token JWT 里的 email | userinfo API（`oauth2/v2/userinfo`）解析邮箱，自动改名成邮箱前缀 |
| 用量接口 | `chatgpt.com/backend-api/wham/usage` | `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`（UA: antigravity） |
| token 刷新 | 无需（JWT 长效） | refresh_token + Antigravity 同款公共 OAuth client 换新 access_token |
| 生效方式 | 立即（CLI 每次读文件） | 退出 Antigravity → 换凭据 → 重启（设置里可关） |

配置文件：`~/.antigravity-switcher/config.json`。

## 注意

- 第一次切换后，Antigravity 读钥匙串可能弹一次授权确认，点「始终允许」即可。
- 凭据只存在本机（`~/.antigravity-switcher/`）。
