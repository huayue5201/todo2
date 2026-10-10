-- lua/todo2/core/archive.lua
-- 归档业务层：把任务组「移动」到独立冷存储（store.archive），并从主 TODO 文件移除其行。
-- 归档 = 存档，不是丢弃；可逆（见 M.unarchive_task_group）。绝不修改代码文件，锚点冻结，
-- 待归档库加载时由 core.relocate_code_location 重解析。

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local store_archive = require("todo2.store.archive")
local events = require("todo2.core.events")
local format = require("todo2.utils.format")
local description = require("todo2.core.description")
local config = require("todo2.config")

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

---判断任务组是否全部完成
---@param root_id string
---@return boolean
local function is_tree_completed(root_id)
	for _, id in ipairs(relation.get_subtree_ids(root_id)) do
		local task = core.get_task(id)
		if not task or not types.is_completed_status(task.core.status) then
			return false
		end
	end
	return true
end

---收集子树每一行的位置（用于从文件移除），并捕获正文文本
---@param ids string[]
---@param lines string[]
---@return table[]
local function collect_line_items(ids, lines)
	local items = {}

	for _, id in ipairs(ids) do
		local loc = core.get_todo_location(id)
		if loc and loc.line and lines[loc.line] then
			local desc_lines, desc_end, desc_text
			local block = description.block_at(lines, loc.line)
			if block then
				desc_lines = {}
				for i = block.start_line, block.end_line do
					desc_lines[#desc_lines + 1] = lines[i]
				end
				desc_end = block.end_line
				desc_text = block.text
			end
			items[#items + 1] = {
				id = id,
				original_line = loc.line,
				desc_end = desc_end,
				desc_text = desc_text,
			}
		end
	end

	return items
end

---把缓冲区里的正文文本回写进主库任务（避免依赖自动同步时序）
---@param items table[]
local function persist_captured_descriptions(items)
	for _, item in ipairs(items) do
		if item.desc_text and item.desc_text ~= "" then
			local task = core.get_task(item.id)
			if task then
				task.core.description = item.desc_text
				core.save_task(item.id, task)
			end
		end
	end
end

---从缓冲区移除这些行（从后往前，正文先删）
---@param bufnr number
---@param items table[]
local function remove_line_items(bufnr, items)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	table.sort(items, function(a, b)
		return a.original_line > b.original_line
	end)
	for _, item in ipairs(items) do
		if item.desc_end then
			for lnum = item.desc_end, item.original_line + 1, -1 do
				if lines[lnum] then
					table.remove(lines, lnum)
				end
			end
		end
		if lines[item.original_line] then
			table.remove(lines, item.original_line)
		end
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

---按状态给任务生成 TODO 行
---@param task table
---@param depth number
---@return string
local function build_task_line(task, depth)
	local checkbox = types.status_to_checkbox(task.core.status)
	local indent = string.rep(" ", depth * (config.get("parser.indent_width") or 2))
	return format.format_task_line({
		indent = indent,
		checkbox = checkbox,
		id = task.id,
		status = task.core.status,
		content = task.core.content,
		tags = task.core.tags,
	})
end

---把任务渲染成行列表（任务行 + 其正文续行）
---@param task table
---@param depth number
---@return string[]
local function build_task_lines(task, depth)
	local task_line = build_task_line(task, depth)
	local out = { task_line }
	local desc = task.core and task.core.description
	if desc and desc ~= "" then
		local indent = string.rep(" ", description.content_indent(task_line))
		for _, l in ipairs(description.to_lines(desc, indent)) do
			out[#out + 1] = l
		end
	end
	return out
end

---计算把任务追加到 `## Active` 段内的插入位置（0-based，插入到该行之前）。
---找不到 Active 段时返回 #lines（追加到末尾）。
---@param lines string[]
---@return number
local function active_insert_index(lines)
	local active_start = nil
	for i, line in ipairs(lines) do
		if line:match("^##%s+Active") then
			active_start = i
			break
		end
	end
	if not active_start then
		return #lines
	end

	-- Active 段结束于下一个 `## ` 段头（或文件末尾）；插到其后最后一行非空行的后面
	local insert_after = active_start
	for i = active_start + 1, #lines do
		if lines[i]:match("^## ") then
			break
		end
		if vim.trim(lines[i]) ~= "" then
			insert_after = i
		end
	end
	return insert_after
end

---把一批任务按父子层级写成行，追加到 TODO 文件末尾
---@param path string
---@param tasks table[]
local function insert_tasks_into_file(path, tasks)
	local id_set = {}
	for _, t in ipairs(tasks) do
		id_set[t.id] = true
	end

	-- 建立一个 id -> task 映射，按层级排序输出
	local by_id = {}
	for _, t in ipairs(tasks) do
		by_id[t.id] = t
	end

	local roots = {}
	local children = {}
	for _, t in ipairs(tasks) do
		local parent = relation.get_parent_id(t.id)
		if parent and id_set[parent] then
			children[parent] = children[parent] or {}
			table.insert(children[parent], t)
		else
			table.insert(roots, t)
		end
	end

	local out = {}
	local function walk(task, depth)
		for _, l in ipairs(build_task_lines(task, depth)) do
			out[#out + 1] = l
		end
		for _, child in ipairs(children[task.id] or {}) do
			walk(child, depth + 1)
		end
	end
	for _, root in ipairs(roots) do
		walk(root, 0)
	end

	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 插入到 `## Active` 段内（默认文件模板的第一个段）
	local idx = active_insert_index(lines)
	vim.api.nvim_buf_set_lines(bufnr, idx, idx, false, out)
	require("todo2.core.autosave").request_save(bufnr)
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---归档任务组：把整棵子树移入冷存储，并从 TODO 文件删除对应行。
---始终在任务所属的 TODO 文件上操作（从 store 解析路径），不依赖当前 buffer。
---@param root_id string 根任务ID
---@param opts? { force?: boolean } force=true 时忽略完成状态
---@return boolean, string, table?
function M.archive_task_group(root_id, opts)
	opts = opts or {}

	if not root_id then
		return false, "Invalid argument", nil
	end

	local root_task = core.get_task(root_id)
	if not root_task or not root_task.locations.todo or not root_task.locations.todo.path then
		return false, "Task has no TODO location", nil
	end

	local path = root_task.locations.todo.path
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "Cannot load TODO file", nil
	end

	local allow_unfinished = config.get("archive.allow_unfinished", true)
	if not opts.force and not allow_unfinished and not is_tree_completed(root_id) then
		return false, "The task group has unfinished tasks", nil
	end

	local all_ids = relation.get_subtree_ids(root_id)
	if #all_ids == 0 then
		return false, "No tasks to archive", nil
	end

	-- 归档前记录行位置（归档后主库已无这些任务），并把正文回写进任务
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local line_items = collect_line_items(all_ids, lines)
	persist_captured_descriptions(line_items)

	-- 1. 移入冷存储（先写冷库落盘，再删主库）
	local ok, msg, tasks = store_archive.archive_ids(all_ids)
	if not ok then
		return false, msg, nil
	end

	-- 2. 从 TODO 文件移除行（含正文）
	remove_line_items(bufnr, line_items)
	require("todo2.core.autosave").request_save(bufnr)

	-- 3. 事件
	events.emit("archive_group", {
		bufnr = bufnr,
		file = path,
		files = { path },
		changed_ids = all_ids,
	})

	return true, msg, {
		root_id = root_id,
		total_tasks = #tasks,
		archived_ids = all_ids,
	}
end

---反归档：把归档任务恢复到主库，并写回 TODO 文件。
---@param ids string[] 要恢复的任务 id（应为一个完整子树）
---@return boolean, string, table?
function M.unarchive_task_group(ids)
	if not ids or #ids == 0 then
		return false, "No tasks to unarchive", nil
	end

	local ok, msg, tasks = store_archive.unarchive_ids(ids)
	if not ok then
		return false, msg, nil
	end

	-- 按 TODO 文件分组写回
	local by_file = {}
	for _, t in ipairs(tasks) do
		local loc = t.locations and t.locations.todo
		local path = loc and loc.path
		if path then
			by_file[path] = by_file[path] or {}
			table.insert(by_file[path], t)
		end
	end

	for path, list in pairs(by_file) do
		insert_tasks_into_file(path, list)
	end

	events.emit("unarchive_group", {
		files = vim.tbl_keys(by_file),
		changed_ids = ids,
	})

	return true, msg, { unarchived_ids = ids, total_tasks = #tasks }
end

---导入旧 `## Archived` 段中的归档任务：把它们从主库移入冷存储，并从文件移除对应行。
---用于一次性迁移兼容期数据。
---@return boolean, string, table?
function M.import_legacy_archive()
	local store = require("todo2.store.nvim_store")

	local all_ids = store.get_namespace_keys("todo.tasks") or {}
	local archived = {}
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task and task.core.status == types.STATUS.ARCHIVED then
			archived[#archived + 1] = id
		end
	end

	if #archived == 0 then
		return false, "No legacy archived tasks found", nil
	end

	-- 按 TODO 文件分组
	local by_file = {}
	for _, id in ipairs(archived) do
		local loc = core.get_todo_location(id)
		local path = loc and loc.path
		if path then
			by_file[path] = by_file[path] or {}
			table.insert(by_file[path], id)
		end
	end

	local total = 0
	for path, file_ids in pairs(by_file) do
		local bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local line_items = collect_line_items(file_ids, lines)
		persist_captured_descriptions(line_items)

		local ok, _, tasks = store_archive.archive_ids(file_ids)
		if ok then
			remove_line_items(bufnr, line_items)
			require("todo2.core.autosave").request_save(bufnr)
			total = total + #tasks
		end
	end

	events.emit("archive_import", { count = total })
	return true, string.format("Imported %d archived tasks", total), { total_tasks = total }
end

return M
