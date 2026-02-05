-- lua/todo2/ui/highlights.lua
--- @module todo2.ui.highlights
--- @brief UI 高亮定义模块

local M = {}

---------------------------------------------------------------------
-- 默认高亮定义（保留原有的）
---------------------------------------------------------------------
M.default_highlights = {
	{
		name = "TodoCompleted",
		definition = "guifg=#888888 gui=italic",
		description = "已完成的任务（灰色斜体）",
	},
	{
		name = "TodoStrikethrough",
		definition = "gui=strikethrough cterm=strikethrough",
		description = "删除线效果，用于已完成任务",
	},
}

---------------------------------------------------------------------
-- 图标高亮组定义（只为3个图标）
---------------------------------------------------------------------
M.icon_highlights = {
	-- 优先级图标
	{
		name = "TodoPriorityHigh",
		definition = "guifg=#ff6b6b", -- 红色
		description = "高优先级图标颜色",
	},
	{
		name = "TodoPriorityMedium",
		definition = "guifg=#feca57", -- 黄色
		description = "中优先级图标颜色",
	},
	{
		name = "TodoPriorityLow",
		definition = "guifg=#48dbfb", -- 蓝色
		description = "低优先级图标颜色",
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
-- 根据优先级值获取高亮组
---------------------------------------------------------------------
--- @param priority number 优先级值 (1=高, 2=中, 3=低)
--- @return string|nil 高亮组名称
function M.get_priority_highlight(priority)
	if priority == 1 then
		return "TodoPriorityHigh"
	elseif priority == 2 then
		return "TodoPriorityMedium"
	elseif priority == 3 then
		return "TodoPriorityLow"
	end
	return nil
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
