-- lua/todo2/ai/context.lua
-- 任务驱动的上下文收集器（修复 Treesitter 错误）

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
-- 工具：从 symbol 树中找到包含任务行的 symbol
------------------------------------------------------------
local function find_symbol_containing_line(symbols, line)
	for _, sym in ipairs(symbols) do
		local s = sym.range.start.line + 1
		local e = sym.range["end"].line + 1
		if line >= s and line <= e then
			if sym.children then
				return find_symbol_containing_line(sym.children, line) or sym
			end
			return sym
		end
	end
	return nil
end

------------------------------------------------------------
-- 第一层：LSP 上下文
------------------------------------------------------------
function M.from_lsp(todo)
	local bufnr = vim.fn.bufnr(todo.path, true)
	if bufnr == -1 then
		return nil
	end

	-- 检查是否有 LSP 客户端附加到该缓冲区
	local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
	if #clients == 0 then
		return nil
	end

	-- 安全地创建位置参数
	local params
	local ok, err = pcall(function()
		if vim.fn.has("nvim-0.9") == 1 or (vim.version() and vim.version().minor >= 9) then
			params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding or "utf-8")
		else
			params = vim.lsp.util.make_position_params()
		end
	end)

	if not ok or not params then
		return nil
	end

	params.position.line = todo.line - 1

	local ok_resp, responses = pcall(vim.lsp.buf_request_sync, bufnr, "textDocument/documentSymbol", params, 300)
	if not ok_resp or not responses then
		return nil
	end

	for _, resp in pairs(responses) do
		if resp.error then
			goto continue
		end

		local symbols = resp.result or {}
		if type(symbols) ~= "table" then
			goto continue
		end

		local found = find_symbol_containing_line(symbols, todo.line)
		if found then
			local s = found.range.start.line + 1
			local e = found.range["end"].line + 1

			local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, s - 1, e, false)
			if not ok_lines or not lines then
				goto continue
			end

			return {
				source = "lsp",
				func = table.concat(lines, "\n"),
				start_line = s,
				end_line = e,
				name = found.name,
				kind = found.kind,
			}
		end
		::continue::
	end

	return nil
end

------------------------------------------------------------
-- 第二层：Treesitter 上下文（修复版）
------------------------------------------------------------
function M.from_treesitter(todo)
	local bufnr = vim.fn.bufnr(todo.path, true)
	if bufnr == -1 then
		return nil
	end

	-- 检查是否有 treesitter 解析器
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not ok or not parser then
		return nil
	end

	-- 安全解析，处理可能的错误
	local ok_tree, tree = pcall(function()
		return parser:parse()
	end)

	if not ok_tree or not tree then
		return nil
	end

	-- 检查 tree 是否是有效的表并且有 root 方法
	if type(tree) ~= "table" or #tree == 0 then
		return nil
	end

	-- 获取第一个语法树
	local first_tree = tree[1]
	if not first_tree or type(first_tree) ~= "table" then
		return nil
	end

	-- 安全调用 root 方法
	local ok_root, root = pcall(function()
		return first_tree:root()
	end)

	if not ok_root or not root then
		return nil
	end

	-- 查找包含当前行的节点
	local node = root:named_descendant_for_range(todo.line - 1, 0, todo.line - 1, 0)

	while node do
		local t = node:type()
		-- 常见的函数/方法节点类型
		if
			t:match("function")
			or t:match("method")
			or t:match("function_declaration")
			or t:match("method_declaration")
			or t:match("func_literal")
		then
			local s_row, _, e_row, _ = node:range()
			local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, s_row, e_row + 1, false)
			if ok_lines and lines then
				return {
					source = "treesitter",
					func = table.concat(lines, "\n"),
					start_line = s_row + 1,
					end_line = e_row + 1,
				}
			end
		end
		node = node:parent()
	end

	return nil
end

------------------------------------------------------------
-- 第三层：Regex fallback
------------------------------------------------------------
local function find_end_of_block(lines, start)
	local indent = lines[start]:match("^(%s*)") or ""
	local base = #indent

	for i = start + 1, #lines do
		local cur_indent = lines[i]:match("^(%s*)") or ""
		if #cur_indent < base and lines[i]:match("%S") then
			return i - 1
		end
	end

	return #lines
end

function M.from_regex(todo)
	local lines = read_lines(todo.path)
	if #lines == 0 then
		return nil
	end

	for i = todo.line, 1, -1 do
		if
			lines[i]:match("^%s*func%s+%w+%s*%(")
			or lines[i]:match("^%s*function%s+%w+%s*%(")
			or lines[i]:match("^%s*def%s+%w+%s*%(")
			or lines[i]:match("^%s*function%s+%w+%s*%(")
			or lines[i]:match("^%s*%w+%.%w+%s*=%s*function%s*%(")
		then
			local start = i
			local finish = find_end_of_block(lines, i)
			return {
				source = "regex",
				func = table.concat(vim.list_slice(lines, start, finish), "\n"),
				start_line = start,
				end_line = finish,
			}
		end
	end

	return nil
end

------------------------------------------------------------
-- 第四层：Fallback（周围 20 行）
------------------------------------------------------------
function M.from_fallback(todo)
	local lines = read_lines(todo.path)
	if #lines == 0 then
		return nil
	end

	local s = math.max(1, todo.line - 10)
	local e = math.min(#lines, todo.line + 10)

	return {
		source = "fallback",
		func = table.concat(vim.list_slice(lines, s, e), "\n"),
		start_line = s,
		end_line = e,
	}
end

------------------------------------------------------------
-- 主入口：任务驱动上下文收集
------------------------------------------------------------
function M.collect(todo)
	return M.from_lsp(todo) or M.from_treesitter(todo) or M.from_regex(todo) or M.from_fallback(todo)
end

return M
