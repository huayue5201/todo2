-- lua/todo2/link/highlight.lua
--- @module todo2.link.highlight
--- @brief 高亮系统模块，包含颜色生成和高亮组管理

local M = {}

---------------------------------------------------------------------
-- 配置管理
---------------------------------------------------------------------
local config = require("todo2.config")

---------------------------------------------------------------------
-- HSL 颜色转换函数
---------------------------------------------------------------------

--- 将 HSL 颜色转换为十六进制颜色代码
--- @param h number 色相 (0-360)
--- @param s number 饱和度 (0-1)
--- @param l number 亮度 (0-1)
--- @return string 十六进制颜色代码
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

--- 根据标签名称生成稳定的颜色
--- @param tag string 标签名称
--- @return string 十六进制颜色代码
function M.generate_color_for_tag(tag)
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

	return M.hsl_to_hex(h, s, l)
end

---------------------------------------------------------------------
-- 主题颜色生成
---------------------------------------------------------------------

--- 根据主题和类型生成颜色
--- @param kind string 颜色类型："done" | "todo"
--- @return string 十六进制颜色代码
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

--- 设置标签高亮组
--- @param tags table 标签配置表（可选，如果不提供则从配置读取）
function M.setup_tag_highlights(tags)
	-- ⭐ 修改：优先使用传入的tags，否则从配置读取
	tags = tags or config.get("tags") or {}

	for tag, style in pairs(tags) do
		-- 自动生成 hl 名字
		if not style.hl then
			style.hl = "Todo2Tag_" .. tag
		end

		-- 自动生成颜色（如果配置中没有指定颜色）
		local color = style.color or M.generate_color_for_tag(tag)

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
-- 动态状态高亮组管理
---------------------------------------------------------------------

--- 设置动态状态高亮组（状态图标 / 进度条）
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
-- 状态颜色高亮组管理（新增）
---------------------------------------------------------------------

--- 设置状态颜色高亮组
function M.setup_status_highlights()
	-- ⭐ 从配置获取状态颜色
	local status_colors = config.get("status_colors")
		or {
			normal = "#51cf66",
			urgent = "#ff6b6b",
			waiting = "#ffd43b",
			completed = "#868e96",
		}

	-- 为每个状态创建高亮组
	for status, color in pairs(status_colors) do
		local hl_name = "TodoStatus" .. status:sub(1, 1):upper() .. status:sub(2)

		if vim.fn.hlexists(hl_name) == 0 then
			vim.api.nvim_set_hl(0, hl_name, {
				fg = color,
				-- 可以根据需要添加其他属性
			})
		end
	end
end

---------------------------------------------------------------------
-- 渲染器高亮管理
---------------------------------------------------------------------

--- 为渲染器设置行级高亮
--- @param bufnr number 缓冲区句柄
--- @param row number 行号
--- @param state table 渲染状态
--- @param cfg table 配置
function M.setup_render_line_highlights(bufnr, row, state, cfg)
	-- 这里可以放置渲染行时的高亮设置逻辑
	-- 当前大部分高亮设置在 renderer.lua 中完成
end

---------------------------------------------------------------------
-- 导出模块
---------------------------------------------------------------------
return M
