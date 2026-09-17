# 260915 zstd 会话日志 "torn JSONL record" 误报（seq 对撞）

## 症状

GUI 打开旧会话 `session-5c321570-559e-40ae-9c78-cd642ab1e6e7` 报错：

```
历史加载失败：failed to observe session "session-5c321570-…": corrupt Zstandard session log:
complete frame contains a torn JSONL record（gateway/internal）
```

## 根因

**直接原因（误报链）**：`dsh-session-persistence-jsonl` 的 `readZstdPrefix` 在
`complete.committedBytes !== complete.inputBytes` 时抛 "torn JSONL record"。但
`committedBytes` 停摆不只有"记录被撕裂"一种成因——`SessionLogScanner.consumeEventLine`
里**任何一行 JSON 解析失败或 seq 断档**都会置 `issue` 并停止提交后续行。本例中
scanner.issue（seq gap）从未被上报，被误报成了 torn record。

**底层原因（数据怎么坏的）**：会话日志里 seq 91261–91264 存在**两段分歧历史**。
时间线（2026-09-15，事件 time 字段 + supervisor 日志还原；损伤全部发生在旧实例
pid 25599 生命周期内，最终重启 02:34:50 在损伤之后才触发）：

| 时间 | 写入方 | 内容 |
|---|---|---|
| 02:34:24.7 | 中断路径 | 合成 closers：`tool/result`(TOOL_OUTCOME_UNKNOWN, seq 91261) + `step/end`(91262) + `turn/end`(interrupted, 91263)。该会话 turn 3 step 13 正在跑浏览器点击工具（camoufox 操作 dsh GUI）时 turn 被打断。打断触发者无运行日志可考（用户 stop 或 GUI 会话重载） |
| 02:34:35.6 | 恢复路径 | 会话被 resume，Session 构造函数按语义追加世代标记 `session/end-seed`(seq 91264) |
| 02:34:38.7–48.4 | 仍存活的旧写入方 | 打断前的工具调用（浏览器点击）此时返回真实结果 + turn 3 step 14–16 续写，**沿用旧内存游标从 seq 91261 重新编号**，共 201 个事件（91261–91461），其中包含排程 live 重启（"detached restart scheduled in 2s"） |
| 02:34:50.4 | supervisor | dsh 重启（stop → pid 32227），日志定格在损伤后的 mid-turn 状态 |

即：**turn 被打断 → 会话被 resume，而打断前的工具调用仍在跑**——中断/恢复路径
基于**存储态**追加合成事件，持**陈旧内存游标**的存活写入方随后继续追加，两者在
seq 91261–91264 上对撞。持久化层 append-only、无跨写入方 seq 冲突检测，对撞数据
落盘。最终的重启本身只是把已损伤的日志定格在 mid-turn（该行为良性）。

读取时 scanner 在 rewind 点（文件行 9817，expected 91265 got 91261）置 issue；
分歧尾部没有 `turn/end`（fail-fast 条件不满足），最终走到 checkpoint 比对不等，
抛出误导性的 "torn JSONL record"。

## 现象与根因的关联

- 文件本身 zstd 帧结构完好（7772 帧全部完整、校验通过、每帧以 `\n` 结尾）——
  公共 API `zstdDecompressSync` 逐帧解码与私有流式解码器输出完全一致。
  故 "corrupt Zstandard session log" 字面为假，实为 seq 断裂被错误归类。
- 历史（含最后一轮"重启 live 4175"操作流）数据都在，只是 4 行合成块插在
  真实续写之前造成 seq 倒卷。

## 修复路径（已执行：数据修复）

保留真实续写（91261–91461 连续），切除 4 行合成块（synthetic tool/result +
step/end + turn/end + session/end-seed，恰为完整帧 7753–7754，物理字节
[2481775, 2482389)），帧级拼接后原子替换：

- 备份：`/root/.dsh/session-log-backups/session-5c321570.session.jsonl.zstd.bak-20260915`（md5 校验一致）
- 修复脚本：按内容定位合成块（校验事件类型 / TOOL_OUTCOME_UNKNOWN / interrupted /
  帧边界对齐）→ 内存验证（91462 事件连续 0..91461）→ fsync + rename → 对最终
  路径跑真实后端 `readPrefix` 通过。
- 全库健康扫描：642 份 zstd 会话日志 642 份通过，损伤仅此一份。

取舍说明：切除 `session/end-seed` 无 lineage 影响——无 seeded 子会话引用该前缀
（唯一关联 `cda3f370` 为自包含 subagent 日志）；会话尾保留真实的 step/start 91461
（进程中断态），下次 resume 时网关会正常补 closers + 世代标记。

## 上游缺陷（建议后续补丁，未实施）

1. **误报（本症状的直接病灶）**：`readZstdPrefix` 应在 checkpoint 不匹配时优先
   抛 `scanner.issue`（真实成因："seq gap in committed region at line 9817
   (expected 91265, got 91261)"），仅在其为空时才报 torn record。
   plain-JSONL 路径同类问题更糟：issue 会被当成 torn tail **静默截断**。
2. **seq 对撞无守卫**：append 只有序列化保证，无"新事件 seq 不得与已存储 seq
   冲突"的校验。中断/end-seed 之后，陈旧游标的写入方仍能落盘分歧历史。
   完整修复（写入方世代/租约）属上游架构问题。

## 置信度

数据修复：>99%（真实后端 readPrefix 通过 + 91462 事件连续性逐事件验证）。
根因归因：>90%（时间线、事件内容、seq 游标推算、supervisor 重启时刻全部吻合；
唯一不确定的是 02:34:24 打断的具体触发者——用户 stop 或 GUI 会话重载，网关无
运行日志可考，不影响修复正确性）。

## 验收标准

- [x] 修复后 `readPrefix` 成功（真实后端，含身份校验）
- [x] 全库 642 份日志健康扫描通过
- [ ] GUI 打开该会话，历史正常渲染（含最后一轮重启操作流），以 turn 3 step 16
      中断态收尾 —— **需用户实机验收**
