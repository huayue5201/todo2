-- lua/todo2/link/renderer.lua
--- @module todo2.link.renderer
--- @brief 在代码文件中渲染 TAG 状态（☐ / ✓），并显示任务内容与父子任务进度（增量刷新版）

local M = {}

local utf8 = require("todo2.utf8")

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
-- ⭐ 行级渲染缓存（核心）
-- render_cache[bufnr][row] = { id, status, text, progress }
---------------------------------------------------------------------

local render_cache = {}

local function ensure_cache(bufnr)
	if not render_cache[bufnr] then
		render_cache[bufnr] = {}
	end
	return render_cache[bufnr]
end

---------------------------------------------------------------------
-- 缓存系统：按 TODO 文件 + mtime 缓存任务树与统计
---------------------------------------------------------------------

local todo_cache = {}

local function get_file_mtime(path)
	local stat = vim.loop.fs_stat(path)
	if not stat or not stat.mtime then
		return 0
	end
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
-- 工具函数：读取 TODO 状态（☐ / ✓）
---------------------------------------------------------------------

local function read_todo_status(todo_path, line)
	local stats = get_todo_stats(todo_path)
	if not stats then
		return nil
	end

	local todo_line = stats.lines[line]
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

---------------------------------------------------------------------
-- 工具函数：读取 TODO 文本
---------------------------------------------------------------------

local function read_todo_text(todo_path, line, max_len)
	local stats = get_todo_stats(todo_path)
	if not stats then
		return nil
	end

	local raw = stats.lines[line]
	if not raw then
		return nil
	end

	local text = raw:match("%] (.+)$") or raw
	text = text:gsub("{#%w+}", "")
	text = vim.trim(text)

	max_len = max_len or 40
	if #text > max_len then
		text = utf8.sub(text, max_len) .. "..."
	end

	return text
end

---------------------------------------------------------------------
-- 任务进度
---------------------------------------------------------------------

local function get_task_progress(todo_path, line)
	local stats = get_todo_stats(todo_path)
	if not stats then
		return nil
	end

	local raw = stats.lines[line]
	if not raw then
		return nil
	end

	local id = raw:match("{#(%w+)}")
	if not id then
		return nil
	end

	local struct = get_store().get_task_structure(id)
	if not struct or not struct.children or #struct.children == 0 then
		return nil
	end

	local done = 0
	local total = 0

	for _, cid in ipairs(struct.children) do
		local child = get_store().get_todo_link(cid)
		if child then
			local _, _, _, is_done = read_todo_status(child.path, child.line)
			if is_done ~= nil then
				total = total + 1
				if is_done then
					done = done + 1
				end
			end
		end
	end

	if total == 0 then
		return nil
	end

	return {
		done = done,
		total = total,
		percent = math.floor(done / total * 100),
	}
end

---------------------------------------------------------------------
-- 进度渲染
---------------------------------------------------------------------

local function render_progress_numeric(p)
	return string.format("(%d/%d)", p.done, p.total)
end

local function render_progress_percent(p)
	return string.format("%d%%", p.percent)
end

local function render_progress_bar(p)
	local total = p.total
	local len = math.max(5, math.min(20, total))
	local filled = math.floor(p.percent / 100 * len)
	return "[" .. string.rep("▰", filled) .. string.rep("▱", len - filled) .. "]"
end

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
		return render_progress_numeric(p)
	end
end

---------------------------------------------------------------------
-- ⭐ 构造行渲染状态（用于 diff）
---------------------------------------------------------------------

local function compute_render_state(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line then
		return nil
	end

	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return nil
	end

	local link = get_store().get_todo_link(id, { force_relocate = true })
	if not link then
		return nil
	end

	local icon, _, _, is_done = read_todo_status(link.path, link.line)
	if not icon then
		return nil
	end

	local text = read_todo_text(link.path, link.line, 40)
	local progress = get_task_progress(link.path, link.line)
	local progress_text = render_progress(progress)

	return {
		id = id,
		tag = tag,
		icon = icon,
		text = text,
		progress = progress_text,
		is_done = is_done,
	}
end

---------------------------------------------------------------------
-- ⭐ 渲染单行（增量 diff）
---------------------------------------------------------------------

function M.render_line(bufnr, row)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local cache = ensure_cache(bufnr)
	local new = compute_render_state(bufnr, row)

	-- 如果没有 TAG → 清除 extmark + 清除缓存
	if not new then
		if cache[row] then
			cache[row] = nil
			vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
		end
		return
	end

	-- diff：如果完全一致 → 不刷新
	local old = cache[row]
	if old and old.id == new.id and old.icon == new.icon and old.text == new.text and old.progress == new.progress then
		return
	end

	-- 更新缓存
	cache[row] = new

	-- 清除旧 extmark
	vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)

	-- 获取 TAG 样式
	local cfg = get_link_mod().get_render_config()
	local style = cfg.tags and cfg.tags[new.tag] or cfg.tags["TODO"]

	-- 构造虚拟文本
	local virt = {}

	table.insert(virt, {
		" " .. new.icon .. " ",
		new.is_done and "Todo2StatusDone" or "Todo2StatusTodo",
	})

	table.insert(virt, { new.tag, style.hl })

	if new.text and new.text ~= "" then
		table.insert(virt, { " " .. new.text, style.hl })
	end

	if new.progress and new.progress ~= "" then
		table.insert(virt, { " " .. new.progress, "Todo2ProgressDone" })
	end

	-- 设置 extmark
	vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
		virt_text = virt,
		virt_text_pos = "eol",
		hl_mode = "combine",
		right_gravity = false,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- ⭐ 全量渲染（首次打开 / 手动刷新）
-- 但内部仍然是增量 diff，不会重复渲染
---------------------------------------------------------------------

function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local cache = ensure_cache(bufnr)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local max_row = #lines - 1

	-- 清理缓存中已不存在的行
	for row, _ in pairs(cache) do
		if row > max_row then
			cache[row] = nil
			vim.api.nvim_buf_clear_namespace(bufnr, ns, row, row + 1)
		end
	end

	-- 渲染所有行（内部自动 diff）
	for row = 0, max_row do
		M.render_line(bufnr, row)
	end
end

return M
