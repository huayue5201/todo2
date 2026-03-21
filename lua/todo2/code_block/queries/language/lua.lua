-- lua/todo2/code_block/queries/lua.lua
-- Lua 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	function_declaration = "function",
	function_definition = "function",
	local_function = "function",
	table_constructor = "class",
}

M.fields = {
	name = "name",
	parameters = "parameters",
}

M.format_signature = function(name, params)
	return string.format("function %s%s", name, params)
end

return M
