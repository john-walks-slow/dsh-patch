# 260917 session-b91c5326 日志 "seq gap" 损伤（end-seed 与续写对撞 seq 3）

## 症状

GUI 打开会话 `session-b91c5326-e887-4523-8a95-2c628673d259` 报错：

```
历史加载失败：failed to observe session "session-b91c5326-…":
corrupt session log: seq gap in committed region at line 5 (expected 4, got 3)（gateway/internal）
```

（260915 案中的误报链已不存在：本次直接抛出 scanner 的真实成因，正确归类。）

## 根因

### 直接原因（数据形态）

日志第 5、6 行在 **seq 3 上存在两个事件**：

| 行 | 事件 | seq | time | 写入路径 |
|---|---|---|---|---|
| 5 | `session/end-seed` | 3 | 2026-09-16 13:03:40.446 | restore 路径：Session 构造函数对 seed=[0,1,2]（不含 end-seed）追加世代标记，经 `attachPrepared` 的 suffix 落盘 |
| 6 | `agent/inbox/spliced` | 3 | 2026-09-16 13:12:56.901 | live 路径：turn 1 开启前的 inbox 注入，写入方游标为 3 |

其后 seq 4..41111 连续（全文件仅此一处断裂）。读取时 scanner 在 line 5（事件行计数，不含 header）置 issue，报 "expected 4, got 3"。

### 底层原因（代码级机制，与 260915 案同型的"同一 id 两个写入方对撞"）

单进程（supervisor pid 18412，12:24:45–18:30:17）内，同一 session id 存在**两条互不知情的会话生命周期**：

1. 12:53:55 会话创建，标准 3 个 preset 事件（seq 0–2）落盘，cursor=3。
2. ~13:03:40 会话不在 live 状态时被观察/预取（`borrowSession`/`prepareCore`）：从盘上 seed=[0,1,2] 构造 Session → 构造函数在**内存中**追加 `session/end-seed`（seq 3，时间戳即此刻）。该世代标记随后经 resume 的 `attachPrepared` suffix 持久化（end-seed 是唯一只能由该路径落盘的事件；时间戳可早于落盘时刻）。
3. 13:12:56 用户发送首条消息。驱动该 turn 的写入方从**游标 3** 续写（onCreated case-1 认领 ownerless state：`seedMatchesPersisted` 只比对 `stored.slice(0, cursor)` 即 [0,1,2]，与全新构造的 preset 事件逐字相同 → 通过，end-seed 从未被比对），inbox splice 以 seq 3 落盘，与 end-seed 对撞。
4. 持久化层 append-only、无跨写入方 seq 冲突检测，对撞数据落盘。

时序佐证：13:15:57 该会话派生 4 个 deep-research 子代理（projcache 4 份记录均引用 parent id），后续 rewind 快照（14:13–14:18，seq 20902–41110）均正常——损伤只发生在最开头的世代边界。

**未完全确认的环节**：13:03–13:12 之间两条生命周期如何精确交错（13:03 的 end-seed 由哪次 resume 的 attachPrepared 落盘、13:12 的写入方为何读到 cursor=3 而非含 end-seed 的 4）——进程无逐请求运行日志可考，但不影响修复正确性（盘上事实唯一：end-seed 在前、splice 在后、均 seq 3、其余全连续）。与 260915 案一致的上游缺陷：**中断/世代标记与陈旧游标写入方之间无冲突守卫**。

## 现象与根因的关联

- zstd 帧结构完好（4469 帧全部完整、每帧以 `\n` 结尾、CLI 校验通过）——损伤是纯逻辑层的 seq 重复，非物理撕裂。
- 全部历史（含 turn 1 的完整研究流、turn 2）都在，4 行 preset + 1 行 end-seed + 真实续写。

## 修复（已执行：数据修复）

保留真实续写（seq 3..41111 连续），切除 end-seed 行（恰为完整帧 2，物理字节 [309,389)），帧级拼接后原子替换：

- 备份：`/root/.dsh/session-log-backups/session-b91c5326.session.jsonl.zstd.bak-20260917`（md5 `eb12a427…` 与原文件一致）
- 验证闭环（同一真实后端 `readPrefix`，含身份/路径校验）：
  - 原文件：精确复现用户报错 "seq gap … at line 5 (expected 4, got 3)"
  - 修复后（canonical 路径）：41112 事件（seq 0..41111）连续、tornMarker 无
- 全库扫描：977 份会话中仅此一份存在相邻 seq 重复，无同型损伤。

取舍说明：切除 `session/end-seed` 无 lineage 影响——该会话 `isSeeded: false`、`inheritedEventCount: 0`，无 seeded 子会话（其 4 个 deep-research 子代理为独立会话）。下次 resume 时构造函数见 seed 尾非 end-seed，会自然在 seq 41112 追加新的世代标记，行为正常。

## 上游缺陷（与 260915 案相同的遗留建议，未实施）

1. **onCreated case-1 的 `seedMatchesPersisted` 只校验 `stored.slice(0, cursor)` 前缀**，对 cursor 之后已落盘的世代标记（end-seed）视而不见 → 盲认领 ownerless state，是本次对撞的直接放行点。
2. **end-seed 内存时间戳 ≠ 落盘时刻**，且其落盘仅依赖 attachPrepared 一条路径，与写入方游标无一致性校验。
3. 完整修复（写入方世代/租约）仍属上游架构问题。

## 置信度

- 数据修复：>99%（真实后端 readPrefix 通过 + 41112 事件逐个连续性验证 + 全库扫描）。
- 根因归因：~85%（盘上数据形态、seq/时间线、代码路径分析全部吻合；仅 13:03–13:12 的进程内精确交错无日志佐证）。

## 验收标准

- [x] 修复后 `readPrefix` 成功（真实后端、canonical 路径、含身份校验）
- [x] 全库 977 份日志扫描，无其他同型损伤
- [ ] GUI 打开该会话，历史正常渲染（turn 1 研究流 + turn 2）—— **需用户实机验收**
