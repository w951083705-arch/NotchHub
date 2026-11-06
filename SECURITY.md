# 安全说明

发现安全问题请通过 GitHub 的 Private vulnerability reporting 私下报告，不要开公开 issue。

## 设计要点
- **审批默认不放行**：只有用户在卡片上点击才会允许；通道不通、超时、回复不符都回到智能体自带的审批。
- **审批 socket**：`/tmp/agenthud-approval.sock`，权限 0600。钩子脚本只信任属于当前用户的 socket。同一用户下运行的程序可以发起审批请求，但只有点击卡片才会得到允许。
- **root 看门狗**：只在打开「合盖不休眠」时启动，用系统密码框授权，不留 sudoers 规则，也不安装常驻服务。它只运行 `pmset`、`ioreg` 等固定路径的系统命令；控制文件只按纯数字解析。
- **凭据**：API Key 只存钥匙串，只发给固定的官方接口，并拒绝重定向。Clash 密钥通过 stdin 传给 curl，不出现在进程参数里。
- **本机文件守卫**：运行 `codex`、读取 WorkBuddy 登录文件前，校验属主和写权限。

## 已知限制
- 应用使用 ad-hoc 签名，没有经过 Apple 公证。
- 看门狗被 `SIGKILL` 杀死时无法自行恢复 `SleepDisabled`，下次启动应用时会提示恢复。
