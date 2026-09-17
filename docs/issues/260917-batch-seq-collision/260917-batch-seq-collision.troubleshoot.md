# 260917 批量会话日志 "seq gap / torn record" 损伤（同型对撞三例 + 根因综合）

## 症状

同日三例报错（b91c5326 已于同日早先修复，见 [[260917-b91c-end-seed-seq-collision]]）：

| 会话 | 报错 | 损伤点 |
|---|---|---|
| session-651aa056 | seq gap at line 7144 (expected 17063, got 17062) | raw line 7144–7145 |
| session-3fb55993 | corrupt Zstandard session log: complete frame contains a torn JSONL record | raw line 7791–7795 |
| session-127690dc（扫描新发现，用户未报） | seq 1435 at line 1414 (expected 1438) type=assistant/chunk | raw line 1412–1415 |

全库严格扫描（backend 等价 decoder，993 份）：损伤仅此三份（b91c 修复后）。

## 根因（三例同型：世代标记/合成块 与 陈旧游标写入方对撞）

### 651aa056（b91c 同型）

| 行 | 事件 | seq | time |
|---|---|---|---|
| 7144 | session/end-seed | 17062 | 15:42:09.863 |
| 7145 | agent/inbox/spliced | 17062 | 15:45:14.056 |

end-seed 落盘后，live 写入方从陈旧游标 17062 续写（onCreated case-1 盲认领）。损伤发生在 15:42–15:45，恰在 4176 手动 dsh web（15:38 启动）与 4175 supervisor 实例并存期间——**跨进程双写同 session id 是本例最可能的触发场景**（两进程共享 DSH_HOME）。

### 3fb55993（260915 案原样复发）

07:45:03 turn 2 step 47 工具被打断 → 合成 closers（tool/result `interrupted-tool-result-*` + step/end + turn/end, seq 79656–79658, 7791–7793）+ end-seed(79659, 7794, 07:45:20) → **仍存活的旧写入方** 07:45:21 携真实工具结果从 seq 79656 重新续写（7795 起，与 callId `call_503e16b5bfbe4e5ba3b55fe4` 精确对应）。"torn JSONL record" 是 260915 已记录的误报链（scanner 的 seq issue 被误报为 torn record）。

### 127690dc（260915 同型，09-15 遗留）

09-15 12:39:17 turn 5 step 69 处 interrupted closers（step/end 1435 + turn/end 1436）+ end-seed(1437) 后，旧写入方 12:39:26 从 seq 1435 续写真实 step 69（assistant/chunk + evaluate_isolated 工具调用）。尾部 turn/end completed(1717) 完整。

### 共同机制

打断/恢复路径基于**存储态**追加合成事件与世代标记；持**陈旧内存游标**的存活写入方（可能在不同进程）随后继续追加。持久化层 append-only、无跨写入方 seq 冲突守卫 → 对撞落盘。三例覆盖了两个变体：变体 A（b91c/651aa056，end-seed vs inbox/splice）与变体 B（3fb55993/127690dc/260915，interrupted closers+end-seed vs 真实工具结果续写）。

## 修复（已执行：帧级切除 + 原子替换，三份全通过）

| 会话 | 切除行 | 保留 |
|---|---|---|
| 651aa056 | 7144（end-seed，恰为 1 完整帧） | 7145 起真实续写 seq 17062..17726 |
| 3fb55993 | 7791–7794（合成 closers + end-seed，2 帧） | 7795 起真实续写 seq 79656..88255 |
| 127690dc | 1412–1414（合成 step/end + turn/end + end-seed，2 帧） | 1415 起真实续写 seq 1435..1717 |

验证：真实后端 `readPrefix`（canonical 路径 + 身份校验）三份全 OK（17727 / 88256 / 1718 事件）；全库 993 份严格扫描 0 损伤。备份均在 `/root/.dsh/session-log-backups/*.bak-20260917`（md5 与原文一致）。

取舍说明：切除 end-seed 无 lineage 影响（三份均无 seeded 子会话引用）；下次 resume 会自然追加新的世代标记。

## 与 dsh-message-datetime 插件的关联排查（已排除）

651aa056 损伤点紧邻插件关闭读数（seq 17060 `user/message` source.plugin=dsh-message-datetime, 15:41:36，紧接 turn/end 17061），时间上疑似相关。但三项证据排除因果：

1. b91c（同型变体 A）的对撞区（seq 0–3）**无任何插件事件**（首个插件事件在 raw line 15，turn 1 开始后）。
2. 127690dc 与 260915 案损伤发生于 09-15，早于 turn-end 关闭读数功能上线（260916）。
3. 代码路径：插件的 `agent.session.append("user/message", …, { surfaceOp: "append" })` 走与普通消息完全相同的单写入方 append 路径，不创建第二个写入生命周期；对撞双方（end-seed 落盘方 vs 陈旧游标续写方）的形成机制与插件无关。651aa056 三次 end-seed 的前驱均为普通 `turn/end`，非插件事件。

结论：关闭读数只是恰好出现在一次对撞的附近（它本就每轮 turn/end 前注入），非成因。

## 对用户三问的结论

1. **原因**：同一 session id 被两条互不知情的写入生命周期对撞——打断/恢复路径按存储态追加 end-seed/合成 closers，旧写入方（内存游标落后）继续追加，seq 重复落盘。持久化层无冲突守卫（上游缺陷）。
2. **复现条件**：turn 被打断（用户 stop / GUI 重载）后立刻 resume/重开会话，且打断前的写入方还活着；或两个 dsh 进程（如 4175 + 4176）驱动同一会话。进程异常重启本身**不直接**导致此类损伤——但重启前后是上述对撞的高发窗口（260915、b91c 均为单进程生命周期内损伤）。
3. **与异常重启的关系**：无直接因果；反向关系成立（损伤→进程崩溃循环，09-16 18:56 即此）。本次 651aa056 的 15:42–15:45 损伤与 4175/4176 双进程并存时段精确吻合，跨进程双写是主要嫌疑。

## 建议（防复发）

1. **不要同时跑两个 dsh web 实例共享 DSH_HOME**（4176 手动实例已停；今后避免）。
2. dsh-patch 可考虑：append 时校验新事件 seq 不得与已存储 seq 冲突（守卫对撞）；`readZstdPrefix` 优先上报 scanner.issue（消灭 torn record 误报，260915 缺陷 #1）。

## 验收标准

- [x] 三份修复后 `readPrefix` 成功（真实后端、canonical 路径、含身份校验）
- [x] 全库 993 份日志严格扫描通过
- [ ] GUI 打开三个会话，历史正常渲染 —— **需用户实机验收**
