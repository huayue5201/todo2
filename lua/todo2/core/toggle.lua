-- lua/todo2/core/toggle.lua
--- @module todo2.core.toggle

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------
local parser
local function get_parser()
	if not parser then
		parser = module.get("core.parser")
	end
	return parser
end

local stats
local function get_stats()
	if not stats then
		stats = module.get("core.stats")
	end
	return stats
end

local sync
local function get_sync()
	if not sync then
		sync = module.get("core.sync")
	end
	return sync
end

---------------------------------------------------------------------
-- 工具：替换行内状态
---------------------------------------------------------------------
local function replace_status(bufnr, lnum, from, to)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	local start_col, end_col = line:find(from)
	if not start_col then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { to })
	return true
end

---------------------------------------------------------------------
-- 递归切换任务 + 子任务
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr, new_status)
	if new_status == nil then
		new_status = not task.is_done
	end

	local success
	if new_status then
		success = replace_status(bufnr, task.line_num, "%[ %]", "[x]")
	else
		success = replace_status(bufnr, task.line_num, "%[[xX]%]", "[ ]")
	end

	if success then
		task.is_done = new_status
	end

	for _, child in ipairs(task.children) do
		toggle_task_and_children(child, bufnr, new_status)
	end
end

---------------------------------------------------------------------
-- ⭐ 新版 toggle：基于 parser.parse_file(path)
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum)
	-----------------------------------------------------------------
	-- 1. 获取文件路径（parser 需要 path）
	-----------------------------------------------------------------
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	-----------------------------------------------------------------
	-- 2. 使用 parser.parse_file(path) 获取任务树
	-----------------------------------------------------------------
	local parser_mod = get_parser()
	local tasks, roots = parser_mod.parse_file(path)

	-----------------------------------------------------------------
	-- 3. 找到当前任务
	-----------------------------------------------------------------
	local current_task = nil
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		return false, "不是任务行"
	end

	-----------------------------------------------------------------
	-- 4. 切换当前任务 + 子任务
	-----------------------------------------------------------------
	toggle_task_and_children(current_task, bufnr, nil)

	-----------------------------------------------------------------
	-- 5. 重新计算统计（基于 parser 的任务树）
	-----------------------------------------------------------------
	local stats_mod = get_stats()
	stats_mod.calculate_all_stats(tasks)

	-----------------------------------------------------------------
	-- 6. 父子联动（纯逻辑，不写盘）
	-----------------------------------------------------------------
	local sync_mod = get_sync()
	sync_mod.sync_parent_child_state(tasks, bufnr)

	return true, current_task.is_done
end

return M
