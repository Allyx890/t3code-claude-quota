# Changes

## 2026-10-25 — quota-refresh-reset-1

- Manual Limits refresh now bypasses T3's five-minute usage cache on web and mobile, including
  whole-environment and single-account requests. A refresh arriving during an older probe waits
  and then performs its own fresh read.
- Claude's explicit rejection of a known quota window marks that window exhausted even when
  utilization is missing or still reports an old value. Unknown limit types are not guessed.
- Active accounts are checked about once a minute; idle accounts every five minutes. Usage probes
  do not send model messages. Account logs include the observation timestamp.
- When no account can continue immediately, limited work moves to an account with remaining
  weekly quota and the earliest known five-hour reset. Accounts above the weekly threshold are
  preferred. One Continue request establishes that account's limit, then T3's existing
  Snoozed / Auto-resume waits for recovery. The best waiting account is not repeatedly retried.
- `waiting_for_reset` records the selected account and reset. `no_target` includes account
  eligibility details. An empty `accounts` list includes newly configured Claude instances.
- Packaging keeps the official desktop shell and native files, verifies public T3 Connect build
  configuration, and saves the previously installed build before swapping resources.

Validated against T3 Code v0.1.2 with focused and orchestration regression tests, package type checks,
patch application, archive checks, and an isolated observe-only server reading five real accounts.
Reset recovery was exercised with simulated provider failures and the test clock; upstream quota
reporting can still lag. Enable T3's Snoozed and Auto-resume settings for reset waiting.
