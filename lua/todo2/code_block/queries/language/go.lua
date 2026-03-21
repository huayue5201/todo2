-- lua/todo2/code_block/queries/go.lua
-- Go 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	-- 函数相关
	function_declaration = "function",
	method_declaration = "method",
	func_literal = "function",
	-- 类型定义
	type_declaration = "type",
	struct_type = "struct",
	interface_type = "interface",
}

M.fields = {
	name = "name",
	parameters = "parameters",
	result = "result",
	receiver = "receiver",
}

M.format_signature = function(name, params, result, receiver)
	if receiver then
		return string.format("func %s %s%s %s", receiver, name, params, result)
	end
	return string.format("func %s%s %s", name, params, result)
end

return M
