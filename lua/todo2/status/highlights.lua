-- lua/todo2/status/highlights.lua
--- @module todo2.status.highlights
--- @brief 状态高亮组定义

local M = {}

---------------------------------------------------------------------
-- 设置状态高亮组
---------------------------------------------------------------------
function M.setup()
	-- 正常状态（红色）
	vim.api.nvim_set_hl(0, "TodoStatusNormal", {
		fg = "#51cf66",
		bold = true,
	})

	-- 紧急状态（绿色）
	vim.api.nvim_set_hl(0, "TodoStatusUrgent", {
		fg = "#ff6b6b",
		bold = true,
	})

	-- 等待状态（黄色）
	vim.api.nvim_set_hl(0, "TodoStatusWaiting", {
		fg = "#ffd43b",
		bold = true,
	})

	-- 完成状态（灰色）
	vim.api.nvim_set_hl(0, "TodoStatusCompleted", {
		fg = "#868e96",
		bold = true,
	})
end

---------------------------------------------------------------------
-- 获取状态高亮组名
---------------------------------------------------------------------
function M.get_highlight(status)
	if status == "normal" then
		return "TodoStatusNormal"
	elseif status == "urgent" then
		return "TodoStatusUrgent"
	elseif status == "waiting" then
		return "TodoStatusWaiting"
	elseif status == "completed" then
		return "TodoStatusCompleted"
	else
		return "TodoStatusNormal"
	end
end

return M
