-- lua/todo2/code_block/queries/javascript.lua
-- JavaScript 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	function_declaration = "function",
	method_definition = "method",
	arrow_function = "function",
	class_declaration = "class",
}

M.fields = {
	name = "name",
	parameters = "parameters",
}

M.format_signature = function(name, params)
	return string.format("function %s%s", name, params)
end

return M
