-- lua/todo2/code_block/core/types.lua
local M = {}

---@class CodeBlock
---@field source string        -- "treesitter" | "lsp" | "indent" | ...
---@field lang string|nil
---@field bufnr integer|nil
---@field type string          -- "function" | "class" | "struct" | ...
---@field name string|nil
---@field start_line integer
---@field end_line integer
---@field is_method boolean|nil
---@field receiver string|nil
---@field signature string|nil
---@field first_line string|nil
---@field relative_line integer|nil -- 块内相对行号

---@class TaskCodeContext
---@field source string
---@field type string
---@field name string|nil
---@field signature string|nil
---@field relative_line integer|nil

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

--- 将完整 CodeBlock 收敛为最小持久化上下文
---
--- 只保留真正被消费的字段（source/type 供 UI 展示，name/signature/relative_line 供行号重定位），
--- 剔除 text 等体积大且无消费者的冗余字段。
---@param block CodeBlock
---@return TaskCodeContext|nil
function M.to_context(block)
	if not block then
		return nil
	end
	return {
		source = block.source,
		type = block.type,
		name = block.name,
		signature = block.signature,
		relative_line = block.relative_line,
	}
end

return M
