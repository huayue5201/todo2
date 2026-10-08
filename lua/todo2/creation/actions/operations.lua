-- lua/todo2/creation/actions/operations.lua
-- TODO 文件内的创建动作与光标工具（UI 层）

local M = {}

local state_manager = require("todo2.core.state_manager")
local service = require("todo2.creation.service")
local id_utils = require("todo2.utils.id")
local buffer = require("todo2.utils.buffer")
local description = require("todo2.core.description")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 批量切换任务状态（可视模式）
---------------------------------------------------------------------
function M.toggle_selected_tasks(bufnr)
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")

	-- 修复：传入 opts 参数（可以为空表）
	local results = state_manager.toggle_range(bufnr, start_line, end_line, {})

	-- 退出可视模式
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

	return results.success
end

---------------------------------------------------------------------
-- 在 TODO 文件中新建纯任务
--
-- 这类任务只存在于 TODO 文件，不建 locations.code（要关联代码用 :TodoLink）。
-- 父子/同级完全由缩进解析树决定，不再看“上一物理行”，也不再继承父任务的代码位置。
---------------------------------------------------------------------

local DEFAULT_CONTENT = "New task"

--- 取光标所在的任务节点（不在任务行上返回 nil）。
---@param path string
---@return table|nil
local function task_at_cursor(path)
	local row = vim.fn.line(".")
	local tasks = scheduler.get_parse_tree(path)
	for _, t in ipairs(tasks) do
		if t.line_num == row then
			return t
		end
	end
	return nil
end

--- 任务自身 + 其正文块的最后一个行号。
---@param lines string[]
---@param node table
---@return number
local function task_block_end(lines, node)
	local block = description.block_at(lines, node.line_num)
	return block and block.end_line or node.line_num
end

--- 整棵子树（含正文）的最后一行。
---@param lines string[]
---@param node table
---@return number
local function subtree_end(lines, node)
	local last = node
	while last.children and #last.children > 0 do
		last = last.children[#last.children]
	end
	return task_block_end(lines, last)
end

--- 在 after_line 之后插入一条纯任务并写入存储（不建代码链接）。返回新行号。
---@param bufnr number
---@param after_line number
---@param indent string
---@param parent_id string|nil
---@return number|nil
local function insert_pure_task(bufnr, after_line, indent, parent_id)
	local id = id_utils.generate_id()
	local result = service.insert_task_line(bufnr, after_line, {
		indent = indent,
		id = id,
		content = DEFAULT_CONTENT,
		update_store = false,
		trigger_event = false,
		autosave = false,
	})
	if not result then
		return nil
	end

	service.create_todo_link(buffer.get_path(bufnr), result.line_num, id, DEFAULT_CONTENT, {
		parent_id = parent_id,
	})
	return result.line_num
end

--- 插入后把光标移到新任务行尾并进入插入模式。
---@param new_line number|nil
local function focus_new_task(new_line)
	if not new_line then
		return
	end
	M.place_cursor_at_line_end(0, new_line)
	M.start_insert_at_line_end()
end

--- 新建独立任务（无父、无代码链接）。
---@param bufnr number|nil
function M.insert_task(bufnr)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local path = buffer.get_path(target_buf)
	local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)

	-- 光标在任务上时插到整棵子树之后，避免新行抢占其子任务
	local node = task_at_cursor(path)
	local after_line = node and subtree_end(lines, node) or vim.fn.line(".")
	focus_new_task(insert_pure_task(target_buf, after_line, "", nil))
end

--- 在当前任务下新建子任务（无代码链接）。
---@param bufnr number|nil
function M.insert_subtask(bufnr)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local node = task_at_cursor(buffer.get_path(target_buf))
	if not node or not node.id then
		vim.notify("Place the cursor on a task line", vim.log.levels.WARN)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
	-- 插在父任务正文之后，避免正文被新任务“截胡”
	local after_line = task_block_end(lines, node)
	local indent = (node.indent or "") .. "  "
	focus_new_task(insert_pure_task(target_buf, after_line, indent, node.id))
end

--- 在当前任务同级新建任务（无代码链接，继承父级关系）。
---@param bufnr number|nil
function M.insert_sibling(bufnr)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local node = task_at_cursor(buffer.get_path(target_buf))
	if not node or not node.id then
		vim.notify("Place the cursor on a task line", vim.log.levels.WARN)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
	local parent_id = node.parent and node.parent.id or nil
	local after_line = subtree_end(lines, node)
	focus_new_task(insert_pure_task(target_buf, after_line, node.indent or "", parent_id))
end

---------------------------------------------------------------------
-- 光标工具函数
---------------------------------------------------------------------
function M.place_cursor_at_line_end(win, lnum)
	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_get_current_win()
	end

	local bufnr = vim.api.nvim_win_get_buf(win)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	vim.api.nvim_win_set_cursor(win, { lnum, #line })
end

function M.start_insert_at_line_end()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
end

---------------------------------------------------------------------
-- 创建动作的公共收尾：校验代码行 + 创建代码链接 + 定位光标
---------------------------------------------------------------------
function M.finish_creation(context, target, id, content, new_line)
	if not buffer.is_valid_line(context.code_buf, context.code_line) then
		return false, "Invalid code line number: " .. tostring(context.code_line)
	end

	service.create_code_link(context.code_buf, context.code_line, id, content)

	if vim.api.nvim_win_is_valid(target.winid) then
		vim.api.nvim_win_set_cursor(target.winid, { new_line, #content })
		vim.api.nvim_feedkeys("A", "n", true)
	end

	return true, nil
end

return M
