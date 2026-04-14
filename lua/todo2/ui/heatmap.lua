-- lua/todo2/ui/heatmap.lua
-- GitHub 风格任务状态热图 - 每个任务一个格子，颜色代表任务状态

-- TODO:ref:ec8fb2
local M = {}

local config = require("todo2.config")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local scheduler = require("todo2.render.scheduler")
local fm = require("todo2.ui.file_manager")

-- ■ (U+25A0 BLACK SQUARE) for filled cells
-- □ (U+25A1 WHITE SQUARE) for empty cells
local CELL = "\226\150\160" -- U+25A0  ■
local EMPTY = "\226\150\161" -- U+25A1  □

local DAY_LABELS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- 状态对应的高亮级别 (6个级别，从低到高)
local HL_LEVELS = {
	"Todo2HeatmapNone", -- 0: 无任务
	"Todo2HeatmapCompleted", -- 1: 完成 (最低优先级)
	"Todo2HeatmapArchived", -- 2: 归档
	"Todo2HeatmapNormal", -- 3: 普通
	"Todo2HeatmapWaiting", -- 4: 等待
	"Todo2HeatmapUrgent", -- 5: 紧急 (最高优先级)
}

-- 每个格子宽度：字符 + 2空格
local CELL_GAP = "  "
local EMPTY_GAP = "  "
local MONTH_GAP = "   "

---------------------------------------------------------------------
-- 设置高亮颜色
---------------------------------------------------------------------
local function setup_highlights()
	local icons = config.get("status_icons")

	local function set(name, color)
		if color then
			vim.api.nvim_set_hl(0, name, { fg = color })
		end
	end

	-- 根据优先级设置颜色
	set("Todo2HeatmapNone", "#495057") -- 灰色
	set("Todo2HeatmapCompleted", icons.completed and icons.completed.color or "#51cf66") -- 绿色
	set("Todo2HeatmapArchived", "#868e96") -- 暗灰色
	set("Todo2HeatmapNormal", icons.normal and icons.normal.color or "#4dabf7") -- 蓝色
	set("Todo2HeatmapWaiting", icons.waiting and icons.waiting.color or "#ffd43b") -- 黄色
	set("Todo2HeatmapUrgent", icons.urgent and icons.urgent.color or "#ff6b6b") -- 红色
end

---------------------------------------------------------------------
-- 加载所有任务
---------------------------------------------------------------------
local function load_all_tasks_from_project()
	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)
	local all_tasks = {}

	for _, todo_path in ipairs(todo_files) do
		local _, roots = scheduler.get_parse_tree(todo_path, false)

		local function collect_tasks(task)
			if task and task.id then
				local t = core.get_task(task.id)
				if t then
					table.insert(all_tasks, t)
				end
			end
			if task.children then
				for _, child in ipairs(task.children) do
					collect_tasks(child)
				end
			end
		end

		for _, root in ipairs(roots) do
			collect_tasks(root)
		end
	end

	return all_tasks
end

---------------------------------------------------------------------
-- 任务状态转优先级 (1-6, 1最低, 6最高)
---------------------------------------------------------------------
local function status_to_level(status)
	if status == types.STATUS.COMPLETED then
		return 1
	elseif status == types.STATUS.ARCHIVED then
		return 2
	elseif status == types.STATUS.NORMAL then
		return 3
	elseif status == types.STATUS.WAITING then
		return 4
	elseif status == types.STATUS.URGENT then
		return 5
	else
		return 0
	end
end

---------------------------------------------------------------------
--- 渲染 27周 × 7天 的热力图（每个格子代表一个任务）
---@return string[], table
function M.render(tasks)
	local lines = {}
	local hls = {}
	local indent = "  "

	-- 标题
	table.insert(lines, "")
	-- FIX:ref:7a5d31
	table.insert(lines, indent .. "Todo2 任务状态热图")
	table.insert(lines, "")

	-- 统计信息
	local stats = { total = #tasks, normal = 0, urgent = 0, waiting = 0, completed = 0, archived = 0 }
	for _, task in ipairs(tasks) do
		local status = task.core.status
		if status == types.STATUS.NORMAL then
			stats.normal = stats.normal + 1
		elseif status == types.STATUS.URGENT then
			stats.urgent = stats.urgent + 1
		elseif status == types.STATUS.WAITING then
			stats.waiting = stats.waiting + 1
		elseif status == types.STATUS.COMPLETED then
			stats.completed = stats.completed + 1
		elseif status == types.STATUS.ARCHIVED then
			stats.archived = stats.archived + 1
		end
	end

	table.insert(lines, indent .. string.format("总计: %d 个任务", stats.total))
	table.insert(
		lines,
		indent
			.. string.format(
				"紧急: %d  等待: %d  普通: %d  完成: %d  归档: %d",
				stats.urgent,
				stats.waiting,
				stats.normal,
				stats.completed,
				stats.archived
			)
	)
	table.insert(lines, "")

	-- 构建网格: 27周 × 7天，每个格子对应一个任务
	local NUM_WEEKS = 27
	local NUM_ROWS = 7
	local total_cells = NUM_WEEKS * NUM_ROWS
	local grid = {}

	-- 初始化网格
	for w = 1, NUM_WEEKS do
		grid[w] = {}
		for d = 1, NUM_ROWS do
			grid[w][d] = nil
		end
	end

	-- 将任务分配到网格中（按列优先填充）
	for i, task in ipairs(tasks) do
		if i <= total_cells then
			local week = math.floor((i - 1) / NUM_ROWS) + 1
			local row = ((i - 1) % NUM_ROWS) + 1
			grid[week][row] = task
		end
	end

	-- 月份标签行（简化版，不显示具体月份，只显示周数）
	local LABEL_INDENT = "       " -- 7 chars: matches "  Mon  " prefix
	local month_line = LABEL_INDENT
	for w = 1, NUM_WEEKS do
		if w == 1 or w % 4 == 0 then
			local label = string.format("W%d", w)
			month_line = month_line .. label
			-- 补齐到3字符
			if #label == 1 then
				month_line = month_line .. "  "
			elseif #label == 2 then
				month_line = month_line .. " "
			end
		else
			month_line = month_line .. MONTH_GAP
		end
	end
	table.insert(lines, month_line)

	-- 渲染网格行
	local CELL_BYTES = #CELL
	local EMPTY_BYTES = #EMPTY

	for row = 1, NUM_ROWS do
		local label = DAY_LABELS[row]
		local row_str = indent .. label .. "  "
		local row_hls = {}
		local col = #row_str

		for week = 1, NUM_WEEKS do
			local task = grid[week][row]

			if task then
				local level = status_to_level(task.core.status)
				local char = CELL
				local blen = CELL_BYTES
				local gap = CELL_GAP

				row_str = row_str .. char .. gap
				table.insert(row_hls, { col, col + blen, HL_LEVELS[level + 1] })
				col = col + blen + #gap
			else
				-- 空格子
				row_str = row_str .. EMPTY .. EMPTY_GAP
				col = col + EMPTY_BYTES + #EMPTY_GAP
			end
		end

		local row_idx = #lines
		table.insert(lines, row_str)
		for _, h in ipairs(row_hls) do
			table.insert(hls, { row_idx, h[1], h[2], h[3] })
		end
	end

	-- 图例
	table.insert(lines, "")
	local legend_row = #lines
	local legend = indent .. EMPTY .. " 无任务  "
	local legend_items = { "完成", "归档", "普通", "等待", "紧急" }
	for i = 1, 5 do
		legend = legend .. CELL .. " " .. legend_items[i]
		if i < 5 then
			legend = legend .. "  "
		end
	end
	table.insert(lines, legend)

	-- 高亮图例
	local lc = #indent
	table.insert(hls, { legend_row, lc, lc + EMPTY_BYTES, HL_LEVELS[1] })
	lc = lc + EMPTY_BYTES + #" 无任务  "
	for i = 1, 5 do
		table.insert(hls, { legend_row, lc, lc + CELL_BYTES, HL_LEVELS[i + 1] })
		lc = lc + CELL_BYTES + 1 + #legend_items[i]
		if i < 5 then
			lc = lc + 2
		end
	end

	table.insert(lines, "")
	table.insert(lines, indent .. "提示: 鼠标左键点击任务方块跳转到代码位置")
	table.insert(lines, indent .. "      q / ESC 关闭窗口")

	return lines, hls
end

---------------------------------------------------------------------
-- 打开热图窗口
---------------------------------------------------------------------
function M.open()
	setup_highlights()

	local tasks = load_all_tasks_from_project()

	if #tasks == 0 then
		vim.notify("项目中没有任务", vim.log.levels.WARN)
		return
	end

	local lines, highlights = M.render(tasks)

	-- 计算窗口尺寸
	local max_line_length = 0
	for _, line in ipairs(lines) do
		local len = vim.fn.strdisplaywidth(line)
		if len > max_line_length then
			max_line_length = len
		end
	end

	local width = max_line_length + 4
	local height = #lines + 4

	-- 居中显示
	local editor_w = vim.o.columns
	local editor_h = vim.o.lines
	local row = math.max(0, math.floor((editor_h - height) / 2))
	local col = math.max(0, math.floor((editor_w - width) / 2))

	-- 创建缓冲区
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

	-- 创建窗口
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Task Heatmap ",
		title_pos = "center",
	})

	-- 构建任务映射
	local task_map = {}
	local idx = 1
	for _, h in ipairs(highlights) do
		if h[4] then -- 存储任务对象
			task_map[idx] = { line = h[1], col_start = h[2], col_end = h[3], task = h[4] }
			idx = idx + 1
		end
	end

	-- 应用高亮
	local ns = vim.api.nvim_create_namespace("todo2_heatmap")
	for _, h in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(buf, ns, h[4], h[1], h[2], h[3])
	end

	-- 需要重新构建 highlights 包含任务对象
	-- 重新渲染以获取带任务对象的 highlights
	local _, new_highlights = M.render(tasks)

	-- 清除并重新应用高亮
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, h in ipairs(new_highlights) do
		vim.api.nvim_buf_add_highlight(buf, ns, h[4], h[1], h[2], h[3])
	end

	-- 鼠标点击跳转
	-- FIX:ref:16fc5a
	vim.keymap.set("n", "<LeftMouse>", function()
		local mouse = vim.fn.getmousepos()
		local line = mouse.line - 1
		local col = mouse.column

		-- 查找点击的任务
		for _, h in ipairs(new_highlights) do
			if h[1] == line and col >= h[2] and col < h[3] and h[5] then
				local task = h[5]
				vim.api.nvim_win_close(win, true)
				vim.schedule(function()
					local jumper = require("todo2.task.jumper")
					if task.locations and task.locations.code then
						jumper.jump_to_task(task.id, "code")
					elseif task.locations and task.locations.todo then
						jumper.jump_to_task(task.id, "todo")
					else
						vim.notify(string.format("任务 %s 没有关联位置", task.id), vim.log.levels.WARN)
					end
				end)
				return
			end
		end
	end, { buffer = buf })

	-- 关闭窗口
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })
end

return M
