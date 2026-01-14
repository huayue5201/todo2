-- lua/todo2/link/init.lua
local M = {}

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
-- 默认配置
---------------------------------------------------------------------
local default_config = {
	jump = {
		keep_todo_split_when_jump = false,
		default_todo_window_mode = "float",
		reuse_existing_windows = true,
	},
	preview = {
		enabled = true,
		border = "rounded",
	},
	render = {
		show_status_in_code = true,
		-- 1 = 数字风 (3/7)
		-- 3 = 百分比风 42%
		-- 5 = 进度条风 [■■■□□]
		progress_style = 5,
		-- ⭐ TAG 配置（可扩展）
		tags = {
			TODO = {
				icon = " ",
				hl = "TodoColor",
			},
			FIXME = {
				icon = "󰁨 ",
				hl = "FixmeColor",
			},
			NOTE = {
				icon = "󱓩 ",
				hl = "NoteColor",
			},
			IDEA = {
				icon = "󰅪 ",
				hl = "IdeaColor",
			},
		},

		status_icons = {
			todo = "☐",
			done = "✓",
		},
	},
}

---------------------------------------------------------------------
-- 当前配置
---------------------------------------------------------------------
local config = vim.deepcopy(default_config)

---------------------------------------------------------------------
-- 延迟加载子模块
---------------------------------------------------------------------
local utils
local creator
local jumper
local renderer
local syncer
local preview
local cleaner
local searcher

local function get_module(name)
	if name == "utils" then
		utils = utils or require("todo2.link.utils")
		return utils
	elseif name == "creator" then
		creator = creator or require("todo2.link.creator")
		return creator
	elseif name == "jumper" then
		jumper = jumper or require("todo2.link.jumper")
		return jumper
	elseif name == "renderer" then
		renderer = renderer or require("todo2.link.renderer")
		return renderer
	elseif name == "syncer" then
		syncer = syncer or require("todo2.link.syncer")
		return syncer
	elseif name == "preview" then
		preview = preview or require("todo2.link.preview")
		return preview
	elseif name == "cleaner" then
		cleaner = cleaner or require("todo2.link.cleaner")
		return cleaner
	elseif name == "searcher" then
		searcher = searcher or require("todo2.link.searcher")
		return searcher
	end
end

---------------------------------------------------------------------
-- 配置管理
---------------------------------------------------------------------
function M.setup(user_config)
	config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user_config or {})

	-- ⭐ 自动生成 TAG 高亮组
	if config.render and config.render.tags then
		setup_tag_highlights(config.render.tags)
	end
end

function M.get_jump_config()
	return config.jump or default_config.jump
end

function M.get_preview_config()
	return config.preview or default_config.preview
end

function M.get_render_config()
	return config.render or default_config.render
end

function M.get_config()
	return config
end

---------------------------------------------------------------------
-- 公开 API
---------------------------------------------------------------------
function M.create_link()
	return get_module("creator").create_link()
end

function M.jump_to_todo()
	return get_module("jumper").jump_to_todo()
end

function M.jump_to_code()
	return get_module("jumper").jump_to_code()
end

function M.jump_dynamic()
	return get_module("jumper").jump_dynamic()
end

function M.render_code_status(bufnr)
	return get_module("renderer").render_code_status(bufnr)
end

function M.sync_code_links()
	return get_module("syncer").sync_code_links()
end

function M.sync_todo_links()
	return get_module("syncer").sync_todo_links()
end

function M.preview_todo()
	return get_module("preview").preview_todo()
end

function M.preview_code()
	return get_module("preview").preview_code()
end

function M.cleanup_all_links()
	return get_module("cleaner").cleanup_all_links()
end

function M.search_links_by_file(filepath)
	return get_module("searcher").search_links_by_file(filepath)
end

function M.search_links_by_pattern(pattern)
	return get_module("searcher").search_links_by_pattern(pattern)
end

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
function M.generate_id()
	return get_module("utils").generate_id()
end

function M.find_task_insert_position(lines)
	return get_module("utils").find_task_insert_position(lines)
end

function M.is_todo_floating_window(win_id)
	return get_module("utils").is_todo_floating_window(win_id)
end

return M
