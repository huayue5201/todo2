-- lua/todo2/render/fold.lua
-- TODO 文件里默认折叠任务正文（描述）。
--
-- 折叠级别由 description.scan 预先算好并按 changedtick 缓存，foldexpr 只做一次
-- 数组查表，避免每次重绘都重新扫描全文件。

local M = {}

local description = require("todo2.core.description")
local format = require("todo2.utils.format")
local config = require("todo2.config")
local checkbox = require("todo2.render.checkbox")

--- 取任务状态。
--- 惰性 require：render 层不应在加载期依赖 store，否则与 conceal 形成加载环
--- （store → … → conceal → fold）。
---@param id string|nil
---@return string|nil
local function task_status(id)
	if not id then
		return nil
	end
	local task = require("todo2.store.task.core").get_task(id)
	return task and task.core.status
end

---@type table<number, { tick: number, levels: table<number, number> }>
local cache = {}

--- 取（必要时重建）缓冲区的折叠级别表：正文行与其任务行为 1，其余为 0
---@param bufnr number
---@return table<number, number>
local function levels(bufnr)
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = cache[bufnr]
	if cached and cached.tick == tick then
		return cached.levels
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local result = {}
	-- 只折叠正文行（任务行为 0），使任务行始终可见，正文可单独折叠。
	for _, block in pairs(description.scan(lines)) do
		for i = block.start_line, block.end_line do
			result[i] = 1
		end
	end

	cache[bufnr] = { tick = tick, levels = result }
	return result
end

--- foldexpr：正文行与所属任务行同一级折叠（首行即任务行）
---@return string
function M.level()
	local n = levels(vim.api.nvim_get_current_buf())[vim.v.lnum]
	return n and tostring(n) or "0"
end

--- foldtext：收起正文时显示行数 + 首行预览（任务行不再进入折叠）。
---@return string
function M.text()
	local count = vim.v.foldend - vim.v.foldstart + 1
	local line = vim.fn.getline(vim.v.foldstart)

	local parsed = format.parse_task_line(line)
	if not parsed then
		-- 正文折叠：任务行已由外层渲染，这里只提示正文行数与首行
		return string.format("  ¶ %d lines  %s", count, (line:gsub("^%s+", "")))
	end

	local status = task_status(parsed.id)
	if not status then
		status = require("todo2.core.status").resolve_checkbox(parsed.checkbox)
	end

	return string.format("%s %s  ¶ %d lines", checkbox.get(status), parsed.content, count)
end

--- 为 TODO 窗口启用正文折叠（窗口局部；只初始化一次，不覆盖用户展开/收起状态）
---@param bufnr number
function M.setup_window(bufnr)
	if not config.get("description.fold") then
		return
	end

	local win = vim.fn.bufwinid(bufnr)
	if win == -1 or vim.w[win].todo2_fold_set then
		return
	end

	pcall(function()
		vim.api.nvim_set_option_value("foldmethod", "expr", { scope = "local", win = win })
		vim.api.nvim_set_option_value(
			"foldexpr",
			"v:lua.require'todo2.render.fold'.level()",
			{ scope = "local", win = win }
		)
		vim.api.nvim_set_option_value(
			"foldtext",
			"v:lua.require'todo2.render.fold'.text()",
			{ scope = "local", win = win }
		)
		vim.api.nvim_set_option_value("foldenable", true, { scope = "local", win = win })
		vim.api.nvim_set_option_value("foldlevel", 0, { scope = "local", win = win })
		vim.w[win].todo2_fold_set = true
	end)
end

--- 丢弃某个缓冲区的折叠级别缓存
---@param bufnr number
function M.clear(bufnr)
	cache[bufnr] = nil
end

return M
