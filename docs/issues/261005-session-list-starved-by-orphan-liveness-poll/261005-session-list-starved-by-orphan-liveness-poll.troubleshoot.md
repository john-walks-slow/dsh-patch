# 会话列表加载不出 —— subprocess-local 孤儿进程组 liveness 轮询打满单核

- 日期：2026-10-05
- 影响：dsh web（4175/4180/4176/隧道全入口）侧栏「会话列表」永远转圈；工作区列表正常
- 结论：**已定位并修复**（重打 dsh-patch 0001 + 加预算上限）。根因在
  `@deepseek-ai/dsh-subprocess-local` 的 PGID fallback 退出等待循环。

## 1. 现象

用户描述：dsh 跑久之后打开 UI，**工作区能列出来，工作区里面的会话列表全列不出来**，
一直转圈不报错。重启 dsh 后恢复正常，过一段时间复发。

## 2. 现场取证

### 2.1 排除法：不是会话数据问题

`curl` 直连 host 的 unary API（`POST /api/session/list`，args 键是 `_request`）：

- 15:05 第一次探针：**HTTP 200，77ms 内开始返回**，payload 正常（2475 条、2.27MB）
- 15:07 之后同一探针：**永久挂起**，12s / 25s / 50s / 90s / 30min 全部超时零字节
- 同期 `POST /api/settings/describe`：**52ms 正常返回**

→ 事件循环没死，host 没崩，只有“贵”的请求挂住。UI 侧（playwright）实测
`POST /api/session/list` 状态永远 pending，页面卡在加载中 —— 与用户描述一致。

### 2.2 进程画像：单核 100%

```
pid 14185 node dsh web ...   %CPU 67.7 (累计), 主线程 5s 内 504 jiffies = ~100% 单核
```

`kill -USR1` 打开 inspector，CDP `Profiler` 采样 6s：

| 自耗比 | 函数 | 位置 |
|---|---|---|
| ~51% | `readFileUtf8` | （/proc/<pid>/stat 同步读） |
| ~25% | `parseProcStat` | `dsh-subprocess-local/lib/runner-launch-B2zsQ1Dz.js:343` |
| ~10% | `readdir` | （/proc 目录） |
| ~1% | `linuxProcessGroupHasLiveMembers` | 同文件 :405 |

即：**`linuxProcessGroupHasLiveMembers` 在以 ~17Hz 全量扫描 /proc**。

### 2.3 谁在调它（`process.kill` 探针）

在活进程里给 `process.kill` 打点数补丁（passthrough），6s 内统计到三个负 pid 各 ~104 次：

```
{"-30764:0":104, "-30715:0":104, "-7557:0":103}
```

对应三个**有活成员的孤儿进程组**：

| pgid | 活着的成员 | 来源 |
|---|---|---|
| 30764 | `cloudflared tunnel --url ...` | dsh bash 工具里起的临时隧道（nohup 后台） |
| 30715 | `bash -c ...` + `node apps/server/dist/index.js` | stage-ai worktree 的预览服务器（后台起，`&`） |
| 7557 | `node /usr/bin/dsh web --port 51784` | 另一个 dsh 实例（后台起） |

## 3. 根因

`dsh-subprocess-local` 在**没有 systemd/cgroup 的部署**（本机：Android init 为 PID 1，
`probeLinuxNative()` 要求的 `systemd-run --user --scope` 不存在）走 **PGID fallback**
容器化路径。`LocalSubprocessRuntime.spawn` 在直接子进程退出后：

```js
const release = () => handle.waitForExit().then(() => { this.live.delete(handle); });
handle.done.then(release, release).catch(() => {});
```

而 fallback owner 的退出等待是**无上限**的：

```js
const alive = () => {
  process.kill(-pid, 0);                                  // 组还在（含僵尸）→ 真
  if (directSettled && linux && linuxProcessGroupHasLiveMembers(pid) === false) return false;
  return true;
};
observation ??= (async () => { while (alive()) await sleepTick(); stopped = true; })();  // sleepTick = 15ms
```

只要进程组里还留着一个**长驻进程**（daemonize 后台命令的典型结果），
`alive()` 永远为真 → **15ms 一轮、每轮全量扫描 /proc、永不退出**。
每轮成本实测：`/proc` 1097 个条目、1023 次 `readFileSync`、**35.5ms**。
一轮 35ms 却按 15ms 排程 → 事件循环被彻底淹没（3 个泄漏循环 = 单核 100%）。

**为什么“会话列表”先倒？** `session/list` 是全量扫描：`listArtifacts()` 要遍历
41 个工作区 / 2496 个 session 目录（readdir）+ 读 2496 个 session 日志头（解压 zstd 首帧）。
实测健康状态 8.8–10s；事件循环被 35ms×17Hz 的同步扫描反复堵死后，这几千次异步
readdir 的续体只能挤在两次同步爆发之间执行，退化成“永远”。

而工作区列表 / settings / permissionPresets 都是 O(工作区数) 的小请求，几十毫秒内
就能在缝隙里跑完 —— 正好解释“工作区能出来、会话列表出不来”。

**为什么“跑久了才犯”**：每留下一个后台守护进程就多一个永久泄漏的轮询循环；
dsh 跑得越久、越多的 `nohup ... &` 命令被执行，泄漏越多（本次 3 个），
会话数也在增长，两个方向一起恶化。

## 4. 定位手法（可复用）

1. `kill -USR1 <dsh pid>` 打开 inspector（`127.0.0.1:9229`），CDP `Profiler.start/stop`
   采 6s CPU profile → 直接读到热点函数。**这是最快的一步。**
2. 活进程内 `Runtime.evaluate` 给 `process.kill` 打计数补丁 → 拿到被轮询的 pgid。
3. `Runtime.evaluate` + `process.getBuiltinModule('node:fs')` 微基准 → 量出单轮扫描成本。
4. `Debugger.setBreakpointByUrl` + `evaluateOnCallFrame` 追踪 RPC 走到了哪一层
   （本次确认 `listArtifacts → listGenerations` 在走、只是被饿死）。
5. **A/B 验证**：把 `process.kill(-pgid, 0)` 对那三个 pgid 改成抛 `ESRCH`（只拦 `sig===0`，
   不碰守护进程本身）→ 主线程 CPU 100% → 3.6%，`session/list` 10s 内返回 2475 条。
   因果链闭合。

## 5. 修复

### 5.1 补丁 0001（重推导）

`patches/0001-subprocess-local-orphan-poll-backoff.patch` 原本就是这个 bug 的修复，
但在 **2026-09-28 升级 dsh 到 0.1.7-rc.2** 后，`dsh-subprocess-local` 的 rollup chunk
文件名从 `runner-launch-COYGu0Dl.js` 变成 `runner-launch-B2zsQ1Dz.js`，
`apply.sh` 在 0001 上 context-mismatch 退出，**补丁静默失效了一周**（0006/0007 也一并
没打上）。

本次把 0001 重新推导到当前 chunk，并把「无限 15ms 轮询」换成三段策略：

```js
const FALLBACK_PENDING_POLL_MS = 100;    // 杀树进行中：100ms（原 15ms）
const FALLBACK_SETTLED_POLL_MS = 5e3;    // 直接子进程已退：5s（只可能剩孤儿）
const FALLBACK_WAIT_BUDGET_MS  = 6e4;    // 总预算 60s，到点放弃观察，不再空转
```

- 解决了 CPU 饥饿（不再 15ms 全量扫 /proc）
- 解决了**永不退出**（有预算上限；`this.live` 不再无限增长）
- 保持正确性：正常命令 0–1ms 返回；被 kill 的树仍在 100ms 内被察觉；
  SIGTERM→SIGKILL 的 grace 升级由独立 timer 驱动，不受影响
- 语义取舍：预算到点后放弃观察，**不再对残留守护进程补发信号**（本来也不会：
  正常完成的命令从不调用 terminate()）。残留进程仍由 init 收养。

验证（隔离 harness，直接 import chunk 调 `spawnSubprocess` + `waitForExit`，
起 `bash -c 'nohup sleep 300 &'` 制造孤儿）：

| | 未打补丁 | 已打补丁 |
|---|---|---|
| 12s 内 waitForExit | 未返回 | 未返回（按设计，60s 到点） |
| 期间 CPU | **61.8% 单核** | **1.2% 单核** |
| 60s 后 | —— | 60.7s 返回；二次调用 0ms |
| 普通命令（无孤儿） | —— | 0–1ms，无退化 |

### 5.2 apply.sh 加固

三处加固：

1. **chunk 名自适应**：把补丁文本里的 `runner-launch-<hash>.js` 按**当前安装的 chunk 名**
   重写后再打，避免将来 upgrade 仅换 hash 就又静默丢补丁（真正改了上下文仍会 fail loud）。
2. **DROOT 探测修正**：原守卫探测 `$DROOT/node_modules/@deepseek-ai/dsh-session-persistence-jsonl`，
   但当前布局下该包在**顶层全局 node_modules**（`/usr/lib/node_modules/@deepseek-ai/`），
   不在 dsh 包内 —— 即今天直接跑原版 `apply.sh` 会立刻以 “dsh install root not found” 退出。
   改为探测 `dsh-subprocess-local`（当前确实在 dsh 包内）。
3. **新增 `--check`**：只报告每个补丁的 MISSING / already applied / context mismatch，
   不改文件；全在位时 rc=0。日常巡检一条命令即可。

```
$ ./apply.sh --check
  ⊘ already applied: 0001-...
  ✗ MISSING (would apply cleanly): 0006-...
```

## 6. 复发原因与后续

- **根因**：dsh 升级覆盖补丁目录，且 `apply.sh` 在 0001 上硬失败 → 后续补丁全丢。
- **规则**：每次 `npm i -g @deepseek-ai/dsh` 之后必须跑 `~/projects/dsh-patch/apply.sh`。
- **未处理的同源项**：`0006`（新会话默认 root 工作区）、`0007`（放行 `--host 0.0.0.0`）
  当前仍未打上（同样自 09-28 丢失）。本次刻意未动（不在本 issue 范围，属其他工作），
  需要时跑 `apply.sh` 即可。
- **上游**：0.2.0-rc.2 / 0.2.1-alpha.1 的 `runner-launch-*.js` 与出问题的
  0.1.7-rc.2 **逐字节相同**，上游尚未修此问题。
