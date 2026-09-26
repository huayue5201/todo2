-- lua/todo2/ui/drawer.lua
-- 任务树抽屉：右侧面板，树形展示项目任务（父子层级 + 折叠 + 状态 + 未完成计数）

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local scheduler = require("todo2.render.scheduler")
local fm = require("todo2.ui.file_manager")
local index = require("todo2.store.index")
local project_utils = require("todo2.utils.project")
local events = require("todo2.core.events")
local jumper = require("todo2.task.jumper")

-- 状态 emoji（便于调整）
local STATUS_EMOJI = {
	normal = "⬜",
	urgent = "🔴",
	waiting = "⏳",
	completed = "✅",
	archived = "📦",
}

local FOLD_EXPANDED = "▾"
local FOLD_COLLAPSED = "▸"

local INDENT = { top = "│ ", middle = "├╴", last = "└╴", ws = "  " }

local state = {
	win = nil,
	buf = nil,
	expanded = {}, -- task_id -> true（展开的父任务）
	row_tasks = {}, -- 行号 -> 任务节点
	render_timer = nil,
}

local function win_valid()
	return state.win and vim.api.nvim_win_is_valid(state.win)
end

---------------------------------------------------------------------
-- 数据收集
---------------------------------------------------------------------
local function collect_roots()
	local project = project_utils.get_project_name()
	local todo_files = fm.get_todo_files(project)
	local roots = {}
	for _, path in ipairs(todo_files) do
		local _, file_roots = scheduler.get_parse_tree(path)
		for _, r in ipairs(file_roots) do
			table.insert(roots, r)
		end
	end
	return roots
end

local function task_status(task)
	local t = core.get_task(task.id)
	return t and t.core.status or task.status or types.STATUS.NORMAL
end

-- 子树统计：未完成数、总数（含自身）
local function count_subtree(task)
	local total, unfinished = 0, 0
	local function walk(t)
		total = total + 1
		local st = task_status(t)
		if st ~= types.STATUS.COMPLETED and st ~= types.STATUS.ARCHIVED then
			unfinished = unfinished + 1
		end
		for _, c in ipairs(t.children or {}) do
			walk(c)
		end
	end
	walk(task)
	return unfinished, total
end

---------------------------------------------------------------------
-- 渲染
---------------------------------------------------------------------
local function build_indent(depth, stack)
	local parts = {}
	for i = 1, depth do
		if i == depth then
			parts[i] = stack[i] and INDENT.last or INDENT.middle
		else
			parts[i] = stack[i] and INDENT.ws or INDENT.top
		end
	end
	return table.concat(parts)
end

local function render()
	local buf = state.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local roots = collect_roots()
	local lines = {}
	state.row_tasks = {}

	local function walk(task, depth, stack, is_last)
		local cur = {}
		for i, v in ipairs(stack) do
			cur[i] = v
		end
		if depth > 0 then
			cur[depth] = is_last
		end

		local has_children = task.children and #task.children > 0
		local is_expanded = state.expanded[task.id] == true
		local indent = build_indent(depth, cur)
		local emoji = STATUS_EMOJI[task_status(task)] or STATUS_EMOJI.normal

		local line
		if has_children then
			local fold = is_expanded and FOLD_EXPANDED or FOLD_COLLAPSED
			local unfinished, total = count_subtree(task)
			line = string.format("%s%s %s %s (%d/%d)", indent, fold, emoji, task.content or "", unfinished, total)
		else
			line = string.format("%s  %s %s", indent, emoji, task.content or "")
		end

		local row = #lines + 1
		lines[row] = line
		state.row_tasks[row] = task

		if has_children and is_expanded then
			for i, child in ipairs(task.children) do
				walk(child, depth + 1, cur, i == #task.children)
			end
		end
	end

	for i, root in ipairs(roots) do
		walk(root, 0, {}, i == #roots)
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

---------------------------------------------------------------------
-- 交互
---------------------------------------------------------------------
local function toggle_fold()
	if not win_valid() then
		return
	end
	local row = vim.api.nvim_win_get_cursor(state.win)[1]
	local task = state.row_tasks[row]
	if not task or not task.children or #task.children == 0 then
		return
	end
	state.expanded[task.id] = not state.expanded[task.id]
	render()
end

local function jump_current()
	if not win_valid() then
		return
	end
	local row = vim.api.nvim_win_get_cursor(state.win)[1]
	local task = state.row_tasks[row]
	if not task then
		return
	end
	jumper.jump_to_task(task.id, nil)
end

local function close()
	if state.render_timer then
		pcall(vim.fn.timer_stop, state.render_timer)
		state.render_timer = nil
	end
	if win_valid() then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
	state.buf = nil
	state.row_tasks = {}
end

---------------------------------------------------------------------
-- 展开聚焦 buffer 关联任务的祖先链
---------------------------------------------------------------------
local function expand_focused_tasks()
	local current = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
	if current == "" then
		return
	end
	local tasks = index.find_code_links_by_file(current)
	for _, t in ipairs(tasks) do
		for _, aid in ipairs(relation.get_ancestor_ids(t.id)) do
			state.expanded[aid] = true
		end
	end
end

---------------------------------------------------------------------
-- 打开 / 切换
---------------------------------------------------------------------
local function open()
	close()

	state.expanded = {}
	expand_focused_tasks()

	vim.cmd("rightbelow vsplit")
	state.win = vim.api.nvim_get_current_win()
	state.buf = vim.api.nvim_create_buf(false, true)

	local buf = state.buf
	vim.api.nvim_win_set_buf(state.win, buf)
	vim.api.nvim_win_set_width(state.win, 40)
	pcall(vim.api.nvim_win_set_option, state.win, "winfixwidth", true)

	for opt, value in pairs({
		buftype = "nofile",
		bufhidden = "wipe",
		swapfile = false,
		modifiable = false,
	}) do
		vim.api.nvim_buf_set_option(buf, opt, value)
	end

	local map_opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("n", "<CR>", jump_current, map_opts)
	vim.keymap.set("n", "<Tab>", toggle_fold, map_opts)
	vim.keymap.set("n", "r", function() render() end, map_opts)
	vim.keymap.set("n", "q", close, map_opts)
	vim.keymap.set("n", "<Esc>", close, map_opts)

	render()
end

function M.toggle()
	if win_valid() then
		close()
	else
		open()
	end
end

M.close = close

-- 实时刷新监听（模块加载时注册一次，抽屉开着时事件驱动重渲染）
events.on_change(function()
	if not win_valid() then
		return
	end
	if state.render_timer then
		pcall(vim.fn.timer_stop, state.render_timer)
	end
	state.render_timer = vim.defer_fn(function()
		state.render_timer = nil
		render()
	end, 50)
end)

return M
