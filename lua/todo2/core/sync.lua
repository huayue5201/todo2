-- lua/todo2/core/sync.lua
-- 同步模块：负责将文件结构同步到存储，处理任务关系、区域变化等
---@module "todo2.core.sync"

local M = {}

local parser = require("todo2.core.parser")
local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local relation = require("todo2.store.link.relation")
local events = require("todo2.core.events")
local types = require("todo2.store.types")
local id_utils = require("todo2.utils.id")

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
		-- 新任务
		core.create_task({
			id = raw_task.id,
			content = raw_task.content,
			tags = { raw_task.tag or "TODO" },
			todo_path = path,
			todo_line = raw_task.line_num,
			region_type = raw_task.region_type or "main",
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

	-- 更新标签
	if raw_task.tag and (not task.core.tags or task.core.tags[1] ~= raw_task.tag) then
		task.core.tags = { raw_task.tag }
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
local function handle_removed_tasks(old_set, new_set)
	local removed = {}

	for id, _ in pairs(old_set) do
		if not new_set[id] then
			table.insert(removed, id)
			-- 任务被删除，可以选择归档
			-- core.delete_task(id) 或 archive.mark_archived(id)
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

---同步TODO文件
---@param path string 文件路径
---@return SyncResult 同步结果
function M.sync_todo_file(path)
	if not path or path == "" then
		return { changed_ids = {}, added = {}, removed = {}, region_changed = {} }
	end

	-- 1. 重新解析文件
	local lines = vim.fn.readfile(path)
	local raw_tasks, roots, id_to_raw = parser.parse_lines(path, lines)

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
						task.core.previous_status = task.core.status
						task.core.status = types.STATUS.ARCHIVED
						task.timestamps.archived = os.time()
						core.save_task(id, task)
					end
				end
			else
				-- 移出归档区
				for _, id in ipairs(ids) do
					local task = core.get_task(id)
					if task then
						task.region_type = "main"
						if task.core.previous_status then
							task.core.status = task.core.previous_status
							task.core.previous_status = nil
						end
						task.timestamps.archived = nil
						core.save_task(id, task)
					end
				end
			end
		end
	end

	-- 6. 更新父子关系
	local relation_changed = update_relations(raw_tasks)

	-- 7. 处理被删除的任务
	local removed_ids = handle_removed_tasks(old_set, new_set)

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

---同步代码文件（扫描ID）
---@param path string 文件路径
---@param bufnr number 缓冲区号
---@return string[] 扫描到的任务ID
function M.sync_code_file(path, bufnr)
	local ids = {}
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for _, line in ipairs(lines) do
		local id = id_utils.extract_id_from_code_mark(line)
		if id then
			table.insert(ids, id)
		end
	end

	return ids
end

---自动同步（带防抖）
---@param bufnr number 缓冲区号
---@param callback? fun(result: SyncResult) 回调函数
function M.auto_sync(bufnr, callback)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path:match("%.todo%.md$") then
		return
	end

	-- 取消之前的定时器
	if debounce_timers[bufnr] then
		debounce_timers[bufnr]:stop()
		debounce_timers[bufnr]:close()
	end

	-- 创建新的定时器（500ms防抖）
	debounce_timers[bufnr] = vim.loop.new_timer()
	debounce_timers[bufnr]:start(
		500,
		0,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				local result = M.sync_todo_file(path)

				-- 触发事件
				if #result.changed_ids > 0 then
					events.on_state_changed({
						source = "auto_sync",
						file = path,
						bufnr = bufnr,
						changed_ids = result.changed_ids,
					})
				end

				if callback then
					callback(result)
				end
			end
			debounce_timers[bufnr] = nil
		end)
	)
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

---强制同步所有打开的TODO文件
---@return table<string, SyncResult> 每个文件的同步结果
function M.sync_all()
	local results = {}

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path:match("%.todo%.md$") then
				results[path] = M.sync_todo_file(path)
			end
		end
	end

	return results
end

return M
