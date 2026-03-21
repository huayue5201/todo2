local M = {
	name = "lsp",
	priority = 50,
}

function M.supports(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	return clients and #clients > 0
end

local kind_map = {
	[5] = "class",
	[6] = "method",
	[10] = "enum",
	[11] = "interface",
	[12] = "function",
	[23] = "struct",
}

---@param lnum integer
---@param symbols any[]
---@return any|nil
local function find_symbol_at_line(lnum, symbols)
	local l0 = lnum - 1
	local function rec(list)
		for _, sym in ipairs(list) do
			local range = sym.range or (sym.location and sym.location.range)
			if range and l0 >= range.start.line and l0 <= range["end"].line then
				if sym.children then
					local child = rec(sym.children)
					if child then
						return child
					end
				end
				return sym
			end
		end
		return nil
	end
	return rec(symbols)
end

---@param bufnr integer
---@param lnum integer
---@param symbols any[]
---@return CodeBlock|nil
local function build_block_from_symbol(bufnr, lnum, symbols)
	local sym = find_symbol_at_line(bufnr, lnum, symbols)
	if not sym then
		return nil
	end
	local range = sym.range or (sym.location and sym.location.range)
	if not range then
		return nil
	end
	local kind = kind_map[sym.kind]
	if not kind then
		return nil
	end

	return {
		source = "lsp",
		type = kind,
		raw_kind = sym.kind,
		name = sym.name,
		start_line = range.start.line + 1,
		start_col = range.start.character,
		end_line = range["end"].line + 1,
		end_col = range["end"].character,
		detail = sym.detail,
		container_name = sym.containerName,
		deprecated = sym.deprecated,
	}
end

---@param bufnr integer
---@return any[]|nil
local function request_symbols(bufnr)
	local params = vim.lsp.util.make_text_document_params(bufnr)
	local result = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 500)
	if not result then
		return nil
	end
	for _, resp in pairs(result) do
		if resp.result then
			return resp.result
		end
	end
	return nil
end

function M.get_block(bufnr, lnum, symbols)
	symbols = symbols or request_symbols(bufnr)
	if not symbols then
		return nil
	end
	return build_block_from_symbol(bufnr, lnum, symbols)
end

function M.get_all(bufnr, symbols)
	symbols = symbols or request_symbols(bufnr)
	if not symbols then
		return nil
	end

	local blocks = {}

	local function rec(list)
		for _, sym in ipairs(list) do
			local kind = kind_map[sym.kind]
			if kind then
				local range = sym.range or (sym.location and sym.location.range)
				if range then
					blocks[#blocks + 1] = {
						source = "lsp",
						type = kind,
						name = sym.name,
						start_line = range.start.line + 1,
						end_line = range["end"].line + 1,
						detail = sym.detail,
					}
				end
			end
			if sym.children then
				rec(sym.children)
			end
		end
	end

	rec(symbols)
	return blocks
end

return M
