-- lua/todo2/render/checkbox.lua
-- 复选框图标 + 高亮（conceal / code_render / drawer / fold / picker 共用）
-- 图标与颜色都来自状态定义本身（status.cycle / 固定终态），这里只做一次查表，
-- 不再维护第二份图标配置。

local M = {}

local status_domain = require("todo2.core.status")

--- 按任务状态返回复选框图标 + 高亮组
---@param status string|nil 任务状态
---@return string icon, string hl_group
function M.get(status)
	local def = status_domain.get_definition(status or status_domain.get_default())
	if not def then
		return "◻", "Normal"
	end
	return vim.trim(def.icon or "") ~= "" and vim.trim(def.icon) or "◻", status_domain.get_hl_group(def.label) or "Normal"
end

return M
