-- lua/todo2/link/init.lua
--- @module todo2.link
--- @brief 双向链接系统核心模块，使用统一模块加载器

local M = {}

---------------------------------------------------------------------
-- 统一的模块加载器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 统一的配置管理
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- 根据 tag 名字生成稳定颜色（HSL → RGB）
---------------------------------------------------------------------
local function hsl_to_hex(h, s, l)
	local function f(n)
		local k = (n + h / 30) % 12
		local a = s * math.min(l, 1 - l)
		local c = l - a * math.max(-1, math.min(math.min(k - 3, 9 - k), 1))
		return math.floor(c * 255 + 0.5)
	end
	return string.format("#%02x%02x%02x", f(0), f(8), f(4))
end

local function generate_color_for_tag(tag)
	-- hash tag → 0~360
	local hash = 0
	for i = 1, #tag do
		hash = (hash + tag:byte(i)) % 360
	end

	local h = hash
	local s = 0.55

	-- 根据主题调整亮度
	local bg = vim.o.background -- "dark" or "light"
	local l = (bg == "dark") and 0.70 or 0.35

	return hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 自动生成 TAG 高亮组
---------------------------------------------------------------------
local function setup_tag_highlights(tags)
	for tag, style in pairs(tags) do
		-- 自动生成 hl 名字
		if not style.hl then
			style.hl = "Todo2Tag_" .. tag
		end

		-- 自动生成颜色
		local color = style.color or generate_color_for_tag(tag)

		-- 如果 highlight 不存在，则创建
		if vim.fn.hlexists(style.hl) == 0 then
			vim.api.nvim_set_hl(0, style.hl, {
				fg = color,
				bold = true,
			})
		end
	end
end

---------------------------------------------------------------------
-- 自动根据主题生成颜色（状态图标 / 进度条）
---------------------------------------------------------------------
local function generate_theme_color(kind)
	-- kind: "done" | "todo"
	local h = 120
	local s = (kind == "done") and 0.70 or 0.20

	local bg = vim.o.background
	local l = (bg == "dark") and ((kind == "done") and 0.75 or 0.55) or ((kind == "done") and 0.35 or 0.25)

	return hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 自动生成状态图标 / 进度条高亮组
---------------------------------------------------------------------
local function setup_dynamic_status_highlights()
	vim.api.nvim_set_hl(0, "Todo2StatusDone", {
		fg = generate_theme_color("done"),
		bold = true,
	})

	vim.api.nvim_set_hl(0, "Todo2StatusTodo", {
		fg = generate_theme_color("todo"),
	})

	vim.api.nvim_set_hl(0, "Todo2ProgressDone", {
		fg = generate_theme_color("done"),
	})

	vim.api.nvim_set_hl(0, "Todo2ProgressTodo", {
		fg = generate_theme_color("todo"),
	})
end

---------------------------------------------------------------------
-- 配置管理
---------------------------------------------------------------------
function M.setup()
	-- 获取 link 配置
	local link_config = config.get_link()

	-- ⭐ 自动生成 TAG 高亮组
	if link_config.render then
		if link_config.render.tags then
			setup_tag_highlights(link_config.render.tags)
		end
		setup_dynamic_status_highlights()
	end

	-- ⭐ 插件启动时自动清理数据库
	local cleaner = module.get("link.cleaner")
	if cleaner and cleaner.cleanup_all_links then
		cleaner.cleanup_all_links()
	end
end

function M.get_jump_config()
	return config.get_link_jump()
end

function M.get_preview_config()
	return config.get_link_preview()
end

function M.get_render_config()
	return config.get_link_render()
end

function M.get_config()
	return config.get_link()
end

---------------------------------------------------------------------
-- 公开 API（使用统一的模块加载器）
---------------------------------------------------------------------

function M.create_link()
	return module.get("link.creator").create_link()
end

function M.jump_to_todo()
	return module.get("link.jumper").jump_to_todo()
end

function M.jump_to_code()
	return module.get("link.jumper").jump_to_code()
end

function M.jump_dynamic()
	return module.get("link.jumper").jump_dynamic()
end

function M.render_code_status(bufnr)
	return module.get("link.renderer").render_code_status(bufnr)
end

function M.sync_code_links()
	return module.get("link.syncer").sync_code_links()
end

function M.sync_todo_links()
	return module.get("link.syncer").sync_todo_links()
end

function M.preview_todo()
	return module.get("link.preview").preview_todo()
end

function M.preview_code()
	return module.get("link.preview").preview_code()
end

function M.cleanup_all_links()
	return module.get("link.cleaner").cleanup_all_links()
end

function M.search_links_by_file(filepath)
	return module.get("link.searcher").search_links_by_file(filepath)
end

function M.search_links_by_pattern(pattern)
	return module.get("link.searcher").search_links_by_pattern(pattern)
end

---------------------------------------------------------------------
-- 工具函数（使用统一的模块加载器）
---------------------------------------------------------------------

function M.generate_id()
	return module.get("link.utils").generate_id()
end

function M.find_task_insert_position(lines)
	return module.get("link.utils").find_task_insert_position(lines)
end

function M.is_todo_floating_window(win_id)
	return module.get("link.utils").is_todo_floating_window(win_id)
end

---------------------------------------------------------------------
-- 返回模块
---------------------------------------------------------------------
return M
