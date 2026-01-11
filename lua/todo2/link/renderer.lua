--- @module todo2.link.renderer
--- @brief 在代码文件中渲染 TAG 状态（☐ / ✓），并显示任务内容（不混用 TAG 图标）

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

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("todo2_code_status")

---------------------------------------------------------------------
-- 工具函数：读取 TODO 文件中的状态
---------------------------------------------------------------------

local function read_todo_status(todo_path, line)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")
	if vim.fn.filereadable(todo_path) == 0 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		return nil
	end

	local todo_line = lines[line]
	if not todo_line then
		return nil
	end

	local status = todo_line:match("%[(.)%]")
	if not status then
		return nil
	end

	if status == "x" or status == "X" then
		return "✓", "已完成", "String", true
	else
		return "☐", "未完成", "Error", false
	end
end

---------------------------------------------------------------------
-- 读取 TODO 文本内容（并截断 + 过滤 {#xxxxxx}）
---------------------------------------------------------------------

local function read_todo_text(todo_path, line, max_len)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")
	if vim.fn.filereadable(todo_path) == 0 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		return nil
	end

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
-- ⭐ 增量渲染：只渲染某一行（不混用 TAG 图标）
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

	-- ⭐ 支持 TAG:ref:xxxxxx
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return
	end

	-- 获取 TAG 样式（只用于颜色，不用于图标）
	local cfg = get_link_mod().get_render_config()
	local style = cfg.tags and cfg.tags[tag] or cfg.tags["TODO"]

	-- 获取链接（自动重新定位）
	local link = get_store().get_todo_link(id, { force_relocate = true })
	if not link then
		return
	end

	-- ⭐ 状态图标（☐ / ✓）来自 TODO 文件
	local status_icon, status_text, status_hl, is_done = read_todo_status(link.path, link.line)
	if not status_icon then
		return
	end

	-- ⭐ TAG 图标不参与状态变化（不混用）
	-- 如果你想显示 TAG 图标，可以启用这一行：
	-- local tag_icon = style.icon or ""

	-- 任务内容
	local todo_text = read_todo_text(link.path, link.line, 40)

	-- ⭐ 最终显示文本（状态图标 + TAG 名 + 内容）
	-- 不混用 TAG 图标
	local display = string.format("%s %s", status_icon, tag)

	if todo_text then
		display = display .. "  " .. todo_text
	end

	-- 设置虚拟文本
	vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
		virt_text = {
			{ "  " .. display, style.hl or status_hl },
		},
		virt_text_pos = "eol",
		hl_mode = "combine",
		right_gravity = false,
		priority = 100,
	})
end

---------------------------------------------------------------------
-- ⭐ 全量渲染（用于首次打开文件）
---------------------------------------------------------------------

function M.render_code_status(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i = 1, #lines do
		M.render_line(bufnr, i - 1)
	end
end

return M
