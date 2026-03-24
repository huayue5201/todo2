-- lua/todo2/code_block/core/types.lua
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
---@field is_method boolean|nil
---@field receiver string|nil
---@field signature string|nil
---@field signature_hash string|nil
---@field inner_node table|nil   -- 当前行精确节点信息
---@field statement table|nil    -- 最近语句节点
---@field ancestors table[]|nil  -- 祖先链
---@field relative_line integer|nil -- 块内相对行号

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
