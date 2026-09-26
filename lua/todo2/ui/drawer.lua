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
local config = require("todo2.config")
local window = require("todo2.ui.window")
local state_manager = require("todo2.core.state_manager")
local core_status = require("todo2.core.status")
local deleter = require("todo2.task.deleter")
local handlers_task = require("todo2.handlers.task")
local task_virt = require("todo2.render.task_virt")
local tree = require("todo2.utils.tree")
local checkbox = require("todo2.render.checkbox")

local FOLD_EXPANDED = "▾"
local FOLD_COLLAPSED = "▸"

-- 抽屉高亮命名空间
local HL_NS = vim.api.nvim_create_namespace("todo2_drawer_hl")

-- 抽屉高亮组（复选框颜色复用 TODO 文件已有的组，其余按层级区分）
local function setup_drawer_highlights()
	local dark = vim.o.background == "dark"
	local drawer_hl = {
		TodoDrawerFileHeader = { fg = dark and "#7aa2f7" or "#2e6fed", bold = true },
		TodoDrawerFoldIcon = { fg = dark and "#565f89" or "#8c93b3" },
		TodoDrawerIndent = { fg = dark and "#3b4261" or "#c8d3f5" },
		TodoDrawerCount = { fg = dark and "#565f89" or "#8c93b3" },
		TodoDrawerParent = { fg = dark and "#e0af68" or "#965027", bold = true },
		TodoDrawerRoot = { fg = dark and "#c0caf5" or "#343b58" },
		TodoDrawerChild = { fg = dark and "#9aa5ce" or "#565f89" },
	}
	for name, spec in pairs(drawer_hl) do
		if vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, spec)
		end
	end

	-- 复选框颜色兜底（正常情况下由 highlights.setup 定义，此处仅确保组存在）
	local checkbox_hl = {
		TodoCheckboxTodo = { fg = dark and "#73daca" or "#33635c" },
		TodoCheckboxDone = { fg = dark and "#9ece6a" or "#485e30" },
		TodoCheckboxArchived = { fg = "#868e96" },
	}
	for name, spec in pairs(checkbox_hl) do
		if vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, spec)
		end
	end
end

setup_drawer_highlights()

-- 按显示宽度补空格，保证复选框/图标列对齐
local function pad(s, n)
	local w = vim.fn.strdisplaywidth(s)
	if w < n then
		return s .. string.rep(" ", n - w)
	end
	return s
end

-- 拼接片段并返回 (整行文本, 高亮区间数组)
-- segs: { {text, hl}, ... }，hl 可为 nil；区间为字节偏移（0-based）
local function emit_line(segs)
	local parts, ranges, offset = {}, {}, 0
	for _, seg in ipairs(segs) do
		parts[#parts + 1] = seg[1]
		if seg[2] then
			ranges[#ranges + 1] = { offset, offset + #seg[1], seg[2] }
		end
		offset = offset + #seg[1]
	end
	return table.concat(parts), ranges
end

local state = {
	win = nil,
	buf = nil,
	expanded = {}, -- task_id -> true（展开的父任务）
	file_expanded = {}, -- TODO 文件 path -> false 表示折叠（默认展开）
	row_tasks = {}, -- 行号 -> 任务节点
	row_files = {}, -- 行号 -> 文件 header 对应的 TODO 文件 path
	follow_augroup = nil,
	prev_win = nil,
}

-- 防抖代际：每次调度递增，旧回调因代际不匹配而失效（比 timer_stop 更可靠）
local render_gen = 0
local follow_gen = 0

local function win_valid()
	return state.win and vim.api.nvim_win_is_valid(state.win)
end

---------------------------------------------------------------------
-- 数据收集
---------------------------------------------------------------------
-- 收集任务树，按 TODO 文件分组
local function collect_groups()
	local project = project_utils.get_project_name()
	local todo_files = fm.get_todo_files(project)
	local groups = {}
	for _, path in ipairs(todo_files) do
		local _, file_roots = scheduler.get_parse_tree(path)
		if file_roots and #file_roots > 0 then
			table.insert(groups, { file = path, roots = file_roots })
		end
	end
	return groups
end

-- 文件组是否展开（默认展开，仅当显式折叠时为 false）
local function is_file_expanded(path)
	return state.file_expanded[path] ~= false
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
local function render()
	local buf = state.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local groups = collect_groups()
	local lines = {}
	local hl_ranges = {} -- [row] = { {scol, ecol, hl}, ... }
	state.row_tasks = {}
	state.row_files = {}

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
		local indent = tree.build_indent(depth, cur)

		local st = task_status(task)
		local cicon, chl = checkbox.get(st)

		local segs = {}
		if indent ~= "" then
			segs[#segs + 1] = { indent, "TodoDrawerIndent" }
		end
		if has_children then
			segs[#segs + 1] = { is_expanded and FOLD_EXPANDED or FOLD_COLLAPSED, "TodoDrawerFoldIcon" }
			segs[#segs + 1] = { " " }
		else
			segs[#segs + 1] = { "  " }
		end
		segs[#segs + 1] = { pad(cicon, 2), chl }
		segs[#segs + 1] = { " " }

		local content_hl
		if has_children then
			content_hl = "TodoDrawerParent"
		elseif depth == 0 then
			content_hl = "TodoDrawerRoot"
		else
			content_hl = "TodoDrawerChild"
		end
		segs[#segs + 1] = { task.content or "", content_hl }

		if has_children then
			local unfinished, total = count_subtree(task)
			segs[#segs + 1] = { " " }
			segs[#segs + 1] = { string.format("(%d/%d)", unfinished, total), "TodoDrawerCount" }
		end

		-- 状态图标 + 时间戳（与代码文件渲染一致）
		local full = core.get_task(task.id)
		if full then
			task_virt.build_status(full, segs)
		end

		local row = #lines + 1
		lines[row], hl_ranges[row] = emit_line(segs)
		state.row_tasks[row] = task

		if has_children and is_expanded then
			for i, child in ipairs(task.children) do
				walk(child, depth + 1, cur, i == #task.children)
			end
		end
	end

	for _, group in ipairs(groups) do
		local name = vim.fn.fnamemodify(group.file, ":t")
		local expanded = is_file_expanded(group.file)
		local fold = expanded and FOLD_EXPANDED or FOLD_COLLAPSED

		local unfinished, total = 0, 0
		for _, root in ipairs(group.roots) do
			local u, t = count_subtree(root)
			unfinished = unfinished + u
			total = total + t
		end

		local segs = {
			{ fold, "TodoDrawerFoldIcon" },
			{ " " },
			{ pad("📁", 2), "TodoDrawerFileHeader" },
			{ " " },
			{ name, "TodoDrawerFileHeader" },
			{ " " },
			{ string.format("(%d/%d)", unfinished, total), "TodoDrawerCount" },
		}

		local row = #lines + 1
		lines[row], hl_ranges[row] = emit_line(segs)
		state.row_files[row] = group.file

		if expanded then
			for i, root in ipairs(group.roots) do
				walk(root, 0, {}, i == #group.roots)
			end
		end
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- 应用高亮
	vim.api.nvim_buf_clear_namespace(buf, HL_NS, 0, -1)
	for row, ranges in ipairs(hl_ranges) do
		for _, r in ipairs(ranges) do
			vim.api.nvim_buf_add_highlight(buf, HL_NS, r[3], row - 1, r[1], r[2])
		end
	end
end

---------------------------------------------------------------------
-- 交互
---------------------------------------------------------------------
-- 当前行折叠目标：返回 kind("file"/"task") + key
local function fold_target()
	if not win_valid() then
		return nil, nil
	end
	local row = vim.api.nvim_win_get_cursor(state.win)[1]
	local file = state.row_files[row]
	if file then
		return "file", file
	end
	local task = state.row_tasks[row]
	if task and task.children and #task.children > 0 then
		return "task", task.id
	end
	return nil, nil
end

local function set_fold(expand)
	local kind, key = fold_target()
	if not kind then
		return
	end
	if kind == "file" then
		state.file_expanded[key] = expand
	else
		state.expanded[key] = expand
	end
	render()
end

local function toggle_fold()
	local kind, key = fold_target()
	if not kind then
		return
	end
	if kind == "file" then
		state.file_expanded[key] = not is_file_expanded(key)
	else
		state.expanded[key] = not state.expanded[key]
	end
	render()
end

local function set_all_folds(expand)
	for _, group in ipairs(collect_groups()) do
		state.file_expanded[group.file] = expand
		local function walk(t)
			state.expanded[t.id] = expand
			for _, c in ipairs(t.children or {}) do
				walk(c)
			end
		end
		for _, root in ipairs(group.roots) do
			walk(root)
		end
	end
	render()
end

-- 当前选中任务 ID
local function current_task_id()
	if not win_valid() then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(state.win)[1]
	local task = state.row_tasks[row]
	return task and task.id or nil
end

-- <CR>：切换复选框状态（复用 state_manager）
local function toggle_status()
	local id = current_task_id()
	if not id then
		return
	end
	state_manager.toggle_line(nil, nil, { id = id })
end

-- <S-CR>：循环切换状态（复用 core.status）
local function cycle_status()
	local id = current_task_id()
	if not id then
		return
	end
	core_status.cycle(id)
end

-- <BS>：删除任务（复用 deleter）
local function delete_task()
	local id = current_task_id()
	if not id then
		return
	end
	local ok, _ = deleter.delete_by_ids({ id })
	if not ok then
		vim.notify("删除任务失败", vim.log.levels.WARN)
	end
end

-- e：编辑任务内容（复用 handlers.edit_task_by_id）
local function edit_task()
	local id = current_task_id()
	if not id then
		return
	end
	handlers_task.edit_task_by_id(id)
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

	-- 只跳转到代码位置（不打开 todo.md）
	local loc = core.get_code_location(task.id)
	if not loc or not loc.path or not loc.line then
		vim.notify("该任务没有代码位置", vim.log.levels.WARN)
		return
	end

	-- 目标窗口：优先打开抽屉前的窗口，其次任意非抽屉窗口
	local target = state.prev_win
	if not target or not vim.api.nvim_win_is_valid(target) or target == state.win then
		target = nil
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if win ~= state.win then
				target = win
				break
			end
		end
	end

	-- 没有其他窗口：在抽屉旁新建一个
	if not target then
		vim.api.nvim_set_current_win(state.win)
		vim.cmd("rightbelow vsplit")
		target = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(state.win)
	end

	-- 在目标窗口打开代码 buffer（不动抽屉 buffer）
	local bufnr = vim.fn.bufnr(loc.path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(loc.path)
		vim.fn.bufload(bufnr)
	end
	vim.api.nvim_win_set_buf(target, bufnr)

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local target_line = math.max(1, math.min(loc.line, line_count))
	pcall(vim.api.nvim_win_set_cursor, target, { target_line, 0 })
	pcall(vim.api.nvim_win_call, target, function()
		vim.cmd("normal! zz")
	end)

	-- 焦点是否跟随（neo-tree 风格默认留在抽屉）
	if config.get("drawer.focus_on_jump") then
		vim.api.nvim_set_current_win(target)
	end
end

---------------------------------------------------------------------
-- 浮窗打开任务（o 键）：用现有浮窗方法打开任务所在 TODO 位置
---------------------------------------------------------------------
local function open_task_float()
	if not win_valid() then
		return
	end
	local row = vim.api.nvim_win_get_cursor(state.win)[1]
	local task = state.row_tasks[row]
	if not task then
		return
	end

	local loc = core.get_todo_location(task.id)
	if not loc or not loc.path or not loc.line then
		vim.notify("该任务没有 TODO 位置", vim.log.levels.WARN)
		return
	end

	window.open_todo_file(loc.path, "float", loc.line, { enter_insert = false })
end

---------------------------------------------------------------------
-- follow：光标在代码 buffer 移动时，定位关联任务
---------------------------------------------------------------------
-- 跟随当前 buffer 关联的第一个任务（精确到文件，最稳）
local function follow_current()
	if not win_valid() then
		return
	end
	-- 光标在抽屉自身时不处理，避免定位后又立刻被清掉
	if vim.api.nvim_get_current_buf() == state.buf then
		return
	end

	local current = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
	if current == "" then
		return
	end

	local tasks = index.find_code_links_by_file(current)
	if #tasks == 0 then
		return
	end

	local task = tasks[1]

	-- 展开祖先链 + 所在文件组，确保目标任务可见
	local changed = false
	for _, aid in ipairs(relation.get_ancestor_ids(task.id)) do
		if state.expanded[aid] ~= true then
			state.expanded[aid] = true
			changed = true
		end
	end
	local todo_path = task.locations and task.locations.todo and task.locations.todo.path
	if todo_path and not is_file_expanded(todo_path) then
		state.file_expanded[todo_path] = true
		changed = true
	end

	if changed then
		render()
	end

	-- 定位目标任务行（cursorline 负责高亮）
	for row, t in pairs(state.row_tasks) do
		if t.id == task.id then
			pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
			return
		end
	end
end

local function schedule_follow()
	if not win_valid() then
		return
	end
	follow_gen = follow_gen + 1
	local gen = follow_gen
	vim.defer_fn(function()
		if gen ~= follow_gen or not win_valid() then
			return
		end
		follow_current()
	end, 150)
end

local function close()
	-- 使所有待执行的防抖回调失效
	render_gen = render_gen + 1
	follow_gen = follow_gen + 1

	if state.follow_augroup then
		pcall(vim.api.nvim_del_augroup_by_id, state.follow_augroup)
		state.follow_augroup = nil
	end
	if win_valid() then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state.win = nil
	state.buf = nil
	state.row_tasks = {}
	state.row_files = {}
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

	state.prev_win = vim.api.nvim_get_current_win()
	state.expanded = {}
	state.file_expanded = {}
	expand_focused_tasks()

	local cfg = config.get("drawer") or {}
	local position = cfg.position or "right"

	if position == "bottom" then
		vim.cmd("botright split")
	else
		vim.cmd("rightbelow vsplit")
	end
	state.win = vim.api.nvim_get_current_win()
	state.buf = vim.api.nvim_create_buf(false, true)

	local buf = state.buf
	vim.api.nvim_win_set_buf(state.win, buf)

	if position == "bottom" then
		pcall(vim.api.nvim_win_set_height, state.win, cfg.height or 12)
		pcall(vim.api.nvim_win_set_option, state.win, "winfixheight", true)
	else
		pcall(vim.api.nvim_win_set_width, state.win, cfg.width or 40)
		pcall(vim.api.nvim_win_set_option, state.win, "winfixwidth", true)
	end

	-- 干净、trouble 风格的窗口外观（去 signcolumn / 行号，选中行高亮）
	vim.wo[state.win].signcolumn = "no"
	vim.wo[state.win].number = false
	vim.wo[state.win].relativenumber = false
	vim.wo[state.win].cursorline = true
	vim.wo[state.win].foldcolumn = "0"
	vim.wo[state.win].wrap = false
	vim.wo[state.win].spell = false

	for opt, value in pairs({
		buftype = "nofile",
		bufhidden = "wipe",
		swapfile = false,
		modifiable = false,
	}) do
		vim.api.nvim_buf_set_option(buf, opt, value)
	end

	local map_opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("n", "<CR>", toggle_status, map_opts)
	vim.keymap.set("n", "<Tab>", jump_current, map_opts)
	vim.keymap.set("n", "o", open_task_float, map_opts)
	vim.keymap.set("n", "e", edit_task, map_opts)
	vim.keymap.set("n", "<BS>", delete_task, map_opts)
	vim.keymap.set("n", "<S-CR>", cycle_status, map_opts)
	vim.keymap.set("n", "za", toggle_fold, map_opts)
	vim.keymap.set("n", "zo", function()
		set_fold(true)
	end, map_opts)
	vim.keymap.set("n", "zc", function()
		set_fold(false)
	end, map_opts)
	vim.keymap.set("n", "zR", function()
		set_all_folds(true)
	end, map_opts)
	vim.keymap.set("n", "zM", function()
		set_all_folds(false)
	end, map_opts)
	vim.keymap.set("n", "r", function()
		render()
	end, map_opts)
	vim.keymap.set("n", "q", close, map_opts)

	-- follow：光标移动时（节流）定位关联任务
	state.follow_augroup = vim.api.nvim_create_augroup("Todo2DrawerFollow", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
		group = state.follow_augroup,
		callback = schedule_follow,
	})

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
	render_gen = render_gen + 1
	local gen = render_gen
	vim.defer_fn(function()
		if gen ~= render_gen or not win_valid() then
			return
		end
		render()
	end, 50)
end)

return M
