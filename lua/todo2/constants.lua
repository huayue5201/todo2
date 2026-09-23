-- lua/todo2/constants.lua
-- 全局常量：统一管理分散在各处的 namespace 等常量

local M = {}

--- 高亮/标记 namespace 名称（集中定义，避免各处硬编码不一致）
M.NAMESPACES = {
	input_footer = "todo2_input_footer",
	heatmap = "todo2_heatmap",
	todo_render = "todo2_render",
	code_render = "code_render",
	conceal = "todo2_conceal",
	strike = "todo2_strike",
	preview_highlight = "todo_preview_highlight",
}

--- 获取（惰性创建）指定 namespace 的 id
---@param name string 见 M.NAMESPACES 的键
---@return integer
function M.ns(name)
	local ns_name = M.NAMESPACES[name]
	assert(ns_name, "unknown namespace: " .. tostring(name))
	return vim.api.nvim_create_namespace(ns_name)
end

return M
