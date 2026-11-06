# 更新记录

## 0.3.0
### 新增
- 「额度」页的 API Key 配置，保存在本机钥匙串（不再依赖其他工具）。
- 审批接入 Claude Code、Codex、WorkBuddy、Gemini、DSH；`tools/approval-hooks.py` 负责安装、卸载和查看状态。

### 修复
- Clash 密钥不再出现在 `curl` 的命令行参数里。
- token 统计移到 `~/Library/Caches/NotchHub/`，不再写入可预测的 `/tmp` 路径。
- token 采集只读统计窗口内改动过的会话，不再每次全量读取。
- 没有 `zstandard` 时只跳过 DSH，不再整体失败；没有命令行工具时不再触发系统安装弹窗。
- 支持 Homebrew 安装的 `codex`。

### 变更
- 公开版不再解密 WorkBuddy 的加密登录态，这种情况下不显示积分。

## 0.2.0
- 独立的「合盖不休眠」开关，不再依赖定时。
- 看门狗自行判断电源；拔电或低电量时暂停，合盖时立刻睡眠。

## 0.1.0
- 首个版本：额度、智能体、审批、常醒、工具。
