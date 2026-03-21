-- lua/todo2/code_block/queries/rust.lua
-- Rust 语言 Treesitter 查询配置

local M = {}

M.blocks = {
	function_item = "function",
	struct_item = "struct",
	enum_item = "enum",
	trait_item = "interface",
	impl_item = "impl",
}

M.fields = {
	name = "name",
	parameters = "parameters",
	return_type = "return_type",
}

M.format_signature = function(name, params, return_type)
	local sig = string.format("fn %s%s", name, params)
	if return_type and return_type ~= "" then
		sig = sig .. " -> " .. return_type
	end
	return sig
end

return M
