# 归档功能设计：文件内 `## Archived` 段（派生视图）

> 语义前提：**归档 = 存档**，不是丢弃、也不等于完成。
> 归档任务是"项目任务地图"的一部分，要求 **可查 / 可复习 / 可再现**：
> 平时不在代码侧渲染，但随时能把完整地图（含存档）重新查看、定位。

本设计取代了早期的「独立冷存储（named store）」方案。该方案把归档任务搬进一个
独立 store、加载时才并入渲染，导致 store 与文件两份真源、且存在 **反向写文件** 的
脆弱路径。现行模型把真相收回到文件本身。

---

## 0. 单一真源

**归档任务的唯一真相源 = TODO 文件里的 `## Archived (YYYY-MM)` 段。**

- 任务行在 **活跃段** ↔ **归档段** 之间移动，就是「归档 / 反归档」。
- 主 store 缓存**全部**任务（活跃 + 归档）；归档状态 = `core.status == "archived"`。
- **没有独立冷存储**；不再有 store→文件的反向写入。
- 归档可逆，id 全程保留。

| 层 | 任务行位置 | store 状态 | 默认渲染 |
|---|---|---|---|
| active（todo/doing/blocked） | `## Active` 段 | 对应状态 | 是 |
| completed | `## Active` 段 | `completed` | 可过滤 |
| **archived** | **`## Archived (YYYY-MM)` 段** | **`archived`** | 否（按需查看） |

---

## 1. 状态如何推进

区域变更由 `lua/todo2/core/sync.lua` 统一处理（第 5 步）：

- 解析出每个任务所在的区域（`parser` 给出 `region_type`：`main` / `archive`）。
- **旧区域由存储状态派生**：`old = (status == archived) and "archive" or "main"`。
  （早前依赖 `task.region_type` 持久化，但该字段从不落盘，检测实际失效。）
- 区域变化时：进入归档段 → `enter_terminal(ARCHIVED)`；离开 → `exit_terminal` 恢复
  `previous_status`（缺省用默认态）。两个方向都做了幂等保护。

归档 / 反归档本身只负责「搬行 + 改复选框」，状态推进交给 sync，避免两处各写一遍。

---

## 2. 数据层 `lua/todo2/store/archive.lua`（只读派生）

不再持久化任何归档索引，全部从主 store 的任务派生：

- `archived_tasks()`：遍历 `store.get_namespace_keys(namespace.facts.tasks_ns)`，
  过滤 `core.status == types.STATUS.ARCHIVED`。
- `is_archived(id)` / `count()`。
- `forest()` → `roots, task_list`：按 `relation.get_parent_id` 建树，
  按 `timestamps.archived` 倒序（供 drawer / viewer / QF 复用）。
- `refresh_anchors()`：对带 `context` 的冻结代码锚点跑一次 `core.relocate_code_location`，
  落 `ok / stale / lost`（每会话一次）。
- `auto_archive()`：把「整棵子树均已完成、且完成时间早于 `archive.auto_after_days`」的
  根任务组归档（默认 0 = 关闭）。

没有 `open` / `close` / `spill_to_cold` / `archive_ids` / `prune` 等生命周期与墓碑 API。

---

## 3. 业务层 `lua/todo2/core/archive.lua`（搬行）

- **`archive_task_group(root_id, opts)`**
  1. 用 `relation.get_subtree_ids` 取整棵子树；
  2. 从 buffer 刷新最新内容 / 标签 / 正文进 store；
  3. 从活跃段摘除这些行（含正文本续行），
     渲染为 `[>]` 复选框、缩进归零，追加到**最后一个** `## Archived (YYYY-MM)` 段；
     没有归档段则在文件末尾新建 `## Archived (<当月>)`；
  4. 写回 buffer、落盘、`sync.sync_todo_file(path)`（推进归档状态）；
  5. `events.emit("archive_group", { files, deleted_locations, ... })` 供代码端清标记。
  完成后同步由 sync 置 `status=archived`。
- **`unarchive_task_group(ids)`**：把归档段内的行移回 `## Active` 段，
  复选框恢复为 `previous_status`（缺省默认态），再次 sync 退出终态。

锚点**冻结**：归档不改代码文件；查看时由 `refresh_anchors()` 重新解析。

---

## 4. 渲染与查看

- **默认**：代码侧 / 抽屉 / 查看器只渲染活跃段任务；`render/code_render` 显式跳过
  `status == ARCHIVED` 的任务（锚点仍冻结保留，只是不画标记）。
- **抽屉**：`A` 切换是否并入归档任务（`archive.include_in_render` 为初值）。
  归档节点用冻结的任务快照（`_task`）显示。
- **`:TodoArchiveView`**：树形查看归档任务，显示锚点状态 `⚠ lost` / `~ stale`。
- **`:TodoArchiveQF`**：平铺所有归档锚点，便于跳转 / `:cdo`。

---

## 5. 命令与配置

命令：`:TodoArchive`（`!` 允许未完成组）/ `:TodoUnarchive` / `:TodoArchiveView` /
`:TodoArchiveQF`。

配置：

```lua
archive_section = { title_prefix = "## Archived" },  -- 段标题前缀，认任意 (YYYY-MM)
archive = {
  allow_unfinished = true,   -- 是否允许归档未完成的任务组
  include_in_render = false, -- 抽屉是否默认并入归档任务
  auto_after_days = 0,       -- 完成超过 N 天的子树自动归档（0 = 关）
},
```

已删除的旧配置：`archive.store_name`、`archive.retention_days`（派生模型下无冷库可保留）。

---

## 6. 风险

- **锚点漂移**：归档时冻结、查看时重解析；符号改名 / 删除 → `stale / lost`（已有状态兜底）。
- **多会话并发**：各 nvim 持内存副本、整体重写；外部改文件会被覆盖（nvim-store3 既有行为）。
- **历史数据**：早期冷库方案可能残留 `facts.archive.index` 等键，由
  `store.namespace.purge_legacy()` 在启动时清理；旧 `## Archived` 段现在**就是**规范存储，无需导入。
