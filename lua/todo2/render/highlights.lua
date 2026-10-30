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

	-- 完成任务正文随动变暗（无删除线）
	TodoDescCompleted = { fg = "#868e96" },

	-- 有正文的标识图标
	TodoDescIcon = { fg = "#565f89" },

	-- checkbox（动态设置颜色）
	TodoCheckboxTodo = nil,
	TodoCheckboxDone = nil,
	TodoCheckboxArchived = { fg = "#868e96" },

	-- 时间戳统一高亮
	TodoTime = { fg = "#8a8a8a" },

	-- 代码端虚拟行箭头（上方 󱞡 / 下方 󱞽）
	TodoCodeRenderArrow = { fg = "#565f89" },

	-- 同一代码行多任务被折叠时的「+N」提示
	TodoCodeRenderMore = { fg = "#565f89", italic = true },

	-- 同一代码行内后代任务的层级前缀（└）
	TodoCodeRenderTree = { fg = "#565f89" },

	-- 任务标签（真实文本，多值）
	TodoTag = { fg = "#7dcfff", italic = true },

	-- 到期日（纯日期字段）：常规灰蓝 / 临近橙色 / 过期红色
	TodoDue = { fg = "#7aa2f7" },
	TodoDueSoon = { fg = "#e0af68" },
	TodoDueOverdue = { fg = "#f7768e", bold = true },

	-- 代码锚点失联提示
	TodoAnchorLost = { fg = "#e0af68" },

	-- 代码锚点精确列：只做 token 区间标记，不占宽度；
	-- 下划线颜色由 setup_status_highlights 生成 TodoCodeAnchorSpan<Status> 覆盖。
	TodoCodeAnchorSpan = { undercurl = true, sp = "#ffaa00", bold = true },
}

---------------------------------------------------------------------
-- 动态进度条高亮
---------------------------------------------------------------------
function M.setup_dynamic_progress_highlights()
	-- 主题（如 night-owl.nvim）已经定义过就沿用主题色，否则用自算的回退色
	if vim.fn.hlexists("Todo2ProgressDone") == 0 then
		vim.api.nvim_set_hl(0, "Todo2ProgressDone", {
			fg = M.generate_theme_color("done"),
		})
	end

	if vim.fn.hlexists("Todo2ProgressTodo") == 0 then
		vim.api.nvim_set_hl(0, "Todo2ProgressTodo", {
			fg = M.generate_theme_color("todo"),
		})
	end
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
		-- 代码锚点下划线跟随任务内容色，而不是固定琥珀色
		local anchor_hl = "TodoCodeAnchorSpan" .. def.label:gsub("^%l", string.upper)
		if vim.fn.hlexists(anchor_hl) == 0 then
			vim.api.nvim_set_hl(0, anchor_hl, { undercurl = true, sp = def.color, bold = true })
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
		local anchor_hl = name:gsub("^TodoStatus", "TodoCodeAnchorSpan")
		if vim.fn.hlexists(anchor_hl) == 0 then
			vim.api.nvim_set_hl(0, anchor_hl, { undercurl = true, sp = color, bold = true })
		end
	end
end

---------------------------------------------------------------------
-- checkbox 高亮
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

return M
