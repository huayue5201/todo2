-- lua/todo2/code_block/queries/c.lua
-- C 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	function_definition = "function",
	struct_specifier = "struct",
	enum_specifier = "enum",
}

M.fields = {
	name = "name",
	parameters = "parameters",
}

M.format_signature = function(name, params, return_type)
	return string.format("%s %s%s", return_type or "void", name, params)
end

return M
