-- lua/todo2/task/jumper.lua
-- 纯功能平移：使用新接口获取任务数据

local M = {}

local core = require("todo2.store.link.core") -- 改为 core
local ui = require("todo2.ui")
local utils = require("todo2.task.utils")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 固定跳转配置
---------------------------------------------------------------------
local FIXED_CONFIG = {
	reuse_existing = true,
	jump_position = "auto",
}

---------------------------------------------------------------------
-- 从任务构造兼容的 link 对象（用于 resolve_line）
---------------------------------------------------------------------
local function task_to_link(task, location_type)
	if not task then
		return nil
	end

	if location_type == "todo" and task.locations.todo then
		return {
			id = task.id,
			path = task.locations.todo.path,
			line = task.locations.todo.line,
		}
	elseif location_type == "code" and task.locations.code then
		return {
			id = task.id,
			path = task.locations.code.path,
			line = task.locations.code.line,
		}
	end
	return nil
end

---------------------------------------------------------------------
-- 查找已有 TODO split 窗口
---------------------------------------------------------------------
local function find_existing_todo_split_window(todo_path)
	local wins = vim.api.nvim_list_wins()
	for _, win in ipairs(wins) do
		if vim.api.nvim_win_is_valid(win) then
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buf_path = vim.api.nvim_buf_get_name(bufnr)
			if vim.fn.fnamemodify(buf_path, ":p") == todo_path then
				local cfg = vim.api.nvim_win_get_config(win)
				if cfg.relative == "" then
					return win, bufnr
				end
			end
		end
	end
	return nil, nil
end

---------------------------------------------------------------------
-- 计算跳转列
---------------------------------------------------------------------
local function get_target_column(line_content, strategy)
	if strategy == "line_start" then
		return 0
	elseif strategy == "line_end" then
		return #line_content
	elseif strategy == "link_end" then
		if id_utils.contains_todo_anchor(line_content) then
			local id = id_utils.extract_id_from_todo_anchor(line_content)
			if id then
				local pattern = id_utils.format_todo_anchor(id)
				local _, e = line_content:find(pattern)
				if e then
					return e + 1
				end
			end
		end
		if id_utils.contains_code_mark(line_content) then
			local tag = id_utils.extract_tag_from_code_mark(line_content)
			local id = id_utils.extract_id_from_code_mark(line_content)
			if tag and id then
				local pattern = id_utils.format_code_mark(tag, id)
				local _, e = line_content:find(pattern)
				if e then
					return e + 1
				end
			end
		end
		return #line_content
	else
		if id_utils.contains_todo_anchor(line_content) or id_utils.contains_code_mark(line_content) then
			return get_target_column(line_content, "link_end")
		end
		return #line_content
	end
end

---------------------------------------------------------------------
-- snapshot 优先 + link.line 兜底
---------------------------------------------------------------------
local function resolve_line(path, id, link)
	if not path or path == "" or not id then
		return (link and link.line) or 1
	end

	local ok, tasks, _, id_to_task = pcall(function()
		local t, m, map = scheduler.get_parse_tree(path)
		return t, m, map
	end)

	if ok and tasks and id_to_task then
		local task = id_to_task[id]
		if task and task.line_num and task.line_num > 0 then
			return task.line_num
		end
	end

	-- snapshot 没有，就退回存储层行号
	return (link and link.line) or 1
end

---------------------------------------------------------------------
-- 安全跳转（带 clamp）
---------------------------------------------------------------------
local function safe_jump_to_line(win, line, col)
	col = col or -1
	local auto = col == -1

	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(line, line_count))
	local target_col = col

	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	if lines and #lines > 0 then
		local content = lines[1]
		if auto then
			target_col = get_target_column(content, FIXED_CONFIG.jump_position)
		else
			target_col = math.min(target_col, #content)
		end
	else
		target_col = 0
	end

	target_col = math.max(0, target_col)
	pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })

	return true
end

---------------------------------------------------------------------
-- 代码 → TODO
---------------------------------------------------------------------
function M.jump_to_todo()
	local line = vim.fn.getline(".")
	if not id_utils.contains_code_mark(line) then
		vim.notify("当前行没有链接标记", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_code_mark(line)
	if not id then
		return
	end

	-- 从内部格式获取任务
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local todo_path = vim.fn.fnamemodify(task.locations.todo.path, ":p")
	local link = task_to_link(task, "todo")
	local todo_line = resolve_line(todo_path, id, link)

	if FIXED_CONFIG.reuse_existing then
		local win = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, todo_line, -1)
			return
		end
	end

	ui.open_todo_file(todo_path, "float", todo_line, { enter_insert = false })

	vim.schedule(function()
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, todo_line, -1)
	end)
end

---------------------------------------------------------------------
-- TODO → 代码
---------------------------------------------------------------------
function M.jump_to_code()
	local line = vim.fn.getline(".")
	if not id_utils.contains_todo_anchor(line) then
		vim.notify("当前行没有代码链接", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_todo_anchor(line)
	if not id then
		return
	end

	-- 从内部格式获取任务
	local task = core.get_task(id)
	if not task or not task.locations.code then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local code_path = vim.fn.fnamemodify(task.locations.code.path, ":p")
	local link = task_to_link(task, "code")
	local code_line = resolve_line(code_path, id, link)

	local current_win = vim.api.nvim_get_current_win()
	local is_float = utils.is_todo_floating_window and utils.is_todo_floating_window(current_win)

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			vim.cmd("edit " .. vim.fn.fnameescape(code_path))
			safe_jump_to_line(vim.api.nvim_get_current_win(), code_line, -1)
		end)
		return
	end

	vim.cmd("edit " .. vim.fn.fnameescape(code_path))
	safe_jump_to_line(vim.api.nvim_get_current_win(), code_line, -1)
end

---------------------------------------------------------------------
-- 动态跳转
---------------------------------------------------------------------
function M.jump_dynamic()
	local name = vim.api.nvim_buf_get_name(0)
	local is_todo = name:match("%.todo%.md$") ~= nil
	if is_todo then
		M.jump_to_code()
	else
		M.jump_to_todo()
	end
end

return M
