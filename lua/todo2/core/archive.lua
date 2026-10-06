-- lua/todo2/core/archive.lua
-- 归档业务层：把任务行（连同正文）移动到归档区，并删除其代码链接。
-- 原则：归档只操作 TODO 文件与 store，绝不修改代码文件；不支持撤销。

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local events = require("todo2.core.events")
local format = require("todo2.utils.format")
local description = require("todo2.core.description")
local archive_utils = require("todo2.core.archive_utils")
local status_domain = require("todo2.core.status")

---------------------------------------------------------------------
-- 缓冲区 / 归档行编辑
---------------------------------------------------------------------

---获取缓冲区行（优先从缓冲区读取）
---@param bufnr number 缓冲区号
---@return string[]|nil
local function get_buffer_lines(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---查找或创建归档区域
---@param bufnr number 缓冲区号
---@param lines string[] 文件行
---@return number, string[]
local function find_or_create_archive_section(bufnr, lines)
	local title = archive_utils.build_archive_title()

	for i, line in ipairs(lines) do
		if archive_utils.is_archive_section_line(line) then
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point]:match("^%s*$") do
				insert_point = insert_point + 1
			end
			return insert_point, lines
		end
	end

	table.insert(lines, "")
	table.insert(lines, title)

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines + 1, lines
end

---移动行到归档区域
---@param bufnr number 缓冲区号
---@param tasks_to_move table[] 要移动的任务行
---@param archive_start number 归档区域起始行
---@param lines string[] 文件行
---@return table[]
local function move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	-- 从原位置删除（从后往前删，避免索引变化）；正文行号更大，先删
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	for _, item in ipairs(tasks_to_move) do
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

	-- 重新按原顺序插入归档区域
	table.sort(tasks_to_move, function(a, b)
		return a.original_line < b.original_line
	end)

	local insert_pos = archive_start
	for _, item in ipairs(tasks_to_move) do
		if item.original_line < archive_start then
			insert_pos = insert_pos - (1 + #(item.desc_lines or {}))
		end
	end

	local pos = insert_pos
	for _, item in ipairs(tasks_to_move) do
		table.insert(lines, pos, item.line)
		item.new_line_num = pos
		pos = pos + 1
		for _, dl in ipairs(item.desc_lines or {}) do
			table.insert(lines, pos, dl)
			pos = pos + 1
		end
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return tasks_to_move
end

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---删除任务在存储中的代码链接（只动 store，不碰代码文件）
---@param id string 任务ID
local function delete_code_link(id)
	local task = core.get_task(id)
	if not task or not task.locations.code then
		return
	end

	local index = require("todo2.store.index")
	if task.locations.code.path then
		pcall(index._internal.remove_code_id, task.locations.code.path, id)
	end

	task.locations.code = nil
	task.timestamps.updated = os.time()
	core.save_task(id, task)
end

---收集任务树所有节点ID（统一由 relation 提供）
local collect_tree_node_ids = relation.get_subtree_ids

---判断任务组是否全部完成
---@param root_id string 根任务ID
---@return boolean
local function is_tree_completed(root_id)
	local all_ids = collect_tree_node_ids(root_id)

	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if not task or not types.is_completed_status(task.core.status) then
			return false
		end
	end
	return true
end

---收集要移动的行（任务行 + 正文块），并把 checkbox 统一改成 [>]
---@param root_id string 根任务ID
---@param lines string[] 文件行
---@return table[]
local function collect_lines_to_move(root_id, lines)
	local result = {}
	local all_ids = collect_tree_node_ids(root_id)

	-- 按行号排序
	table.sort(all_ids, function(a, b)
		local a_loc = core.get_todo_location(a)
		local b_loc = core.get_todo_location(b)
		return (a_loc and a_loc.line or 0) < (b_loc and b_loc.line or 0)
	end)

	for _, id in ipairs(all_ids) do
		local loc = core.get_todo_location(id)
		if loc and loc.line then
			local line = lines[loc.line]
			if line then
				local ancestors = relation.get_ancestors(id)
				local level = #ancestors
				local parent_id = ancestors[#ancestors]

				-- 归档行：复选框改 [>]，标记前缀改 archived
				local archived_line
				local parsed = format.parse_task_line(line)
				if parsed and parsed.id then
					archived_line = format.format_task_line({
						indent = parsed.indent,
						checkbox = "[>]",
						id = parsed.id,
						status = types.STATUS.ARCHIVED,
						tags = parsed.tags,
						content = parsed.content,
					})
				else
					archived_line = line:gsub("%[[xX]%]", "[>]"):gsub("%[%s%]", "[>]")
				end

				-- 正文与任务强绑定：连同正文块一起搬（归档区保留原缩进）
				local desc_lines, desc_end
				local block = description.block_at(lines, loc.line)
				if block then
					desc_lines = {}
					for i = block.start_line, block.end_line do
						desc_lines[#desc_lines + 1] = lines[i]
					end
					desc_end = block.end_line
				end

				table.insert(result, {
					line = archived_line,
					original_line = loc.line,
					desc_lines = desc_lines,
					desc_end = desc_end,
					id = id,
					level = level,
					parent_id = parent_id,
				})
			end
		end
	end

	return result
end

---更新任务行号
---@param tasks_to_move table[] 移动后的任务行
local function update_task_lines(tasks_to_move)
	for _, item in ipairs(tasks_to_move) do
		if item.id then
			local task = core.get_task(item.id)
			if task and task.locations.todo then
				task.locations.todo.line = item.new_line_num
				task.timestamps.updated = os.time()
				core.save_task(item.id, task)
			end
		end
	end
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---归档任务组：把任务行移到归档区，并删除其代码链接。
---始终在任务所属的 TODO 文件上操作（从 store 解析路径），不依赖当前 buffer，
---因此从代码文件触发也不会误改代码文件。
---@param root_id string 根任务ID
---@param opts? { force?: boolean } force=true 时忽略完成状态
---@return boolean, string, table?
function M.archive_task_group(root_id, opts)
	opts = opts or {}

	if not root_id then
		return false, "参数错误", nil
	end

	-- 从 store 解析 TODO 文件（而非当前 buffer）
	local root_task = core.get_task(root_id)
	if not root_task or not root_task.locations.todo or not root_task.locations.todo.path then
		return false, "任务没有 TODO 位置", nil
	end

	local path = root_task.locations.todo.path
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "无法加载 TODO 文件", nil
	end

	-- 校验完成状态（除非强制）
	if not opts.force and not is_tree_completed(root_id) then
		return false, "任务组中存在未完成的任务", nil
	end

	local lines = get_buffer_lines(bufnr)
	if not lines or #lines == 0 then
		return false, "文件内容为空", nil
	end

	local all_ids = collect_tree_node_ids(root_id)
	if #all_ids == 0 then
		return false, "没有可归档的任务", nil
	end

	-- 1. 删除代码链接（只动 store 与索引，不碰代码文件）
	for _, id in ipairs(all_ids) do
		delete_code_link(id)
	end

	-- 2. 收集并移动 TODO 行（任务行 + 正文）
	local tasks_to_move = collect_lines_to_move(root_id, lines)
	if #tasks_to_move == 0 then
		return false, "没有可归档的任务行", nil
	end

	local archive_pos, updated_lines = find_or_create_archive_section(bufnr, lines)
	if not archive_pos then
		return false, "无法创建归档区域", nil
	end

	tasks_to_move = move_tasks_to_archive(bufnr, tasks_to_move, archive_pos, updated_lines)

	-- 3. 状态改为归档
	local now = os.time()
	for _, id in ipairs(all_ids) do
		local task = core.get_task(id)
		if task then
			status_domain.enter_terminal(task, types.STATUS.ARCHIVED, now)
			core.save_task(id, task)
		end
	end

	-- 4. 更新行号
	update_task_lines(tasks_to_move)

	-- 5. 触发自动保存
	require("todo2.core.autosave").request_save(bufnr)

	-- 6. 触发事件
	events.emit("archive_group", {
		bufnr = bufnr,
		file = path,
		files = { path },
		changed_ids = all_ids,
	})

	return true, string.format("归档任务组: %d 个任务", #all_ids), {
		root_id = root_id,
		total_tasks = #all_ids,
		archived_ids = all_ids,
	}
end

return M
