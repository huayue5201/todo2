# 归档功能重设计：独立冷存储（OmniFocus 式）

> 语义前提：**归档 = 存档**，不是丢弃、也不等于完成。
> 归档任务是"项目任务地图"的一部分，要求 **可查 / 可复习 / 可再现**：
> 平时不在代码侧渲染，但随时能把完整地图（含存档）重新加载、定位、渲染出来。

---

## 0. 分层模型

| 层 | 数据在哪 | 默认渲染 | 语义 |
|---|---|---|---|
| active（todo/doing/blocked） | 主 store（default） | 是 | 活跃工作集 |
| completed | 主 store（default） | 可过滤 | 已完成但仍是活跃地图的一部分 |
| **archived** | **独立冷存储（archive）** | **否，按需加载** | 存档层，可查/复习/再现 |

- 主 store 保持精简（只含 active + completed）。
- archived 移入独立 store 文件，常驻内存中**不加载**，需要时加载、用完卸载。
- 归档是**移动**（主库删、冷库存），不是复制。
- 归档**可逆**（反归档），id 全程保留。

---

## 1. nvim-store3 侧改动（通用能力）

现状：`init.lua:M.project(opts)` 只按 `project_key(from)` 缓存实例（同项目第二个 store 会撞缓存）；`store.lua:Store:cleanup()` 已经是 **flush + 清空内存**，正好是"卸载"语义。

要加：

1. **实例按 `(project_key, name)` 缓存**
   - `opts.name`，默认 `"default"`；缓存键加后缀。默认名保持现状、零影响。
2. **命名 store 的路径**
   - `util/path.lua:project_store_path(from, name?)` → `projects/<key>/data.json`（默认）/ `projects/<key>/<name>.json`（命名）。
   - `project_store_dir` 同理。
3. **显式生命周期 API**
   - `M.unload(opts)`：`Store:cleanup()`（flush）+ 从实例缓存移除。
   - `M.is_loaded(opts)`：是否已加载。
   - `M.clear()` 仍清全部。
4. （可选）命名 store 用 `meta.<name>.json`，或共用 `meta.json`。

这样 `nvim-store3.project({name="archive", from=...})` 与 active store 完全对称，todo2 不碰 `Store.new` 私有细节。

---

## 2. todo2 数据模型

### 主 store（default）新增一个键（墓碑）
```
todo.archive.index = {
  [id] = { at = <ts>, file = <todo path>, anchor = <code path|nil> },
}
```
- 轻量、单键 map，供"该 id 是否已归档"与反归档定位。
- 主 store 不再含归档任务的 `todo.tasks.*` / `task_ctx.*` / relation / index。

### 归档 store（archive）复用同一 schema
```
todo.tasks.<id>            -- core.status="archived"; previous_status 保留（反归档用）
todo.task_ctx.<id>.todo    -- { path, line }（冻结行号，加载时重解析）
todo.task_ctx.<id>.code    -- { path, line, context = signature/name/fingerprint }（冻结锚点）
todo.relation.*            -- 子树自包含，闭包
todo.index.file_to_todo.<path>
todo.index.file_to_code.<path>
```

### 锚点策略：冻结 + 加载时重解析
- 冷库不常驻 → 不能跟随代码行位移（shift），因此**必然**采用"冻结 + 按需重解析"。
- 复用现有 `core.relocate_code_location(id, lines_or_path)`（`lua/todo2/store/task/core.lua:716`）：
  按 context 的 signature/name/fingerprint 找回代码块，并把锚点状态落成 `ok / stale / lost`。
- 加载归档库/再现时，对每个冻结锚点跑一次重解析；失败标记 `stale`/`lost`，不丢数据。

---

## 3. 归档流程（移动语义，崩溃安全）

`:TodoArchive`（组 / 批量）：

1. 解析选中子树或批量集（默认：全部 `status=archived`；可选：completed-before-date）。
2. 打开归档库（`nvim-store3.project({name="archive"})`）。
3. 逐条写入归档库（tasks / ctx / relation / index），**保留 id**。
4. `archive:flush()` 成功。
5. 从主库删除同 id（tasks / ctx / relation / index），并在主库写 `todo.archive.index[id]`。
6. 主 TODO 文件：移除这些任务行（含正文/子标题），主文件只留活跃集。
7. `events.emit("archive_moved", {...})`。

**顺序约束**：先写冷库并 flush 成功 → 再删主库，避免中途崩溃丢数据；第 4 步失败则中止并回滚冷库。

---

## 4. 反归档 `:TodoUnarchive`

1. 由 `todo.archive.index` 找 id，定位归档库记录。
2. 写回主库（status 取 `previous_status`，否则默认态）。
3. 按冻结的 `locations.todo.path` + 锚点在 TODO 文件重新插入行（或 append 到 `## Active`）。
4. 从归档库删除 + 主库墓碑删除。
5. `events.emit("unarchive_moved", {...})`。

---

## 5. 渲染与按需再现

- **默认**：代码侧/抽屉/查看器只查主 store → 归档任务天然不出现（无需过滤逻辑）。
- **开关**：
  - `:TodoArchiveOpen` → 加载归档 store，并把归档库并入渲染/查询源。
  - `:TodoArchiveClose` → `nvim-store3.unload` 卸载，释放内存。
- **合并视图**：归档库已加载时，渲染层把 archived 树以 📦 + 灰色（`TodoCheckboxArchived`）显示 → 可复习/再现。
- 会话内记住是否已加载；配置项 `archive.*`（见 §7）。

---

## 6. 审视归档任务的 UX（核心回答）

**不要三选一，三者各司其职：**

1. **抽屉（drawer）—— in-context 复习**
   - 加"Include archived"开关：在当前代码行/文件的上下文里，把已归档任务一并显示（灰色）。
   - 用途：你正看某段代码，想看它的历史任务 → 这是"任务地图完整性"最直接的体现。
   - 复用 `lua/todo2/ui/drawer.lua`（per-buffer 树）。

2. **查看器 / 全局归档浏览器 —— 复习 / 再现整张地图（首要）**
   - `:TodoArchiveView` 用现有 `lua/todo2/task/viewer.lua` 树形渲染，按文件/项目分组，显示归档时间与锚点状态（ok/stale/lost），可展开整棵树。
   - 用途：重新梳理项目逻辑时的全景复习。**树结构是关键，qf 做不到**。

3. **quickfix / location list —— 批量导航 / 可查**
   - `:TodoArchiveQF` 用 `setqflist` 平铺所有存档锚点（`path:line` + 任务内容），可跳转、可 `:cdo`。
   - 复用现有 `show_project_links_qf`（`viewer.lua:236`）风格。
   - 用途：跨库批量遍历、脚本化；也天然适合"存档即数据"。

4. **（可选）picker/telescope** —— 模糊搜标题/tag/id，轻量"可查"入口。

结论：
- **树形（drawer + viewer）负责"复习/再现"**（承载任务地图）。
- **qf 负责"批量导航/可查"**（平铺、可跳转，但不承载结构）。
- **picker 负责"模糊查找"**。
- qf 单独用会丢树，不足以承载"任务地图"；但作为平铺跳转层非常合适。

---

## 7. 与现有实现 / 命令的兼容

- `:TodoArchive`（现 `ui.archive.archive_task_group`）改为执行 §3 的冷存储移动：
  - **不再** `delete_code_link`（`core/archive.lua:116` 的删除逻辑去掉，改为冻结锚点）。
  - **不再**写 `## Archived` 段。
- `core/archive.lua` / `ui/archive.lua` 重写为"标记 archived + spill 到冷库"。
- `config.archive_section`（`title_prefix`）废弃 → 新增 `config.archive`：
  - `auto_after_days`（completed 自动归档，可选，默认关）
  - `allow_unfinished`（允许未完成直接存档，默认 true）
  - `store_name = "archive"`
  - `include_in_render`（会话内是否已加载，运行时状态）
- `is_tree_completed` 门槛（`archive.lua`）改为可配。
- completed：仍在主库；新增可选"completed→archived 自动"。
- **迁移**：旧 `## Archived` 行 + store 中 `status=archived` 的任务 → 提供一次性导入（`:TodoArchiveImport`）；锚点已丢的标 `stale/lost`。

---

## 8. 风险

- **锚点漂移**：冷库不常驻，只能加载时重解析；符号改名/删除 → `stale/lost`（已有状态机制兜底）。
- **两库一致性/崩溃**：用"先写冷库 flush 成功 → 再删主库"顺序 + `flush()` 同步。
- **墓碑膨胀**：单键 map、极小；可定期清理过期墓碑（配合冷库保留策略）。
- **并发**：多 nvim 会话各自持内存副本、整体重写，外部改文件会被覆盖（nvim-store3 既有行为），冷库同理。

---

## 9. 落地顺序（建议）

1. **nvim-store3**：命名 store + `unload`/`is_loaded`（小、可独立测试）。
2. **todo2 数据层**：archive store 封装 + 墓碑 `todo.archive.index` + 锚点冻结。
3. **归档/反归档流程 + 命令**（`:TodoArchive` / `:TodoUnarchive` / `:TodoArchiveOpen`/`Close`）。
4. **渲染合并** + drawer "Include archived" + viewer/QF 入口。
5. **迁移与文档**（`:TodoArchiveImport`、README、`doc/todo2.txt`）。

---

## 10. 待确认（设计已给出建议，可 override）

1. 触发：以**批量为主、按组可选**（建议）。
2. 墓碑：**主库保留轻量墓碑**（建议，理由见 §2/§6）。
3. 未完成是否允许存档：**允许**（建议）。
4. 是否提供自动归档（`auto_after_days`）：默认关，可配（建议）。

---

## 11. 实现状态（已落地）

- **nvim-store3**：命名 store（`project({name=...})` → `projects/<key>/<name>.json`）、`unload`/`is_loaded`/`loaded_names`。
- **数据层** `lua/todo2/store/archive.lua`：墓碑 `todo.archive.index`、`open/close/count`、`spill_to_cold`（先写冷库 flush 成功再删主库）、`archive_ids`/`unarchive_ids`（恢复 `previous_status`）、`forest()`。
- **业务层** `lua/todo2/core/archive.lua`：`archive_task_group`（移行 + 删行含正文；归档前把缓冲区正文回写主库任务）、`unarchive_task_group`（按文件把树（含正文本续行）写回 `## Active` 段）、`import_legacy_archive`。
- **UI/命令**：`:TodoArchive` / `:TodoUnarchive` / `:TodoArchiveView` / `:TodoArchiveQF` / `:TodoArchiveOpen` / `:TodoArchiveClose` / `:TodoArchiveImport`。
- **渲染**：drawer `A` 切换并入归档任务（`archive.include_in_render` 为初值，关闭时卸载冷库）；viewer 归档树 / 平铺 QF。
- **配置**：`config.archive = { allow_unfinished, include_in_render, auto_after_days }`；`auto_after_days` 暂未接线（预留）。
- **未接线**：自动归档 `auto_after_days`；墓碑过期清理。
