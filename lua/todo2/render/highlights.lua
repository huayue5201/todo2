-- lua/todo2/render/highlights.lua
-- 精简版：只保留当前 todo2 架构需要的高亮组

local M = {}

local config = require("todo2.config")

---------------------------------------------------------------------
-- HSL → HEX
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
-- tag 颜色生成
---------------------------------------------------------------------
function M.generate_color_for_tag(tag)
	local hash = 0
	for i = 1, #tag do
		hash = (hash + tag:byte(i)) % 360
	end
	local h = hash
	local s = 0.55
	local l = (vim.o.background == "dark") and 0.70 or 0.35
	return M.hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 主题色生成（checkbox / 状态）
---------------------------------------------------------------------
function M.generate_theme_color(kind)
	local h = 120
	local s = (kind == "done") and 0.70 or 0.20
	local l = (vim.o.background == "dark") and ((kind == "done") and 0.75 or 0.55)
		or ((kind == "done") and 0.35 or 0.25)
	return M.hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 静态高亮（无废弃项）
---------------------------------------------------------------------
M.static_highlights = {
	-- 完成状态
	TodoCompleted = { fg = "#868e96", strikethrough = true, italic = true },
	TodoStrikethrough = { fg = "#868e96", strikethrough = true },

	-- checkbox（动态设置颜色）
	TodoCheckboxTodo = nil,
	TodoCheckboxDone = nil,
	TodoCheckboxArchived = { fg = "#868e96" },

	-- ID 图标
	TodoIdIcon = { fg = "#bb9af7" },

	-- AI 图标
	Todo2AIIcon = { fg = "#FFD700" }, -- 金色
}

---------------------------------------------------------------------
-- tag 高亮
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
-- 动态状态高亮
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
-- 状态颜色（normal/urgent/waiting/completed）
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
			vim.api.nvim_set_hl(0, hl_name, { fg = color })
		end
	end
end

---------------------------------------------------------------------
-- checkbox 高亮
---------------------------------------------------------------------
function M.setup_conceal_highlights()
	vim.api.nvim_set_hl(0, "TodoCheckboxTodo", {
		fg = M.generate_theme_color("todo"),
	})

	vim.api.nvim_set_hl(0, "TodoCheckboxDone", {
		fg = M.generate_theme_color("done"),
	})

	vim.api.nvim_set_hl(0, "TodoCheckboxArchived", {
		fg = "#868e96",
	})

	vim.api.nvim_set_hl(0, "TodoIdIcon", {
		fg = "#bb9af7",
	})
end

---------------------------------------------------------------------
-- 静态高亮初始化
---------------------------------------------------------------------
function M.setup_static_highlights()
	for name, hl in pairs(M.static_highlights) do
		if hl and vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, hl)
		end
	end
end

---------------------------------------------------------------------
-- 初始化所有高亮
---------------------------------------------------------------------
function M.setup(user_config)
	local tags = user_config and user_config.tags or config.get("tags")

	M.setup_static_highlights()
	M.setup_tag_highlights(tags)
	M.setup_dynamic_status_highlights()
	M.setup_status_highlights()
	M.setup_conceal_highlights()
end

---------------------------------------------------------------------
-- 清理
---------------------------------------------------------------------
function M.clear()
	for name in pairs(M.static_highlights) do
		pcall(vim.api.nvim_set_hl, 0, name, {})
	end

	local dynamic = {
		"Todo2StatusDone",
		"Todo2StatusTodo",
		"Todo2ProgressDone",
		"Todo2ProgressTodo",
		"TodoCheckboxTodo",
		"TodoCheckboxDone",
		"TodoCheckboxArchived",
		"TodoIdIcon",
		"TodoStrikethrough",
		"TodoCompleted",
	}

	for _, name in ipairs(dynamic) do
		pcall(vim.api.nvim_set_hl, 0, name, {})
	end
end

return M
