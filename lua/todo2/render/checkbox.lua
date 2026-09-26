-- lua/todo2/render/checkbox.lua
-- 复选框图标 + 高亮（conceal / code_render / drawer 共用）
-- 只依赖 config + types（轻量，无循环依赖）

local M = {}

local types = require("todo2.store.types")
local config = require("todo2.config")

--- 按任务状态返回复选框图标 + 高亮组
--- @param status string 任务状态
--- @return string icon, string hl_group
function M.get(status)
	local icons = config.get("checkbox_icons")
	if status == types.STATUS.COMPLETED then
		return icons.done, "TodoCheckboxDone"
	elseif status == types.STATUS.ARCHIVED then
		return icons.archived, "TodoCheckboxArchived"
	else
		return icons.todo, "TodoCheckboxTodo"
	end
end

return M
