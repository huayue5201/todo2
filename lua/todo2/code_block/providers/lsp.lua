local M = {
	name = "lsp",
	priority = 50,
}

--- 将 LSP SymbolKind 映射为插件内部的块类型。
--- 只保留“块级”符号（类/函数/命名空间等）；叶子符号（变量/字段/属性等）
--- 不在此映射中，find_symbol_at_line 会自动回退到最近的块级祖先。
local kind_map = {
	[2] = "module",
	[3] = "namespace",
	[4] = "package",
	[5] = "class",
	[6] = "method",
	[9] = "constructor",
	[10] = "enum",
	[11] = "interface",
	[12] = "function",
	[23] = "struct",
}

---@param client table
---@return boolean
local function supports_document_symbols(client)
	if client.supports_method then
		return client.supports_method("textDocument/documentSymbol")
	end
	local caps = client.server_capabilities or {}
	return caps.documentSymbolProvider ~= nil
end

function M.supports(bufnr)
	if not vim.lsp or not vim.lsp.get_clients then
		return false
	end
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if not clients then
		return false
	end
	for _, client in ipairs(clients) do
		if supports_document_symbols(client) then
			return true
		end
	end
	return false
end

---@param sym any
---@return any|nil
local function symbol_range(sym)
	return sym.range or (sym.location and sym.location.range)
end

--- 在给定行上查找“最深且 kind 已映射”的符号；
--- 若最深符号是叶子（未映射），回退到最近的块级祖先。
---@param lnum integer 1 索引行号
---@param symbols any[]
---@return any|nil
local function find_symbol_at_line(lnum, symbols)
	local l0 = lnum - 1
	local best = nil

	local function rec(list)
		for _, sym in ipairs(list) do
			local range = symbol_range(sym)
			if range and l0 >= range.start.line and l0 <= range["end"].line then
				if kind_map[sym.kind] then
					best = sym
				end
				if sym.children then
					rec(sym.children)
				end
			end
		end
	end

	rec(symbols)
	return best
end

---@param lnum integer
---@param symbols any[]
---@return CodeBlock|nil
local function build_block_from_symbol(lnum, symbols)
	local sym = find_symbol_at_line(lnum, symbols)
	if not sym then
		return nil
	end
	local range = symbol_range(sym)
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
		name = sym.name,
		start_line = range.start.line + 1,
		end_line = range["end"].line + 1,
	}
end

--- 异步获取 documentSymbol 符号表，通过回调返回。
--- 结果由 engine 负责缓存，get_block/get_all 依赖传入的 symbols 工作。
---@param bufnr integer
---@param callback fun(symbols:any[]|nil) symbols 为空表表示服务器成功响应但没有符号；nil 表示请求失败/超时
function M.get_symbols(bufnr, callback)
	callback = callback or function() end

	if not M.supports(bufnr) then
		callback(nil)
		return
	end

	local params = vim.lsp.util.make_text_document_params(bufnr)
	local done = false

	local function resolve(symbols)
		if done then
			return
		end
		done = true
		callback(symbols)
	end

	-- 超时兜底，避免 server 无响应时回调永不触发。
	-- 注意：vim.defer_fn 返回的是 uv timer，没有 :cancel() 方法；
	-- 超时后 timer 会自行 stop/close，这里仅靠 done 标志保证回调只触发一次。
	vim.defer_fn(function()
		resolve(nil)
	end, 500)

	vim.lsp.buf_request_all(bufnr, "textDocument/documentSymbol", params, function(results)
		local had_response = false
		for _, resp in pairs(results or {}) do
			if resp and resp.result then
				had_response = true
				if #resp.result > 0 then
					resolve(resp.result)
					return
				end
			end
		end
		if had_response then
			resolve({})
		else
			resolve(nil)
		end
	end)
end

--- 从已获取的 symbols 中定位指定行的代码块。
--- symbols 必须由调用方（engine）通过 get_symbols + 缓存提供。
---@param bufnr integer
---@param lnum integer
---@param symbols any[]
---@return CodeBlock|nil
function M.get_block(bufnr, lnum, symbols)
	if not symbols then
		return nil
	end
	return build_block_from_symbol(lnum, symbols)
end

--- 从已获取的 symbols 中收集所有代码块。
--- symbols 必须由调用方（engine）通过 get_symbols + 缓存提供。
---@param bufnr integer
---@param symbols any[]
---@return CodeBlock[]|nil
function M.get_all(bufnr, symbols)
	if not symbols then
		return nil
	end

	local blocks = {}

	local function rec(list)
		for _, sym in ipairs(list) do
			local kind = kind_map[sym.kind]
			if kind then
				local range = symbol_range(sym)
				if range then
					blocks[#blocks + 1] = {
						source = "lsp",
						type = kind,
						name = sym.name,
						start_line = range.start.line + 1,
						end_line = range["end"].line + 1,
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
