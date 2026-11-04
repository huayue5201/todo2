-- lua/todo2/utils/tree.lua
-- 树形缩进前缀构建（drawer / viewer 共用，字形来自 icons.tree 配置）

local M = {}

local config = require("todo2.config")

--- 构建树形缩进前缀
--- @param depth integer 缩进深度
--- @param stack boolean[] 每层是否为最后一个节点的标记栈
--- @return string
function M.build_indent(depth, stack)
	local indent = config.get("icons.tree") or {}
	local parts = {}

	for i = 1, depth do
		if i == depth then
			parts[i] = stack[i] and indent.last or indent.middle
		else
			parts[i] = stack[i] and indent.ws or indent.top
		end
	end

	return table.concat(parts)
end

return M
