--- @module todo2.link.renderer
--- @brief 在代码文件中渲染 TAG 状态（☐ / ✓），并显示任务内容与父子任务进度

local M = {}

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

local link_mod
local function get_link_mod()
	if not link_mod then
		link_mod = require("todo2.link")
	end
	return link_mod
end

local core
local function get_core()
	if not core then
		core = require("todo2.core")
	end
	return core
end

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("todo2_code_status")

---------------------------------------------------------------------
-- 缓存系统：按 TODO 文件 + mtime 缓存任务树与统计
---------------------------------------------------------------------

-- key: abs_path
-- value: { mtime = number, lines = string[], tasks = table, roots = table }
local todo_cache = {}

---------------------------------------------------------------------
-- 工具函数：安全读取文件 + mtime
---------------------------------------------------------------------

local function get_file_mtime(path)
	local stat = vim.loop.fs_stat(path)
	if not stat or not stat.mtime then
		return 0
	end
	-- 纳秒级时间戳，避免同一秒写入导致缓存不刷新
	return stat.mtime.sec * 1e9 + (stat.mtime.nsec or 0)
end

local function safe_readfile(path)
	path = vim.fn.fnamemodify(path, ":p")
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end
	return lines
end

---------------------------------------------------------------------
-- 获取 / 解析 TODO 任务树 + 统计
---------------------------------------------------------------------

local function get_todo_stats(todo_path)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")
	local mtime = get_file_mtime(todo_path)
	if mtime == 0 then
		return nil
	end

	local cached = todo_cache[todo_path]
	if cached and cached.mtime == mtime then
		return cached
	end

	local lines = safe_readfile(todo_path)
	if not lines then
		return nil
	end

	local core_mod = get_core()
	local tasks = core_mod.parse_tasks(lines)
	core_mod.calculate_all_stats(tasks)
	local roots = core_mod.get_root_tasks(tasks)

	cached = {
		mtime = mtime,
		lines = lines,
		tasks = tasks,
		roots = roots,
	}
	todo_cache[todo_path] = cached
	return cached
end

---------------------------------------------------------------------
-- 任务进度：根据 TODO 文件中的父子任务统计
---------------------------------------------------------------------

--- 获取某一行对应任务的进度（如果是父任务且有子任务）
--- @param todo_path string
--- @param line integer 1-based
--- @return table|nil { done, total, percent }
local function get_task_progress(todo_path, line)
	local stats = get_todo_stats(todo_path)
	if not stats then
		return nil
	end

	local tasks = stats.tasks
	local target = nil

	for _, t in ipairs(tasks) do
		if t.line_num == line then
			target = t
			break
		end
	end

	if not target then
		return nil
	end

	-- 只有有子任务的任务才显示进度
	if not target.children or #target.children == 0 then
		return nil
	end

	local s = target.stats
	if not s or not s.total or s.total == 0 then
		return nil
	end

	return {
		done = s.done or 0,
		total = s.total or 0,
		percent = math.floor((s.done or 0) / s.total * 100),
	}
end

---------------------------------------------------------------------
-- 工具函数：读取 TODO 状态与文本
---------------------------------------------------------------------

local function read_todo_status(todo_path, line)
	local stats = get_todo_stats(todo_path)
	if not stats then
		return nil
	end

	local lines = stats.lines
	local todo_line = lines[line]
	if not todo_line then
		return nil
	end

	local status = todo_line:match("%[(.)%]")
	if not status then
		return nil
	end

	if status == "x" or status == "X" then
		return "✓", "已完成", true
	else
		return "☐", "未完成", false
	end
end

local function read_todo_text(todo_path, line, max_len)
	local stats = get_todo_stats(todo_path)
	if not stats then
		return nil
	end

	local lines = stats.lines
	local raw = lines[line]
	if not raw then
		return nil
	end

	-- 提取任务文本
	local text = raw:match("%] (.+)$") or raw

	-- 过滤 {#xxxxxx}
	text = text:gsub("{#%w+}", "")
	text = vim.trim(text)

	-- 截断
	max_len = max_len or 40
	if #text > max_len then
		text = text:sub(1, max_len) .. "..."
	end

	return text
end

---------------------------------------------------------------------
-- 三种进度风格渲染（1 / 3 / 5）
---------------------------------------------------------------------

-- 数字模式: (3/7)
local function render_progress_numeric(p)
	return string.format("(%d/%d)", p.done, p.total)
end

-- 百分比模式: 42%
local function render_progress_percent(p)
	return string.format("%d%%", p.percent)
end

-- 进度条模式: [■■■□□]
local function render_progress_bar(p)
	local total = p.total
	if total <= 0 then
		return ""
	end

	-- 智能长度：根据 total 自动调整 5～20 格
	local len = math.max(5, math.min(20, total))
	local filled = math.floor(p.percent / 100 * len)

	return "[" .. string.rep("▰", filled) .. string.rep("▱", len - filled) .. "]"
end

---------------------------------------------------------------------
-- 根据配置选择进度风格
---------------------------------------------------------------------

local function render_progress(p)
	if not p then
		return ""
	end

	local cfg = get_link_mod().get_render_config()
	local style = (cfg and cfg.progress_style) or 1

	if style == 1 then
		return render_progress_numeric(p)
	elseif style == 3 then
		return render_progress_percent(p)
	elseif style == 5 then
		return render_progress_bar(p)
	else
		-- 默认数字模式
		return render_progress_numeric(p)
	end
end

---------------------------------------------------------------------
-- ⭐ 渲染单行（核心）
---------------------------------------------------------------------
function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 清除该行旧的 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return
	end

	-----------------------------------------------------------------
	-- 解析 TAG:ref:xxxxxx
	-----------------------------------------------------------------
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return
	end

	-----------------------------------------------------------------
	-- 获取 TAG 样式（颜色）
	-----------------------------------------------------------------
	local cfg = get_link_mod().get_render_config()
	local style = cfg.tags and cfg.tags[tag] or cfg.tags["TODO"]

	-----------------------------------------------------------------
	-- 获取链接（自动重新定位）
	-----------------------------------------------------------------
	local link = get_store().get_todo_link(id, { force_relocate = true })
	if not link then
		return
	end

	-----------------------------------------------------------------
	-- 获取状态图标（☐ / ✓）
	-----------------------------------------------------------------
	local status_icon, _, _, is_done = read_todo_status(link.path, link.line)
	if not status_icon then
		return
	end

	-----------------------------------------------------------------
	-- 获取任务文本
	-----------------------------------------------------------------
	local todo_text = read_todo_text(link.path, link.line, 40)

	-----------------------------------------------------------------
	-- 获取父子任务进度（如果是父任务）
	-----------------------------------------------------------------
	local progress = get_task_progress(link.path, link.line)
	local progress_text = render_progress(progress)

	-----------------------------------------------------------------
	-- ⭐ 构造多段虚拟文本（核心增强）
	-----------------------------------------------------------------
	local virt = {}

	-- 状态图标
	table.insert(virt, {
		" " .. status_icon .. " ",
		is_done and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	-- TAG（保持原来的 TAG 颜色）
	table.insert(virt, { tag, style.hl })

	-- 任务文本（保持 TAG 的颜色）
	if todo_text and todo_text ~= "" then
		table.insert(virt, { " " .. todo_text, style.hl })
	end

	-- 进度
	if progress_text ~= "" then
		table.insert(virt, { " " })

		if cfg.progress_style == 5 and progress then
			-- 进度条模式：逐字符高亮
			local total = progress.total
			local len = math.max(5, math.min(20, total))
			local filled = math.floor(progress.percent / 100 * len)

			-- table.insert(virt, { "[" })

			for i = 1, filled do
				table.insert(virt, { "▰", "Todo2ProgressDone" })
			end
			for i = filled + 1, len do
				table.insert(virt, { "▱", "Todo2ProgressTodo" })
			end

			-- table.insert(virt, { "]" })
			-- ⭐ 在进度条后追加百分比
			local percent_text = string.format(" %d%%", progress.percent)
			table.insert(virt, { percent_text, "Todo2ProgressDone" })

			-- ⭐ 再追加数字 (done/total)
			local numeric_text = string.format(" (%d/%d)", progress.done, progress.total)
			table.insert(virt, { numeric_text, "Todo2ProgressDone" })
		else
			-- 数字 / 百分比模式
			table.insert(virt, { progress_text, "Todo2ProgressDone" })
		end
	end
	-----------------------------------------------------------------
	-- 设置虚拟文本（extmark）
	-----------------------------------------------------------------
	vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "eol",
		hl_mode = "combine",
		right_gravity = false,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- ⭐ 全量渲染（用于首次打开文件 / 手动刷新）
---------------------------------------------------------------------

function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 清除所有 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i = 1, #lines do
		M.render_line(bufnr, i - 1)
	end
end

return M
