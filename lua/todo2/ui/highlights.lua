-- lua/todo2/ui/highlights.lua
--- @module todo2.ui.highlights
--- @brief UI 高亮定义模块

local M = {}

---------------------------------------------------------------------
-- 默认高亮定义（任务文本颜色和效果）
---------------------------------------------------------------------
M.default_highlights = {
	{
		name = "TodoCompleted",
		definition = "guifg=#888888 gui=italic,strikethrough", -- 灰色、斜体、删除线
		description = "已完成的任务（灰色斜体带删除线）",
	},
	{
		name = "TodoPending",
		definition = "guifg=#c0c0c0", -- 浅灰色，未完成任务
		description = "未完成的任务",
	},
}

---------------------------------------------------------------------
-- 图标高亮组定义（复选框和ID图标）
---------------------------------------------------------------------
M.icon_highlights = {
	-- 复选框高亮
	{
		name = "TodoCheckboxTodo",
		definition = "guifg=#888888", -- 灰色
		description = "未完成复选框图标颜色",
	},
	{
		name = "TodoCheckboxDone",
		definition = "guifg=#51cf66", -- 绿色
		description = "已完成复选框图标颜色",
	},
	-- ID图标高亮
	{
		name = "TodoIdIcon",
		definition = "guifg=#bb9af7", -- 紫色
		description = "任务ID图标颜色",
	},
}

---------------------------------------------------------------------
-- 初始化高亮组
---------------------------------------------------------------------
function M.setup()
	-- 设置默认高亮
	for _, hl in ipairs(M.default_highlights) do
		M.define_highlight(hl.name, hl.definition)
	end

	-- 设置图标高亮
	for _, hl in ipairs(M.icon_highlights) do
		M.define_highlight(hl.name, hl.definition)
	end
end

---------------------------------------------------------------------
-- 定义单个高亮组
---------------------------------------------------------------------
function M.define_highlight(name, definition)
	local cmd = string.format("highlight %s %s", name, definition)
	vim.cmd(cmd)
end

---------------------------------------------------------------------
-- 重新加载高亮组
---------------------------------------------------------------------
function M.reload()
	M.clear()
	M.setup()
end

---------------------------------------------------------------------
-- 清理高亮组
---------------------------------------------------------------------
function M.clear()
	for _, hl in ipairs(M.default_highlights) do
		vim.cmd(string.format("highlight clear %s", hl.name))
	end
	for _, hl in ipairs(M.icon_highlights) do
		vim.cmd(string.format("highlight clear %s", hl.name))
	end
end

return M
