-- lua/todo2/ui/highlights.lua
--- @module todo2.ui.highlights
--- @brief UI 高亮定义模块

local M = {}

---------------------------------------------------------------------
-- 默认高亮定义
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
-- 初始化高亮组
---------------------------------------------------------------------
function M.setup()
	for _, hl in ipairs(M.default_highlights) do
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
-- 添加自定义高亮组
---------------------------------------------------------------------
function M.add_highlight(name, definition)
	table.insert(M.default_highlights, {
		name = name,
		definition = definition,
	})
	M.define_highlight(name, definition)
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
end

---------------------------------------------------------------------
-- 获取所有高亮组定义
---------------------------------------------------------------------
function M.get_definitions()
	return M.default_highlights
end

return M
