# t3code-claude-quota

[English](./README.md)

给同时使用多个 Claude 订阅的 [T3 Code](https://github.com/pingdotgg/t3code) 用户的额度自动驾驶
（每个账号在 T3 里对应一个 Claude Provider 实例）。

- **额度快用完前自动换号**：对话所用账号的 5 小时额度或周额度快用完时，把对话换到剩余额度最多的账号。
- **被额度打断的工作自动接着干**：撞了额度的回合会在几秒内换到另一个账号继续，
  用的就是 T3 自带的 Resume 按钮（选别的账号后点继续）那条命令。
- **提前启动空闲账号的 5 小时窗口**：某账号的窗口到期、又没人在用时，给它发一条极短的消息，
  这样等你需要用它时，新窗口已经在倒计时了。

它是打进 T3 Code 的一个服务端文件，只调用 T3 已有的命令和服务：不改界面、协议、编排器或
Provider 适配器，所以 T3 出新版时很容易继续套用。

> 请自行确认你使用多个账号的方式符合 Anthropic 的条款。

## 判断规则

对话一撞额度（来自 T3 的事件流），或账号已知的 5 小时窗口到点，补丁会立刻醒来处理；平时每分钟巡检一次。
这些检查只读本地状态。额度用 T3 自带的 Usage 查询读取，约 5.5 分钟一次，不发送模型消息。

**换号**（5 小时或周额度剩余 ≤ `switchAtRemainingPercent` 就算"不够"）：

- **额度不够的空闲对话** → 换到池中 5 小时额度剩余最多的账号，你的下一条消息就发到那里。侧边栏顺序不变。
- **被额度打断的对话（5 小时内）** → 在最合适的账号上发 `Continue where you left off.`。
  T3 卡在没额度账号上的排队消息，会在新账号上重新排队。
- 只换账号，模型、思考强度等选项不变。目标账号必须提供这个模型，5 小时和周额度都要高于阈值。
  Max 套餐里"某个模型专用"的周额度，只影响使用该模型的对话。
- **无号可换** → 什么都不改，日志记 `no_target`，交给 T3 自带的"额度重置后自动继续"（`autoResumeLimitedThreads`）。
- 正在运行的对话、等待审批的对话、你手动标为结束（settled）的对话、Claude 子代理对话都不动。
  T3 自动标为结束的对话仍会换号，因为它们的下一条消息同样需要额度。
- **挂着后台任务的空闲对话**（Monitor、后台命令、后台子代理）不提前换号：换号会关闭旧账号的 Claude 会话，
  这些任务会跟着被杀掉。它们留在原账号（`held_background`），等真的被额度打断再续跑；
  续跑消息会列出被停掉的任务，让新账号把还需要的重新启动。
- 刚撞过额度的账号，在下一次查询之前当作 0%。
- 同一对话 5 小时内最多自动续跑 3 次，之后记 `continue_gave_up`。
- T3 空闲时自动 `/compact` 撞上额度，不算需要续跑的工作。

**激活**（`activate: true`）：账号已就绪、空闲、周额度不低、没有正在计时的 5 小时窗口时，
在名为 **Claude quota timers** 的项目里新建一个对话，发送 `Only reply with 'Hi'.`（默认 Haiku、低思考强度）。

- 如果之前的查询报告过窗口何时结束，就在那个时间后 30 秒发送，不必等下一次查询（否则会晚 5–11 分钟才开始新窗口）。
- 不知道结束时间时，要两次相隔至少 `activateAfterFullMinutes` 的查询都显示 100% 才发。
- 只有结束时间晚于发送时间的新窗口才算激活成功（`activation_confirmed`），旧数据不会导致重复发送。失败 30 分钟后重试。
- 收到回复后删除这个对话（卡住超过 30 分钟也会删除）。

## 环境要求

已在 T3 Code **v0.1.2** 上验证。其他版本需要先通过补丁、测试和构建检查，才能部署。

- Windows 10/11，并已安装桌面版 T3 Code（脚本会给已安装的程序打补丁）。
  补丁本身与平台无关；macOS/Linux 用户可以把它套到 T3 源码上自行构建。
- Git，以及首次安装依赖用的 [Vite+](https://viteplus.dev/guide/)（`irm https://vite.plus/ps1 | iex`）。
- 该 T3 版本要求的 Node.js 版本（见 T3 `package.json` 的 `engines.node`；v0.1.2 是 26.12.1）。
- T3 里至少两个 Claude Provider 实例（**Settings → Providers**），各自登录自己的账号。

## 安装

```powershell
git clone https://github.com/Allyx890/t3code-claude-quota.git
cd t3code-claude-quota
.\Update-T3-Quota.ps1
```

`Update-T3-Quota.ps1` 会：

1. 读出已安装的 T3 版本，首次运行时把 T3 Code 克隆到 `work\t3code`。
2. 切到该版本的 tag，套上 `claude-quota.patch`，跑补丁的测试。
3. 用与官方发行版相同的公开构建配置构建 T3（从官方安装包里复制，所以 T3 Connect 登录和中继照常可用），并核对。
4. 重新打包官方程序：只替换编译出来的桌面端和服务端代码。
5. 用真实账号启动一个隔离副本，只观察不动作，检查每个账号都能读到额度。不会发送任何消息。
6. 把官方文件备份到 `backup\official-<版本>`，换上补丁版并重启 T3。
   重启由一次性的计划任务执行，所以从 T3 里面运行脚本也没问题。

参数：`-NoRestart` 做到隔离检查为止；`-SkipBuild` 复用上次构建。

路径可在 `t3-quota.local.json`（不提交）里修改：

```json
{ "t3Source": "D:\\src\\t3code", "nodeDir": "D:\\tools\\node-26", "t3Install": "C:\\...\\Programs\\t3code" }
```

重启 T3 会停掉所有对话的后台任务。Monitor 或子代理被停掉的对话，T3 会自己唤醒；
普通后台命令要等你下次发消息才恢复。

## 配置

首次安装时从 `claude-quota.example.json` 生成 `%USERPROFILE%\.t3\userdata\claude-quota.json`，之后不会覆盖。
改完一分钟内生效，不用重启 T3。

| 字段 | 含义 |
|---|---|
| `enabled` | 总开关。`false` 或没有这个文件 = 完全不运行 |
| `observeOnly` | `true`：只记日志，不动作 |
| `accounts` | 参与轮换的 Provider 实例 ID；`[]` 表示所有 Claude 实例 |
| `switchAtRemainingPercent` | 剩余额度（%）不高于多少算"不够"，默认 5 |
| `activate` | 是否提前启动空闲账号的 5 小时窗口，默认 `true` |
| `activateAfterFullMinutes` | 不知道重置时间时，要连续显示 100% 多久，默认 10 |
| `activationModel` | 激活消息用的模型，默认 `claude-haiku-5-5`，账号没有时用账号默认模型 |
| `activationEffort` | 激活消息的思考强度，默认 `low`，模型不支持时不设 |

## 日志

`%USERPROFILE%\.t3\userdata\logs\claude-quota.ndjson`（超过 2 MB 轮转）。`.\Show-T3-QuotaLog.ps1` 查看最新记录，
`-Follow` 持续查看。每个动作都带一句英文 `message`，例如
`Moved "Refactor auth" from Claude2 (3% left) to Claude4 (76% left).` 日志包含对话标题和标识符，不包含消息正文；分享前请检查日志内容。

事件：`account`、`switched`、`continued`、`queue_moved`、`no_target`、`held_background`、`continue_gave_up`、
`activation_sent`、`activation_confirmed`、`would_*`（仅观察模式）、`*_failed`。

## 升级 T3

补丁版的版本号是 `<官方版本>+quota`，T3 的更新检查把它当作与官方同版本，
所以有新版时 T3 照常提醒（它从不自动安装）。升级步骤：

1. 安装新的官方版（界面里的更新或安装包）。完成第 2 步之前，额度自动驾驶不在。
2. 再运行一次 `.\Update-T3-Quota.ps1`。

## 卸载

`.\Restore-T3-Official.ps1` 装回最新的官方备份并重启 T3。`claude-quota.json` 可以留着，官方版会忽略它。

## 移植到新版 T3

补丁改动 `apps/server/src/orchestration-v2/`：新文件 `ClaudeQuotaAutopilot.ts`（全部逻辑）和
`ClaudeQuotaAutopilot.test.ts`，`runtimeLayer.ts` 里注册 layer 的几行，以及 `runtimeLayer.test.ts` 里的一个集成测试。
套不上时，通常是 `runtimeLayer.ts` 周围的代码变了，或 `ServerProvider`、线程 shell 的字段改了名。

1. 在 T3 源码里 `git checkout -f --detach v<版本>`，然后 `git apply` 补丁，或手工移植。
2. 在 `apps/server` 里运行 `vp test run src/orchestration-v2/ClaudeQuotaAutopilot.test.ts src/orchestration-v2/runtimeLayer.test.ts`
   和 `vp run typecheck`；对改过的文件运行 `vp fmt` 和 `vp lint`。
3. 在源码根目录重新生成补丁：先 `git add -N` 两个新文件，
   `git diff --binary v<版本> -- apps/server/src/orchestration-v2/ > claude-quota.patch`，再 `git reset` 它们。
4. 运行 `.\Update-T3-Quota.ps1`。

## 已知限制

- 跨账号续跑用的是 T3 自带的上下文交接，很长的历史可能被压缩；新账号没有提示缓存，第一条消息会重新读一遍对话。
- 排队中的后台唤醒和子代理结果不会搬到新账号。
- 不在 T3 界面弹通知：T3 的通知是前端根据对话状态生成的，服务端没有自定义通知通道。动作都记在日志里。
- 只在 T3 运行时工作。

## 相关的 T3 issue

- [#21705](https://github.com/pingdotgg/t3code/issues/21705)：在另一个账号上 Resume 后，排队消息又在没额度的账号上启动
  （官方已接受；本补丁会把它们在新账号上重新排队）。
- [讨论 #24431](https://github.com/pingdotgg/t3code/discussions/24431)：切换账号或模型会悄悄停掉后台任务。
- [讨论 #18949](https://github.com/pingdotgg/t3code/discussions/18949)：额度用完时在另一个账号上继续。

## 许可证

MIT
