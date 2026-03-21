-- lua/todo2/ai/context.lua
-- 任务驱动语义上下文收集器（只做“所见即所得”的上下文恢复，不改 link）

local M = {}

------------------------------------------------------------
-- 工具：安全读取文件行
------------------------------------------------------------
local function read_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines then
		return {}
	end
	return lines
end

------------------------------------------------------------
-- LSP：尝试通过 LSP 拿语义范围（函数 / 方法 / 类等）
------------------------------------------------------------
local function lsp_get_range(path, line)
	local bufnr = vim.fn.bufnr(path, false)
	if bufnr == -1 then
		return nil
	end

	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if not clients or #clients == 0 then
		return nil
	end

	-- 先尝试 documentSymbol
	local params = vim.lsp.util.make_text_document_params(bufnr)
	local ok, result = pcall(vim.lsp.buf_request_sync, bufnr, "textDocument/documentSymbol", {
		textDocument = params,
	}, 500)
	if not ok or not result then
		return nil
	end

	local function in_range(r, lnum0)
		return lnum0 >= r.start.line and lnum0 <= r["end"].line
	end

	local lnum0 = line - 1
	local best = nil

	local function handle_symbol(sym)
		if sym.range and in_range(sym.range, lnum0) then
			-- 选最内层的
			if
				not best
				or (sym.range.start.line >= best.range.start.line and sym.range["end"].line <= best.range["end"].line)
			then
				best = sym
			end
		end
		if sym.children then
			for _, child in ipairs(sym.children) do
				handle_symbol(child)
			end
		end
	end

	for _, resp in pairs(result) do
		local symbols = resp.result
		if vim.tbl_islist(symbols) then
			for _, sym in ipairs(symbols) do
				handle_symbol(sym)
			end
		end
	end

	if not best or not best.range then
		return nil
	end

	local s = best.range.start.line + 1
	local e = best.range["end"].line + 1
	local lines = read_lines(path)
	if #lines == 0 then
		return nil
	end

	s = math.max(1, math.min(s, #lines))
	e = math.max(s, math.min(e, #lines))

	return {
		start_line = s,
		end_line = e,
		code = table.concat(vim.list_slice(lines, s, e), "\n"),
		source = "lsp_document_symbol",
	}
end

------------------------------------------------------------
-- 工具：从 store.context.lines 中识别函数签名
------------------------------------------------------------
local function find_function_in_window(ctx)
	if not ctx or not ctx.lines then
		return nil
	end

	for _, line in ipairs(ctx.lines) do
		local text = line.content or ""
		if text:match("^%s*func%s+[%w_%.]+%s*%(") then
			return {
				signature = text,
				offset = line.offset, -- 相对 target_line 的偏移
			}
		end
	end

	return nil
end

------------------------------------------------------------
-- 工具：根据 store.context.range_info + 指纹窗口恢复代码块
-- 注意：这里不改任务行号，只用 snapshot 的真实行号
------------------------------------------------------------
local function compute_range_from_window(ctx, func_offset)
	local info = ctx.metadata and ctx.metadata.range_info
	if not info then
		return nil
	end

	-- target_line 是任务行号（1-based）
	local target_line = info.target_line
	local func_line = target_line + func_offset

	local lines = read_lines(ctx.target_file)
	if #lines == 0 then
		return nil
	end

	if func_line < 1 or func_line > #lines then
		return nil
	end

	-- 从函数签名开始向下扫描，直到匹配到 "}" 或文件结束
	local start_line = func_line
	local end_line = func_line

	local depth = 0
	for i = func_line, #lines do
		local l = lines[i]
		if l:find("{") then
			depth = depth + 1
		end
		if l:find("}") then
			depth = depth - 1
		end
		end_line = i
		if depth == 0 and i > func_line then
			break
		end
	end

	return {
		start_line = start_line,
		end_line = end_line,
		code = table.concat(vim.list_slice(lines, start_line, end_line), "\n"),
		source = "store_context",
	}
end

------------------------------------------------------------
-- Treesitter：动态解析器
------------------------------------------------------------
local function get_parser(path)
	local bufnr = vim.fn.bufnr(path, true)
	if bufnr == -1 then
		return nil, nil
	end

	local ft = vim.bo[bufnr].filetype
	if not ft or ft == "" then
		return nil, nil
	end

	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, ft)
	if not ok or not parser then
		return nil, nil
	end

	return parser, bufnr
end

------------------------------------------------------------
-- Treesitter：查找包含标记行的函数
------------------------------------------------------------
local func_nodes_by_ft = {
	go = { "function_declaration", "method_declaration" },
	lua = { "function_declaration", "function_definition" },
	python = { "function_definition" },
	javascript = { "function_declaration", "method_definition", "arrow_function" },
	typescript = { "function_declaration", "method_definition", "arrow_function" },
	rust = { "function_item" },
	c = { "function_definition" },
	cpp = { "function_definition" },
	java = { "method_declaration" },
}

local function get_func_node_types(ft)
	return func_nodes_by_ft[ft] or { "function", "function_declaration" }
end

local function find_local_function(parser, bufnr, line)
	local ok_tree, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_tree or not trees or not trees[1] then
		return nil
	end

	local root = trees[1]:root()
	if not root then
		return nil
	end

	local ft = vim.bo[bufnr].filetype
	local targets = get_func_node_types(ft)

	local node = root:named_descendant_for_range(line - 1, 0, line - 1, 0)
	while node do
		local t = node:type()
		for _, target in ipairs(targets) do
			if t == target then
				return node
			end
		end
		node = node:parent()
	end

	return nil
end

local function extract_node_code(bufnr, node)
	if not node then
		return nil
	end

	local s_row, _, e_row, _ = node:range()
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, s_row, e_row + 1, false)
	if not ok or not lines then
		return nil
	end

	return {
		start_line = s_row + 1,
		end_line = e_row + 1,
		code = table.concat(lines, "\n"),
		source = "treesitter_local",
	}
end

------------------------------------------------------------
-- fallback：标记上下 50 行
------------------------------------------------------------
local function fallback(path, line)
	local lines = read_lines(path)
	if #lines == 0 then
		return {
			start_line = 1,
			end_line = 1,
			code = "",
			source = "empty_file",
		}
	end

	local s = math.max(1, line - 50)
	local e = math.min(#lines, line + 50)

	return {
		start_line = s,
		end_line = e,
		code = table.concat(vim.list_slice(lines, s, e), "\n"),
		source = "fallback",
	}
end

------------------------------------------------------------
-- 主入口：语义上下文收集（不修改 link，只返回代码块）
------------------------------------------------------------
-- TODO:ref:dd7825
function M.collect(link, todo)
	if not link or not link.path or not link.line then
		return nil
	end

	local path = link.path
	local line = link.line
	local ctx = link.context

	------------------------------------------------------------
	-- 0. LSP 优先：如果有语义范围，直接用
	------------------------------------------------------------
	local lsp_ctx = lsp_get_range(path, line)
	if lsp_ctx then
		return lsp_ctx
	end

	------------------------------------------------------------
	-- 1. 优先使用 store.context（指纹系统采集的窗口）
	------------------------------------------------------------
	if ctx then
		local func = find_function_in_window(ctx)
		if func then
			local range = compute_range_from_window(ctx, func.offset)
			if range then
				return range
			end
		end

		-- 即使没有函数签名，也可以直接用 range_info 作为上下文窗口
		local info = ctx.metadata and ctx.metadata.range_info
		if info then
			local lines = read_lines(ctx.target_file)
			if #lines > 0 then
				local s = math.max(1, math.min(info.start_line, #lines))
				local e = math.max(s, math.min(info.end_line, #lines))
				return {
					start_line = s,
					end_line = e,
					code = table.concat(vim.list_slice(lines, s, e), "\n"),
					source = "store_context_window",
				}
			end
		end
	end

	------------------------------------------------------------
	-- 2. Treesitter 局部查找
	------------------------------------------------------------
	local parser, bufnr = get_parser(path)
	if parser and bufnr then
		local node = find_local_function(parser, bufnr, line)
		local ts_ctx = extract_node_code(bufnr, node)
		if ts_ctx then
			return ts_ctx
		end
	end

	------------------------------------------------------------
	-- 3. fallback（标记上下 50 行）
	------------------------------------------------------------
	return fallback(path, line)
end

return M