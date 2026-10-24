# t3code-claude-quota

[中文说明](./README.zh-CN.md)

A quota autopilot for [T3 Code](https://github.com/pingdotgg/t3code) when you use several Claude subscriptions
(one T3 Claude provider instance per account).

- **Switches accounts before you hit the wall.** When the account a conversation uses is nearly out of its
  5-hour or weekly quota, the conversation moves to the account with the most quota left.
- **Resumes work the limit stopped.** A run that just failed with a usage limit is continued within seconds on
  another account — the same command as T3's own *Resume* button with a different account selected.
- **Starts idle accounts' 5-hour windows early.** When an account's window has ended and nobody is using it,
  it gets one tiny message, so its next window is already counting down by the time you need it.

It is a single server-side file patched into T3 Code. It only uses commands and services T3 already has:
no UI, protocol, orchestrator or provider-adapter changes, which keeps it easy to carry to new T3 releases.

> Make sure the way you use several accounts complies with Anthropic's terms.

## How it decides

The autopilot wakes the moment a run fails (via T3's event stream), when an account's known 5-hour window
ends, and once a minute otherwise. These checks only read local state. Usage itself is read with T3's own
usage probe about every 5.5 minutes, without sending a model message.

**Switching** (an account is "low" when its 5-hour or weekly quota left is ≤ `switchAtRemainingPercent`):

- **Idle conversation on a low account** → its account is changed to the pooled account with the most 5-hour
  quota left. Your next message goes there. The sidebar order does not change.
- **Conversation stopped by a usage limit (within the last 5 hours)** → `Continue where you left off.` is sent on
  the best account. Queued follow-up messages that T3 held on the empty account are re-queued on the new one.
- Only the account changes: model, effort and other options stay. The target must offer that model and have
  both its 5-hour and weekly quota above the threshold. A model-specific weekly window (Max plans) only
  counts for conversations using that model.
- **No account left** → nothing changes and a `no_target` entry is logged. T3's own "resume after reset"
  (`autoResumeLimitedThreads`) takes over.
- Running conversations, pending approvals, conversations you marked as settled and Claude subagent threads
  are left alone. Conversations T3 auto-settled are still moved, since their next message needs quota too.
- **Idle conversations with live background tasks** (Monitor, background commands, background subagents)
  are not moved early: switching accounts closes the old Claude session and kills those tasks. They stay put
  (`held_background`) until an actual limit stops them; the continue message then lists the stopped tasks so
  the new account can restart what is still needed.
- An account a run just hit the limit on counts as empty until a newer probe says otherwise.
- A conversation is auto-continued at most 3 times per 5 hours (`continue_gave_up` after that).
- T3's idle `/compact` hitting a limit is not treated as work to continue.

**Activation** (`activate: true`): an account that is ready, idle, not low on weekly quota and has no running
5-hour window gets a fresh thread in a project called **Claude quota timers**, with the message
`Only reply with 'Hi'.` (Haiku at low effort by default).

- When an earlier probe reported when the window ends, the message is sent 30 seconds after that time —
  no need to wait for the next probe, which would start the window 5–11 minutes late.
- Otherwise two probes at least `activateAfterFullMinutes` apart must both show 100%.
- Only a window that ends after the message was sent counts as confirmation (`activation_confirmed`), so a
  stale snapshot never triggers a second message. Failures are retried after 30 minutes.
- The thread is deleted once the reply is in (or after 30 minutes if it got stuck).

## Requirements

Tested with T3 Code **v0.1.2**. Other versions must pass the patch, test and build checks before deployment.

- Windows 10/11 with the desktop T3 Code installed (the scripts patch the installed app).
  The patch itself is platform-neutral; on macOS/Linux apply it to a T3 checkout and build it yourself.
- Git, and [Vite+](https://viteplus.dev/guide/) (`irm https://vite.plus/ps1 | iex`) for the first dependency install.
- The Node.js version the T3 release requires (`engines.node` in T3's `package.json`; 26.12.1 for v0.1.2).
- Two or more Claude provider instances in T3 (**Settings → Providers**), each signed in to its own account.

## Install

```powershell
git clone https://github.com/alllyx520-bot/t3code-claude-quota.git
cd t3code-claude-quota
.\Update-T3-Quota.ps1
```

`Update-T3-Quota.ps1`:

1. Reads the installed T3 version and clones T3 Code into `work\t3code` (first run).
2. Checks out that release's tag, applies `claude-quota.patch` and runs the patch's tests.
3. Builds T3 with the same public build config as the official release
   (copied from the official package, so T3 Connect sign-in and relay keep working) and verifies it.
4. Repackages the official app: only the compiled desktop and server bundles are replaced.
5. Starts an isolated copy against your real accounts in observe-only mode and checks that every account
   reports usage. Nothing is sent.
6. Backs up the official files to `backup\official-<version>`, swaps the patched files in and restarts T3.
   The restart runs as a one-off scheduled task, so it also works when the script was started from inside T3.

Options: `-NoRestart` stops after the isolated check; `-SkipBuild` reuses the last build.

Paths can be changed in `t3-quota.local.json` (not committed):

```json
{ "t3Source": "D:\\src\\t3code", "nodeDir": "D:\\tools\\node-26", "t3Install": "C:\\...\\Programs\\t3code" }
```

Restarting T3 stops background tasks in all conversations. T3 itself wakes conversations whose Monitors or
subagents were stopped; plain background commands resume with your next message.

## Configure

`%USERPROFILE%\.t3\userdata\claude-quota.json` is created from `claude-quota.example.json` on the first install
and never overwritten afterwards. Changes apply within a minute, without restarting T3.

| Field | Meaning |
|---|---|
| `enabled` | Master switch. `false` or no file: nothing runs |
| `observeOnly` | `true`: only log what it would do |
| `accounts` | Provider instance ids in the pool; `[]` means every Claude instance |
| `switchAtRemainingPercent` | Quota left (%) at or below which an account counts as low; default 5 |
| `activate` | Start idle accounts' 5-hour windows; default `true` |
| `activateAfterFullMinutes` | Without a known reset time, how long an account must read 100% first; default 10 |
| `activationModel` | Model for the activation message; default `claude-haiku-5-5`, falling back to the account's default |
| `activationEffort` | Effort for that message; default `low`, skipped if the model does not offer it |

## Logs

`%USERPROFILE%\.t3\userdata\logs\claude-quota.ndjson` (rotated at 2 MB). `.\Show-T3-QuotaLog.ps1` shows the
tail, `-Follow` keeps watching. Every action carries a plain `message`, for example
`Moved "Refactor auth" from Claude2 (3% left) to Claude4 (76% left).` Logs include conversation titles and
identifiers, but not message bodies. Review local logs before sharing them.

Events: `account`, `switched`, `continued`, `queue_moved`, `no_target`, `held_background`, `continue_gave_up`,
`activation_sent`, `activation_confirmed`, `would_*` (observe only), `*_failed`.

## Updating T3

The patched build is versioned `<official>+quota`, which T3's updater treats as equal to the official release,
so T3 still tells you about new versions (it never installs them on its own). To upgrade:

1. Install the new official release (the in-app update or the installer). The autopilot is gone until step 2.
2. Run `.\Update-T3-Quota.ps1` again.

## Uninstall

`.\Restore-T3-Official.ps1` puts the newest official backup back and restarts T3.
`claude-quota.json` can stay; the official build ignores it.

## Porting to a new T3 release

The patch touches `apps/server/src/orchestration-v2/`: the new `ClaudeQuotaAutopilot.ts` (all logic) and
`ClaudeQuotaAutopilot.test.ts`, a few lines registering the layer in `runtimeLayer.ts`, and one integration test in
`runtimeLayer.test.ts`. If it no longer applies, usually `runtimeLayer.ts` moved or a field of `ServerProvider`
or the thread shell was renamed.

1. In the T3 checkout: `git checkout -f --detach v<version>`, then `git apply` the patch, or port it by hand.
2. In `apps/server`: `vp test run src/orchestration-v2/ClaudeQuotaAutopilot.test.ts src/orchestration-v2/runtimeLayer.test.ts`
   and `vp run typecheck`; `vp fmt` and `vp lint` the changed files.
3. Regenerate the patch from the checkout root:
   `git add -N` the two new files, `git diff --binary v<version> -- apps/server/src/orchestration-v2/ > claude-quota.patch`,
   then `git reset` them.
4. Run `.\Update-T3-Quota.ps1`.

## Known limits

- Cross-account continuation uses T3's own context handoff; very long histories may be condensed, and the
  new account has no prompt cache, so its first message re-reads the conversation.
- Queued wake-ups and subagent results are not moved to the new account.
- No in-app notifications: T3 builds its notifications in the client from thread state and has no server channel
  for custom ones. Actions are logged instead.
- It only runs while T3 is running.

## Related T3 issues

- [#21705](https://github.com/pingdotgg/t3code/issues/21705): queued messages restart on the exhausted account
  after resuming on another one (accepted upstream; the patch re-queues them on the new account).
- [Discussion #24431](https://github.com/pingdotgg/t3code/discussions/24431): switching account or model silently
  stops background tasks.
- [Discussion #18949](https://github.com/pingdotgg/t3code/discussions/18949): continuing on another account when one
  runs out.

## License

MIT
