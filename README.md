# NotchHub

[English](README.en.md)

把 AI 编程工具的额度、运行状态、审批和常醒开关放进 MacBook 刘海的灵动岛。原生 SwiftUI/AppKit，无第三方 Swift 依赖。

> 与 OpenAI、Anthropic、Google、腾讯、DeepSeek、月之暗面、智谱均无关联，相关名称归各自所有者。

## 功能
- **额度**：DeepSeek / Kimi / GLM 余额，Codex / Claude 订阅剩余，WorkBuddy 积分；低于提醒线时弹出。
- **智能体**：Claude Code、Codex、DSH、WorkBuddy 的运行状态和 24 小时 token 用量。
- **审批**：把智能体的审批请求转到灵动岛，点一下允许或拒绝。
- **常醒**：接电常醒、不息屏、定时常醒、合盖不休眠。
- **工具**：常用应用和终端命令的快捷入口；Clash Verge 代理状态。

## 交互
- 悬停：向下展开速览。点击：完整面板，📌 固定后鼠标移开也不收起。右键：刷新、登录后自动启动、退出。
- 收到审批请求时自动弹出审批卡并播放提示音。

## 安装
需要 macOS 14+、Apple Silicon、Xcode 命令行工具（`xcode-select --install`）。没有刘海的屏幕也能用，会贴在屏幕顶部。

```bash
git clone https://github.com/w951083705-arch/NotchHub && cd NotchHub
./build.sh --install    # 编译、自测并安装到 ~/Applications
```

余额类额度：点「额度」页的 **API Key** 填写，只保存在本机钥匙串。

## 接入审批
```bash
tools/approval-hooks.py status
tools/approval-hooks.py install              # 或指定：install claude codex
tools/approval-hooks.py uninstall            # 改动前都会备份配置
```

| 智能体 | 方式 | 范围 | 说明 |
|---|---|---|---|
| Claude Code | `PermissionRequest` 钩子 | 需要审批的操作 | 提问和计划确认仍在 Claude 里完成 |
| Codex / ChatGPT 应用 | `PermissionRequest` 钩子 | 需要审批的操作 | 需要在 `/hooks` 或 设置 > Hooks 里确认信任 |
| WorkBuddy | `PermissionRequest` 钩子 | 需要审批的操作 | |
| Gemini（agy） | `PreToolUse` 钩子 | 只有执行命令 | agy 每次调用工具都会触发，且不看已允许的规则，所以每条命令都会弹卡 |
| DSH（desktop 配置） | 插件 | 需要审批的操作 | |
| Muse | 不支持 | | 没有对外的审批接口 |

NotchHub 没运行、超时（2 分钟）或出错时，一律回到智能体自带的审批，不会默认放行。

## 合盖不休眠
普通的防休眠请求挡不住合盖，所以只能打开系统的 `SleepDisabled`。打开时需要输入一次管理员密码，由一个 root 看门狗持有：

- 接电时一直有效；拔电自动暂停，接电后自动恢复。定时期间用电池也有效。
- 电量 ≤15% 且未充电时暂停；变成暂停时如果盖子是合上的，立刻睡眠，防止放进包里后过热。
- 关闭开关、退出、崩溃或关机时恢复系统设置。

## 数据与隐私
NotchHub 不上传任何数据，也没有自己的服务器。它会读取本机这些内容：

| 内容 | 用途 |
|---|---|
| 钥匙串中的 API Key | 查询对应平台余额 |
| `~/.codex`（运行 `codex app-server`）、Claude 的本机额度快照 | 订阅剩余 |
| WorkBuddy 登录文件 | 查询积分（只发给官方域名）。登录态已加密的版本暂不支持 |
| `~/.claude/projects`、`~/.codex/sessions`、`~/.dsh/sessions` | 活跃状态和 token 统计，只读用量字段 |
| Clash Verge 配置 | 代理状态 |

安全相关的设计见 [SECURITY.md](SECURITY.md)。

## 开发
```bash
./build.sh                                # 编译 + --self-test
zsh tests/lid-watchdog-test.sh            # 合盖看门狗（假 pmset）
/usr/bin/python3 -I tests/approval-hook-test.py
/usr/bin/python3 -I tests/approval-hooks-install-test.py
build/NotchHub.app/Contents/MacOS/NotchHub -show expanded -tab 智能体   # 直接展开并固定
```

已知限制：界面只有中文；新版 WorkBuddy 的积分暂不支持读取；合盖和审批的真实行为依赖各智能体版本，改动后需要手动验证。更新记录见 [CHANGELOG.md](CHANGELOG.md)。
