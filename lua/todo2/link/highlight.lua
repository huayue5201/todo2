-- lua/todo2/link/highlight.lua
--- @module todo2.link.highlight
--- @brief 高亮系统模块，包含颜色生成和高亮组管理
--- ⭐ 增强：添加上下文高亮组

local M = {}

---------------------------------------------------------------------
-- 配置管理
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- HSL 颜色转换函数
---------------------------------------------------------------------

function M.hsl_to_hex(h, s, l)
	local function f(n)
		local k = (n + h / 30) % 12
		local a = s * math.min(l, 1 - l)
		local c = l - a * math.max(-1, math.min(math.min(k - 3, 9 - k), 1))
		return math.floor(c * 255 + 0.5)
	end
	return string.format("#%02x%02x%02x", f(0), f(8), f(4))
end

---------------------------------------------------------------------
-- 标签颜色生成
---------------------------------------------------------------------

function M.generate_color_for_tag(tag)
	local hash = 0
	for i = 1, #tag do
		hash = (hash + tag:byte(i)) % 360
	end

	local h = hash
	local s = 0.55

	local bg = vim.o.background
	local l = (bg == "dark") and 0.70 or 0.35

	return M.hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 主题颜色生成
---------------------------------------------------------------------

function M.generate_theme_color(kind)
	local h = 120
	local s = (kind == "done") and 0.70 or 0.20

	local bg = vim.o.background
	local l = (bg == "dark") and ((kind == "done") and 0.75 or 0.55) or ((kind == "done") and 0.35 or 0.25)

	return M.hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 标签高亮组管理
---------------------------------------------------------------------

function M.setup_tag_highlights(tags)
	tags = tags or config.get("tags") or {}

	for tag, style in pairs(tags) do
		if not style.hl then
			style.hl = "Todo2Tag_" .. tag
		end

		local color = style.color or M.generate_color_for_tag(tag)

		if vim.fn.hlexists(style.hl) == 0 then
			vim.api.nvim_set_hl(0, style.hl, {
				fg = color,
				bold = true,
			})
		end
	end
end

---------------------------------------------------------------------
-- 动态状态高亮组管理
---------------------------------------------------------------------

function M.setup_dynamic_status_highlights()
	vim.api.nvim_set_hl(0, "Todo2StatusDone", {
		fg = M.generate_theme_color("done"),
		bold = true,
	})

	vim.api.nvim_set_hl(0, "Todo2StatusTodo", {
		fg = M.generate_theme_color("todo"),
	})

	vim.api.nvim_set_hl(0, "Todo2ProgressDone", {
		fg = M.generate_theme_color("done"),
	})

	vim.api.nvim_set_hl(0, "Todo2ProgressTodo", {
		fg = M.generate_theme_color("todo"),
	})
end

---------------------------------------------------------------------
-- 状态颜色高亮组管理
---------------------------------------------------------------------

function M.setup_status_highlights()
	local status_colors = config.get("status_colors")
		or {
			normal = "#51cf66",
			urgent = "#ff6b6b",
			waiting = "#ffd43b",
			completed = "#868e96",
		}

	for status, color in pairs(status_colors) do
		local hl_name = "TodoStatus" .. status:sub(1, 1):upper() .. status:sub(2)

		if vim.fn.hlexists(hl_name) == 0 then
			vim.api.nvim_set_hl(0, hl_name, {
				fg = color,
			})
		end
	end
end

---------------------------------------------------------------------
-- 完成状态高亮组管理
---------------------------------------------------------------------

function M.setup_completion_highlights()
	if vim.fn.hlexists("TodoStrikethrough") == 0 then
		vim.api.nvim_set_hl(0, "TodoStrikethrough", {
			strikethrough = true,
			fg = "#868e96",
		})
	end

	if vim.fn.hlexists("TodoCompleted") == 0 then
		vim.api.nvim_set_hl(0, "TodoCompleted", {
			fg = "#868e96",
		})
	end
end

---------------------------------------------------------------------
-- 隐藏相关高亮组管理
---------------------------------------------------------------------

function M.setup_conceal_highlights()
	if vim.fn.hlexists("TodoCheckboxTodo") == 0 then
		vim.api.nvim_set_hl(0, "TodoCheckboxTodo", {
			fg = M.generate_theme_color("todo"),
		})
	end

	if vim.fn.hlexists("TodoCheckboxDone") == 0 then
		vim.api.nvim_set_hl(0, "TodoCheckboxDone", {
			fg = M.generate_theme_color("done"),
		})
	end

	if vim.fn.hlexists("TodoCheckboxArchived") == 0 then
		vim.api.nvim_set_hl(0, "TodoCheckboxArchived", {
			fg = "#868e96",
		})
	end

	if vim.fn.hlexists("TodoIdIcon") == 0 then
		vim.api.nvim_set_hl(0, "TodoIdIcon", {
			fg = "#868e96",
		})
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：上下文高亮组
---------------------------------------------------------------------
function M.setup_context_highlights()
	-- 有效上下文高亮
	if vim.fn.hlexists("TodoContextValid") == 0 then
		vim.api.nvim_set_hl(0, "TodoContextValid", {
			fg = "#51cf66", -- 绿色
			undercurl = false,
		})
	end

	-- 无效上下文高亮
	if vim.fn.hlexists("TodoContextInvalid") == 0 then
		vim.api.nvim_set_hl(0, "TodoContextInvalid", {
			fg = "#ff6b6b", -- 红色
			undercurl = true,
		})
	end

	-- 过期上下文高亮
	if vim.fn.hlexists("TodoContextExpired") == 0 then
		vim.api.nvim_set_hl(0, "TodoContextExpired", {
			fg = "#ffd43b", -- 黄色
			undercurl = true,
		})
	end
end

---------------------------------------------------------------------
-- ⭐ 修改：初始化所有高亮
---------------------------------------------------------------------
function M.setup_all_highlights()
	M.setup_tag_highlights()
	M.setup_dynamic_status_highlights()
	M.setup_status_highlights()
	M.setup_completion_highlights()
	M.setup_conceal_highlights()
	M.setup_context_highlights()
end

---------------------------------------------------------------------
-- 渲染器高亮管理
---------------------------------------------------------------------
function M.setup_render_line_highlights(bufnr, row, state, cfg) end

return M
