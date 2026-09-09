# dsh-patch

dsh（`@deepseek-ai/dsh`）的部署补丁集。这些补丁修的是本机部署上 dsh 的问题，
其根因在 dsh 上游代码里，但上游尚未修，所以以补丁形式打到已安装的 dsh 包上。

> ⚠️ **升级 dsh 会覆盖这些补丁**——每次 `npm i -g @deepseek-ai/dsh`（或等价升级）后，
> 重新跑 `./apply.sh` 即可全部重打。`apply.sh` 是幂等的（已应用会跳过，上下文不匹配会报错而非静默失败）。

## 补丁清单

### 0001-subprocess-local-orphan-poll-backoff.patch

**症状**：dsh web 会话列表 / 会话首次加载极慢（本地直连 session.list 也要 ~12s），
dsh 进程空闲时仍占满 ~80% CPU。

**根因**：`@deepseek-ai/dsh-subprocess-local` 的 `observeTreeExit` 里
`while (treeAlive()) await sleepTick()`（`sleepTick` = 15ms）在主子进程 `settled`
后，对“组长已死、孤儿仍活”的进程组（典型：从 bash 工具跑的 `pnpm preview` /
astro 预览服务器等长驻后台命令，启动器退出后进程被 init 收养）做**永久全 /proc
stat 扫描**——每轮同步 `readFileSync` 读 ~670 个 `/proc/<pid>/stat`、阻塞事件循环
~470ms。进程组不消失，循环永不退出（观察者是泄漏的 async，`cleanup()` 不取消它，
也没绑 AbortSignal）。

**修复**：settled 后把轮询从 15ms 退避到 5s。CPU 从 ~80% 降到 ~10%，事件循环不再
被卡。不改变正确性：组真死时仍能检测到（晚几秒）；SIGTERM→SIGKILL 的 grace-timer
escalation 不受影响。

**规避**：长驻后台进程（dev server / tunnel / 守护进程）用 supervisord 托管，别用
dsh bash 工具前台启动。

### 0002-apiproxy-history-chunk-filter.patch

**症状**：dsh 会话首次加载慢——`session.history` 响应一个长会话能到 5.9MB。

**根因**：`session.history` 响应里 `assistant/chunk`（LLM 流式 token 增量）占 payload
>82%（一个长会话 5.9MB 里 27191 个 chunk 占 4.39MB）。而最终的 `assistant/message`
事件已含完整组装内容（`data.message.content`），客户端 `dsh-client-ui-conversation`
的 fold 分支用 `toAssistantBlocks(data.message.content)` 自足渲染——chunks 是纯冗余
的流式遥测，只服务直播动画。

**修复**：在 `dsh-host-apiproxy` 的 `historyPage` 里，先收集本页所有 `assistant/message`
的 `turn:step` 入 `completeSteps` 集合，再过滤掉 `assistant/chunk` 中
`turn:step ∈ completeSteps` 的（即“该轮已收尾”的 chunks），**保留不完整轮**（无
`assistant/message`，如被中断的流）的 chunks 以免丢部分内容。`hasMore` 不受影响。

**实测**：payload 5.38MB → 0.96MB（-82%），事件数 27439 → 248，客户端 fold -99%。

> 诊断文档：`dsh-im-humanize/docs/issues/260909-dsh-web-slow-listing/`。

## 用法

```bash
# 重打所有补丁（升级 dsh 后必跑）
./apply.sh

# 验证某补丁是否已应用
cd "$(dirname "$(readlink -f "$(command -v dsh)")")/.." && \
  patch -p1 --dry-run < /path/to/dsh-patch/patches/0001-*.patch

# 回滚单个补丁
cd "$(dirname "$(readlink -f "$(command -v dsh)")")/.." && \
  patch -p1 -R < /path/to/dsh-patch/patches/0001-*.patch
```

## 兼容性

补丁针对当前部署的 dsh 版本（`dsh --version`）。dsh 升级若改动了被补丁文件的相关
上下文行，`apply.sh` 会报 context-mismatch——此时需对照新版代码重新推导补丁
（diff 旧备份与新文件），更新本仓库的 `.patch` 文件后再 `./apply.sh`。

打补丁前请先确认 dsh 版本与补丁推导时一致；不一致时先在测试环境验证。
