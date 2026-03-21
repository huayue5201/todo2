-- lua/todo2/code_block/queries/python.lua
-- Python 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	function_definition = "function",
	async_function_definition = "function",
	class_definition = "class",
}

M.fields = {
	name = "name",
	parameters = "parameters",
	return_type = "return_type",
}

M.format_signature = function(name, params, return_type, _, is_async)
	local prefix = is_async and "async def" or "def"
	local sig = string.format("%s %s%s", prefix, name, params)
	if return_type and return_type ~= "" then
		sig = sig .. " -> " .. return_type
	end
	return sig
end

return M
