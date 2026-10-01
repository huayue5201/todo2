-- lua/todo2/core/sync.lua
-- 同步模块：负责将文件结构同步到存储，处理任务关系、区域变化等
---@module "todo2.core.sync"

local M = {}

local parser = require("todo2.core.parser")
local core = require("todo2.store.task.core")
local index = require("todo2.store.index")
local relation = require("todo2.store.task.relation")
local types = require("todo2.store.types")
local status_domain = require("todo2.core.status")
local file = require("todo2.utils.file")
local id_utils = require("todo2.utils.id")
local description = require("todo2.core.description")
local autosave = require("todo2.core.autosave")

-- 防抖定时器
local debounce_timers = {}

---------------------------------------------------------------------
-- 同步结果类型
---------------------------------------------------------------------

---@class SyncResult
---@field changed_ids string[] 变更的任务ID列表
---@field added string[] 新增的任务ID列表
---@field removed string[] 删除的任务ID列表
---@field region_changed table<string, string[]> 区域变更的任务，按区域分组

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---构建文件树节点
---@param task table 解析出的任务
---@return table? 文件树节点
local function build_tree_node(task)
	if not task or not task.id then
		return nil
	end

	return {
		id = task.id,
		line = task.line_num,
		level = task.level or 0,
		region = task.region_type or "main",
		children = vim.tbl_map(build_tree_node, task.children or {}),
	}
end

---更新任务位置
---@param raw_task table 解析出的原始任务
---@param path string 文件路径
---@return boolean 是否更新
local function update_task_location(raw_task, path)
	if not raw_task or not raw_task.id then
		return false
	end

	local task = core.get_task(raw_task.id)
	if not task then
		-- 从 checkbox 推导初始状态（[x] → 完成，[>] → 归档，[ ] → 默认循环状态）
		local status = status_domain.resolve_checkbox((raw_task.checkbox or ""):lower())

		-- 新任务
		core.create_task({
			id = raw_task.id,
			content = raw_task.content,
			description = raw_task.description,
			status = status,
			todo_path = path,
			todo_line = raw_task.line_num,
		})
		return true
	end

	-- 更新位置
	local changed = false

	if not task.locations.todo then
		task.locations.todo = {}
	end

	if task.locations.todo.path ~= path then
		task.locations.todo.path = path
		changed = true
	end

	if task.locations.todo.line ~= raw_task.line_num then
		task.locations.todo.line = raw_task.line_num
		changed = true
	end

	-- 更新内容（用户可能修改了文本）
	if task.core.content ~= raw_task.content then
		task.core.content = raw_task.content
		changed = true
	end

	-- 更新正文（用户可能改了描述；空正文不占字段）
	local raw_desc = raw_task.description or ""
	if (task.core.description or "") ~= raw_desc then
		task.core.description = raw_desc ~= "" and raw_desc or nil
		changed = true
	end

	if changed then
		task.timestamps.updated = os.time()
		core.save_task(raw_task.id, task)
	end

	return changed
end

---更新父子关系
---@param raw_tasks table[] 解析出的原始任务列表
---@return string[] 关系变更的任务ID
local function update_relations(raw_tasks)
	local changed_ids = {}

	-- 先收集所有父子关系
	local relations = {}
	for _, task in ipairs(raw_tasks) do
		if task.id and task.parent and task.parent.id then
			relations[task.id] = task.parent.id
		end
	end

	-- 批量更新关系
	for child_id, parent_id in pairs(relations) do
		local current_parent = relation.get_parent_id(child_id)
		if current_parent ~= parent_id then
			if current_parent then
				relation.remove_child(current_parent, child_id)
			end
			relation.set_parent_child(parent_id, child_id)
			table.insert(changed_ids, child_id)
		end
	end

	-- 处理根任务（确保没有父任务）
	for _, task in ipairs(raw_tasks) do
		if task.id and not relations[task.id] then
			local current_parent = relation.get_parent_id(task.id)
			if current_parent then
				relation.remove_child(current_parent, task.id)
				table.insert(changed_ids, task.id)
			end
		end
	end

	return changed_ids
end

---检测区域变化
---@param raw_tasks table[] 解析出的原始任务列表
---@return table<string, string[]> 区域变更的任务，按新区域分组
local function detect_region_changes(raw_tasks)
	local changes = {
		["main"] = {},
		["archive"] = {},
	}

	for _, raw in ipairs(raw_tasks) do
		if raw.id then
			local task = core.get_task(raw.id)
			if task then
				local old_region = task.region_type or "main"
				local new_region = raw.region_type or "main"

				if old_region ~= new_region then
					table.insert(changes[new_region], raw.id)
				end
			end
		end
	end

	return changes
end

---处理被删除的任务
---@param old_set table<string, boolean> 旧ID集合
---@param new_set table<string, boolean> 新ID集合
---@return string[] 删除的任务ID
--- 处理「文件中已消失」的任务。
---
--- 安全约束：
---   * 调用方已保证文件读取成功（读失败不会走到这里，避免把“读不到”
---     当成“任务被删”而批量误删）
---   * 只处理索引中属于本文件的任务
--- 策略：解除 TODO 定位；若仍被代码引用则保留，否则整条删除。
---@param old_set table<string, boolean>
---@param new_set table<string, boolean>
---@param path string
---@return string[] removed 被移除的任务 ID
local function handle_removed_tasks(old_set, new_set, path)
	local removed = {}

	for id in pairs(old_set) do
		if not new_set[id] then
			table.insert(removed, id)

			local task = core.get_task(id)
			if not task then
				-- 任务记录已不存在，只清理索引残留
				index._internal.remove_todo_id(path, id)
			elseif task.locations and task.locations.code then
				-- 仍被代码引用：只解除 TODO 定位，保留任务
				index._internal.remove_todo_id(path, id)
				task.locations.todo = nil
				task.timestamps = task.timestamps or {}
				task.timestamps.updated = os.time()
				core.save_task(id, task)
			else
				-- 只存在于 TODO 文件：整条删除（含 ctx / 索引 / 父子关系）
				core.delete_task(id)
			end
		end
	end

	return removed
end

---构建并更新文件树
---@param path string 文件路径
---@param roots table[] 根任务列表
local function update_file_tree(path, roots)
	local tree_roots = {}
	for _, root in ipairs(roots) do
		local node = build_tree_node(root)
		if node then
			table.insert(tree_roots, node)
		end
	end
	index.update_file_tree(path, tree_roots)
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

--- 清理「任务行已消失、正文块却还留着」的悬空正文。
--- 不做的话，这些缩进续行会被 parser 当作“上一个任务的正文”静默接管。
--- 用 store 里保存的正文文本按行指纹定位；找不到（内容已改）就不动。
---@param path string
---@param lines string[]
---@return boolean 是否发生了修改
local function repair_orphan_bodies(path, lines)
	local old_ids = index.get_file_task_ids(path)
	if #old_ids == 0 then
		return false
	end

	local present = {}
	for _, line in ipairs(lines) do
		local id = id_utils.extract_id_from_line(line)
		if id then
			present[id] = true
		end
	end

	local runs = {}
	for _, id in ipairs(old_ids) do
		if not present[id] then
			local task = core.get_task(id)
			local loc = task and task.locations and task.locations.todo
			local desc = task and task.core.description
			if desc and desc ~= "" and loc and file.normalize_path(loc.path) == file.normalize_path(path) then
				local s, e = description.find_run(lines, desc, math.max(1, tonumber(loc.line) or 1))
				if s then
					table.insert(runs, { s, e })
				end
			end
		end
	end

	if #runs == 0 then
		return false
	end

	-- 从后往前删，避免行号变化
	table.sort(runs, function(a, b)
		return a[1] > b[1]
	end)

	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	for _, r in ipairs(runs) do
		pcall(vim.api.nvim_buf_set_lines, bufnr, r[1] - 1, r[2], false, {})
	end
	autosave.request_save(bufnr)
	return true
end

---同步TODO文件
---@param path string 文件路径
---@return SyncResult 同步结果
function M.sync_todo_file(path)
	if not path or path == "" then
		return { changed_ids = {}, added = {}, removed = {}, region_changed = {} }
	end

	-- 1. 重新解析文件（优先从已加载的 buffer 读取，避免删除/编辑后同步到磁盘旧数据）
	-- 读取失败（nil）时直接放弃同步：绝不能把“读不到内容”当成“所有任务都被删”
	local lines = file.read_lines_smart(path)
	if not lines then
		return { changed_ids = {}, added = {}, removed = {}, region_changed = {} }
	end

	-- 先修掉悬空正文（任务行已不在但正文还留着），再按清理后的内容解析
	if repair_orphan_bodies(path, lines) then
		lines = file.read_lines_smart(path) or lines
	end

	local raw_tasks, roots, id_to_raw, archive_trees = parser.parse_lines(path, lines)

	-- 2. 获取当前存储中的任务ID
	local old_ids = index.get_file_task_ids(path)
	local old_set = {}
	for _, id in ipairs(old_ids) do
		old_set[id] = true
	end

	-- 3. 收集新任务ID并更新位置
	local new_ids = {}
	local new_set = {}
	local updated_ids = {}

	for _, raw in ipairs(raw_tasks) do
		if raw.id then
			table.insert(new_ids, raw.id)
			new_set[raw.id] = true

			local changed = update_task_location(raw, path)
			if changed then
				table.insert(updated_ids, raw.id)
			end
		end
	end

	-- 归档区里的任务仍然存在，只是不在 main 区；必须计入 new_set，
	-- 否则 handle_removed_tasks 会把已归档任务的 store 记录删掉。
	for _, tree in pairs(archive_trees or {}) do
		for id in pairs(tree.id_to_task or {}) do
			new_set[id] = true
		end
	end

	-- 4. 检测区域变化
	local region_changes = detect_region_changes(raw_tasks)

	-- 5. 处理区域变化（归档/恢复）
	for region, ids in pairs(region_changes) do
		if #ids > 0 then
			if region == "archive" then
				-- 移入归档区
				for _, id in ipairs(ids) do
					local task = core.get_task(id)
					if task then
						task.region_type = "archive"
						status_domain.enter_terminal(task, types.STATUS.ARCHIVED)
						core.save_task(id, task)
					end
				end
			else
				-- 移出归档区
				for _, id in ipairs(ids) do
					local task = core.get_task(id)
					if task then
						task.region_type = "main"
						status_domain.exit_terminal(task)
						core.save_task(id, task)
					end
				end
			end
		end
	end

	-- 6. 更新父子关系
	local relation_changed = update_relations(raw_tasks)

	-- 7. 处理被删除的任务
	local removed_ids = handle_removed_tasks(old_set, new_set, path)

	-- 8. 更新文件树
	update_file_tree(path, roots)

	-- 9. 收集所有变更的ID
	local changed_ids = {}
	for _, id in ipairs(updated_ids) do
		table.insert(changed_ids, id)
	end
	for _, id in ipairs(relation_changed) do
		if not vim.tbl_contains(changed_ids, id) then
			table.insert(changed_ids, id)
		end
	end
	for _, ids in pairs(region_changes) do
		for _, id in ipairs(ids) do
			if not vim.tbl_contains(changed_ids, id) then
				table.insert(changed_ids, id)
			end
		end
	end

	-- 10. 返回结果
	return {
		changed_ids = changed_ids,
		added = new_ids,
		removed = removed_ids,
		region_changed = region_changes,
	}
end

---清理定时器
---@param bufnr number 缓冲区号
function M.cleanup(bufnr)
	if bufnr and debounce_timers[bufnr] then
		debounce_timers[bufnr]:stop()
		debounce_timers[bufnr]:close()
		debounce_timers[bufnr] = nil
	end
end

return M
