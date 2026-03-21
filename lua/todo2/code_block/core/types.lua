local M = {}

---@class CodeBlock
---@field source string        -- "treesitter" | "lsp" | "indent" | ...
---@field lang string|nil
---@field type string          -- "function" | "class" | "struct" | ...
---@field name string|nil
---@field start_line integer
---@field end_line integer
---@field start_col integer|nil
---@field end_col integer|nil
---@field text string|nil
---@field detail string|nil
---@field raw_type string|nil
---@field raw_kind integer|nil
---@field node userdata|nil

---@class CodeBlockProvider
---@field name string
---@field priority integer
---@field supports fun(bufnr:integer):boolean
---@field get_block fun(bufnr:integer, lnum:integer):CodeBlock|nil
---@field get_all fun(bufnr:integer):CodeBlock[]|nil

function M.get_filetype(bufnr)
	return vim.bo[bufnr].filetype or ""
end

function M.log(debug_enabled, msg, level)
	if not debug_enabled then
		return
	end
	vim.notify("[code_block] " .. msg, level or vim.log.levels.INFO)
end

return M
