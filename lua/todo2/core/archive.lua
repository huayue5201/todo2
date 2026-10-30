-- lua/todo2/core/archive.lua
-- 归档业务层。
--
-- 架构契约：**归档任务的唯一真相源是 TODO 文件里的 `## Archived (YYYY-MM)` 段。**
-- 「归档 / 反归档」= 把任务组的行在「活跃段」和「归档段」之间搬移，并改写复选框；
-- store 里的 `core.status = archived` / `timestamps.archived` 由 core/sync.lua 的
-- 区域变更统一推进（见 sync.lua 第 5 步）。本模块不写独立冷存储，也不修改代码文件
-- （锚点冻结，待查看归档时由 core.relocate_code_location 重解析）。

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local events = require("todo2.core.events")
local config = require("todo2.config")
local archive_utils = require("todo2.core.archive_utils")
local description = require("todo2.core.description")
local format = require("todo2.utils.format")
local tags_utils = require("todo2.utils.tags")

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

local function indent_width()
	return config.get("parser.indent_width") or 2
end

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

---按给定状态渲染任务行
---@param task table
---@param depth number
---@param status string
---@return string
local function build_task_line(task, depth, status)
	local checkbox = types.status_to_checkbox(status)
	local indent = string.rep(" ", depth * indent_width())
	return format.format_task_line({
		indent = indent,
		checkbox = checkbox,
		id = task.id,
		status = status,
		due = task.core.due,
		content = task.core.content,
		tags = task.core.tags,
	})
end

---渲染任务行 + 正文续行
---@param task table
---@param depth number
---@param status string
---@return string[]
local function build_task_lines(task, depth, status)
	local task_line = build_task_line(task, depth, status)
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

---把整棵子树按父子层级渲染成行（从 store 读取，深度归零）
---@param ids string[]
---@param status_for string|fun(task: table): string
---@return string[]
local function render_subtree(ids, status_for)
	local id_set = {}
	for _, id in ipairs(ids) do
		id_set[id] = true
	end

	local children = {}
	local roots = {}
	for _, id in ipairs(ids) do
		local parent = relation.get_parent_id(id)
		if parent and id_set[parent] then
			children[parent] = children[parent] or {}
			table.insert(children[parent], id)
		else
			table.insert(roots, id)
		end
	end

	local out = {}
	local function walk(id, depth)
		local task = core.get_task(id)
		if not task then
			return
		end
		local status = type(status_for) == "function" and status_for(task) or status_for
		for _, l in ipairs(build_task_lines(task, depth, status)) do
			out[#out + 1] = l
		end
		for _, child in ipairs(children[id] or {}) do
			walk(child, depth + 1)
		end
	end

	for _, root in ipairs(roots) do
		walk(root, 0)
	end
	return out
end

---从 buffer 把这些任务的最新内容/标签/正文刷新进 store（用户可能改了还没同步）
---@param ids string[]
---@param lines string[]
local function refresh_from_buffer(ids, lines)
	for _, id in ipairs(ids) do
		local loc = core.get_todo_location(id)
		local lnum = loc and loc.line
		if lnum and lines[lnum] and format.is_task_line(lines[lnum]) then
			local parsed = format.parse_task_line(lines[lnum])
			local task = core.get_task(id)
			if parsed and task then
				task.core.content = parsed.content
				task.core.tags = tags_utils.normalize(parsed.tags)
				local block = description.block_at(lines, lnum)
				task.core.description = (block and block.text ~= "") and block.text or nil
				core.save_task(id, task)
			end
		end
	end
end

---子树在 buffer 中占用的行区间（1-based，含正文），返回 nil 表示找不到
---@param ids string[]
---@param lines string[]
---@return number? first_line, number? last_line
local function subtree_line_range(ids, lines)
	local first, last = math.huge, 0
	for _, id in ipairs(ids) do
		local loc = core.get_todo_location(id)
		local lnum = loc and loc.line
		if lnum and lines[lnum] then
			first = math.min(first, lnum)
			local block = description.block_at(lines, lnum)
			last = math.max(last, block and block.end_line or lnum)
		end
	end
	if last == 0 then
		return nil
	end
	return first, last
end

---从 lines 中移除 [a, b]
local function remove_range(lines, a, b)
	for i = b, a, -1 do
		if lines[i] then
			table.remove(lines, i)
		end
	end
end

---`## Active` 段内的插入行号（1-based，插到该行之后）；找不到返回 #lines
---@param lines string[]
---@return number
local function active_insert_index(lines)
	local active_start
	for i, line in ipairs(lines) do
		if line:match("^##%s+Active") then
			active_start = i
			break
		end
	end
	if not active_start then
		return #lines
	end

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

---最后一个归档段的区间（1-based，含标题行）；没有归档段返回 nil
---@param lines string[]
---@return number? start_line, number? end_line
local function last_archive_section(lines)
	local start
	for i, line in ipairs(lines) do
		if archive_utils.is_archive_section_line(line) then
			start = i
		end
	end
	if not start then
		return nil
	end

	local finish = #lines
	for i = start + 1, #lines do
		if lines[i]:match("^## ") then
			finish = i - 1
			break
		end
	end
	return start, finish
end

---在 idx 之后插入一批行
local function insert_lines(lines, idx, block)
	for i = #block, 1, -1 do
		table.insert(lines, idx + 1, block[i])
	end
end

---获取 buffer 行（优先已加载 buffer）
local function buffer_lines(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---应用改动到 buffer：写回 + 落盘 + 同步 store（推进区域变更）
local function apply_changes(bufnr, path, lines)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	require("todo2.core.autosave").request_save(bufnr)
	require("todo2.core.sync").sync_todo_file(path)
end

---打开并校验任务所属 TODO 文件
---@param task table
---@return number? bufnr, string? path, string? err
local function open_task_file(task)
	local loc = task.locations and task.locations.todo
	if not loc or not loc.path then
		return nil, nil, "Task has no TODO location"
	end
	local path = loc.path
	local bufnr = vim.fn.bufadd(path)
	require("todo2.utils.buffer").ensure_loaded(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, nil, "Cannot load TODO file"
	end
	return bufnr, path, nil
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---归档任务组：把整棵子树的行移入 `## Archived` 段并改写为 [>]。
---@param root_id string 根任务ID
---@param opts? { force?: boolean } force=true 时忽略完成状态
---@return boolean, string, table?
function M.archive_task_group(root_id, opts)
	opts = opts or {}

	if not root_id then
		return false, "Invalid argument", nil
	end

	local root_task = core.get_task(root_id)
	if not root_task then
		return false, "Task not found", nil
	end

	local bufnr, path, err = open_task_file(root_task)
	if not bufnr then
		return false, err, nil
	end

	local allow_unfinished = config.get("archive.allow_unfinished", true)
	if not opts.force and not allow_unfinished and not is_tree_completed(root_id) then
		return false, "The task group has unfinished tasks", nil
	end

	local all_ids = relation.get_subtree_ids(root_id)
	if #all_ids == 0 then
		return false, "No tasks to archive", nil
	end

	local lines = buffer_lines(bufnr)
	refresh_from_buffer(all_ids, lines)
	lines = buffer_lines(bufnr)

	local first, last = subtree_line_range(all_ids, lines)
	if not first then
		return false, "Tasks not found in TODO file", nil
	end

	-- 1. 摘除源行
	remove_range(lines, first, last)

	-- 2. 渲染归档块（[>]）
	local block = render_subtree(all_ids, types.STATUS.ARCHIVED)

	-- 3. 追加到最后一个归档段；没有则新建
	local _, sec_end = last_archive_section(lines)
	if sec_end then
		insert_lines(lines, sec_end, block)
	else
		lines[#lines + 1] = ""
		lines[#lines + 1] = archive_utils.build_archive_title()
		insert_lines(lines, #lines, block)
	end

	apply_changes(bufnr, path, lines)

	-- 4. 事件（显式带上被归档任务的代码文件与旧位置，供代码端清标记）
	local files = { path }
	local deleted_locations = {}
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		local loc = task and task.locations or {}
		local code = loc.code
		if code and code.path then
			if not vim.tbl_contains(files, code.path) then
				table.insert(files, code.path)
			end
			table.insert(deleted_locations, { path = code.path, line = code.line })
		end
		if loc.todo and loc.todo.path then
			table.insert(deleted_locations, { path = loc.todo.path, line = loc.todo.line })
		end
	end
	events.emit("archive_group", {
		bufnr = bufnr,
		file = path,
		files = files,
		changed_ids = all_ids,
		deleted_locations = deleted_locations,
	})

	return true,
		string.format("Archived %d tasks", #all_ids),
		{
			root_id = root_id,
			total_tasks = #all_ids,
			archived_ids = all_ids,
		}
end

---反归档：把归档任务组从 `## Archived` 段移回活跃段并还原复选框。
---@param ids string[] 要恢复的任务 id（应为一个完整子树）
---@return boolean, string, table?
function M.unarchive_task_group(ids)
	if not ids or #ids == 0 then
		return false, "No tasks to unarchive", nil
	end

	local id_set = {}
	for _, id in ipairs(ids) do
		id_set[id] = true
	end

	-- 根：id 集合里没有祖先的那一个
	local root_id
	for _, id in ipairs(ids) do
		local parent = relation.get_parent_id(id)
		if not (parent and id_set[parent]) then
			root_id = id
			break
		end
	end
	root_id = root_id or ids[1]

	local root_task = core.get_task(root_id)
	if not root_task then
		return false, "Task not found", nil
	end

	local bufnr, path, err = open_task_file(root_task)
	if not bufnr then
		return false, err, nil
	end

	local lines = buffer_lines(bufnr)

	-- 找到归档段内的源行
	local sec_start, sec_end = last_archive_section(lines)
	if not sec_start then
		return false, "No archive section in TODO file", nil
	end

	local first, last = subtree_line_range(ids, lines)
	if not first or first < sec_start or first > sec_end then
		return false, "Tasks not found in archive section", nil
	end

	remove_range(lines, first, last)

	-- 还原状态：退出终态时 sync 会用 previous_status，这里渲染同样的值
	local status_domain = require("todo2.core.status")
	local block = render_subtree(ids, function(task)
		local prev = task.core.previous_status
		if prev and prev ~= types.STATUS.ARCHIVED then
			return prev
		end
		return status_domain.get_default()
	end)

	local idx = active_insert_index(lines)
	insert_lines(lines, idx, block)

	apply_changes(bufnr, path, lines)

	events.emit("unarchive_group", {
		files = { path },
		changed_ids = ids,
	})

	return true, string.format("Unarchived %d tasks", #ids), {
		unarchived_ids = ids,
		total_tasks = #ids,
	}
end

return M
