-- lua/todo2/code_block/queries/typescript.lua
-- TypeScript 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	-- 函数相关
	function_declaration = "function",
	method_definition = "method",
	arrow_function = "function",
	-- 类型定义
	class_declaration = "class",
	interface_declaration = "interface",
	enum_declaration = "enum",
	type_alias_declaration = "type",
}

M.fields = {
	name = "name",
	parameters = "parameters",
	return_type = "type",
}

M.format_signature = function(name, params, return_type)
	local sig = string.format("function %s%s", name, params)
	if return_type and return_type ~= "" then
		sig = sig .. ": " .. return_type
	end
	return sig
end

return M
