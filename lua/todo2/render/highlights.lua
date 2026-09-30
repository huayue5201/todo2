-- lua/todo2/render/highlights.lua
-- 精简版：只保留当前 todo2 架构需要的高亮组

local M = {}

local config = require("todo2.config")
local core_status = require("todo2.core.status")

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

	-- 时间戳统一高亮
	TodoTime = { fg = "#8a8a8a" },
}

---------------------------------------------------------------------
-- 动态进度条高亮
---------------------------------------------------------------------
function M.setup_dynamic_progress_highlights()
	vim.api.nvim_set_hl(0, "Todo2ProgressDone", {
		fg = M.generate_theme_color("done"),
	})

	vim.api.nvim_set_hl(0, "Todo2ProgressTodo", {
		fg = M.generate_theme_color("todo"),
	})
end

---------------------------------------------------------------------
-- 状态颜色（循环状态由用户配置，终态固定灰色）
---------------------------------------------------------------------
function M.setup_status_highlights()
	local cycle = config.get("status.cycle") or {}
	for _, def in ipairs(cycle) do
		local hl_name = core_status.get_hl_group(def.label)
		if vim.fn.hlexists(hl_name) == 0 then
			vim.api.nvim_set_hl(0, hl_name, { fg = def.color })
		end
	end

	-- 固定终态图标高亮（灰色，无删除线；删除线由内容层单独处理）
	local terminal = {
		TodoStatusCompleted = "#868e96",
		TodoStatusArchived = "#868e96",
	}
	for name, color in pairs(terminal) do
		if vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, { fg = color })
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
function M.setup()
	M.setup_static_highlights()
	M.setup_dynamic_progress_highlights()
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
