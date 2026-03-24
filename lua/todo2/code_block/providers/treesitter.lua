-- lua/todo2/code_block/providers/treesitter.lua
-- 统一的 Treesitter 代码块提供器

local Types = require("todo2.code_block.core.types")
local Queries = require("todo2.code_block.queries")

local M = {
	name = "treesitter",
	priority = 100,
}

--- 获取节点文本
local function get_node_text(node, bufnr)
	if not node then
		return nil
	end
	local ok, ts = pcall(require, "vim.treesitter")
	if not ok then
		return nil
	end
	return ts.get_node_text(node, bufnr)
end

--- 从节点获取指定字段的子节点
local function get_child_by_field(node, field_name)
	local field_node = node:field(field_name)
	if field_node and type(field_node) == "userdata" then
		return field_node
	end
	if field_node and type(field_node) == "table" and #field_node > 0 then
		return field_node[1]
	end
	return nil
end

--- 从节点提取名称
local function extract_name(node, lang_config, bufnr)
	local name_field = lang_config.fields and lang_config.fields.name
	if name_field then
		local name_node = get_child_by_field(node, name_field)
		if name_node then
			return get_node_text(name_node, bufnr)
		end
	end

	for child in node:iter_children() do
		local child_type = child:type()
		if
			child_type == "identifier"
			or child_type == "type_identifier"
			or child_type == "field_identifier"
			or child_type == "name"
		then
			return get_node_text(child, bufnr)
		end
	end

	return nil
end

--- 提取参数列表
local function extract_parameters(node, lang_config, bufnr)
	local params_field = lang_config.fields and lang_config.fields.parameters
	if params_field then
		local params_node = get_child_by_field(node, params_field)
		if params_node then
			return get_node_text(params_node, bufnr) or "()"
		end
	end
	return "()"
end

--- 提取返回值
local function extract_return_type(node, lang_config, bufnr)
	local result_field = lang_config.fields and (lang_config.fields.result or lang_config.fields.return_type)
	if result_field then
		local result_node = get_child_by_field(node, result_field)
		if result_node then
			return get_node_text(result_node, bufnr) or ""
		end
	end
	return ""
end

--- 提取接收者（方法）
local function extract_receiver(node, lang_config, bufnr)
	local receiver_field = lang_config.fields and lang_config.fields.receiver
	if receiver_field then
		local receiver_node = get_child_by_field(node, receiver_field)
		if receiver_node then
			return get_node_text(receiver_node, bufnr)
		end
	end
	return nil
end

--- 检查是否为异步函数
local function is_async_function(node)
	return node:type() == "async_function_definition"
end

--- 提取签名
local function extract_signature(node, lang_config, bufnr, block_type)
	local name = extract_name(node, lang_config, bufnr)
	if not name then
		return nil
	end

	if block_type ~= "function" and block_type ~= "method" then
		return string.format("%s %s", block_type, name)
	end

	local params = extract_parameters(node, lang_config, bufnr)
	local return_type = extract_return_type(node, lang_config, bufnr)
	local receiver = extract_receiver(node, lang_config, bufnr)
	local is_async = is_async_function(node)

	if lang_config.format_signature then
		if block_type == "method" then
			return lang_config.format_signature(name, params, return_type, receiver)
		elseif block_type == "function" then
			return lang_config.format_signature(name, params, return_type, nil, is_async)
		end
	end

	if receiver then
		return string.format("func %s %s%s %s", receiver, name, params, return_type)
	end
	return string.format("func %s%s %s", name, params, return_type)
end

--- 获取代码块类型
local function get_block_type(node_type, lang_config)
	return lang_config.blocks[node_type]
end

--- 语句级节点类型集合
local STATEMENT_TYPES = {
	statement = true,
	expression_statement = true,
	assignment_statement = true,
	variable_declaration = true,
	local_declaration = true,
	if_statement = true,
	for_statement = true,
	while_statement = true,
	return_statement = true,
	call_expression = true,
}

--- 查找最近的语句节点
local function find_nearest_statement_node(node)
	if not node then
		return nil
	end
	local cur_node = node
	while cur_node do
		if STATEMENT_TYPES[cur_node:type()] then
			return cur_node
		end
		cur_node = cur_node:parent()
	end
	return nil
end

--- 获取祖先链
local function get_ancestor_chain(node, max_depth)
	if not node then
		return {}
	end

	local ancestors = {}
	local cur_node = node:parent()
	local depth = 0
	max_depth = max_depth or 5

	while cur_node and depth < max_depth do
		local sr, sc, er, ec = cur_node:range()
		table.insert(ancestors, {
			type = cur_node:type(),
			start_line = sr + 1,
			end_line = er + 1,
			start_col = sc,
			end_col = ec,
		})
		cur_node = cur_node:parent()
		depth = depth + 1
	end

	return ancestors
end

--- 构建节点信息（精简版，不含完整代码）
local function build_node_info(node)
	if not node then
		return nil
	end

	local sr, sc, er, ec = node:range()
	return {
		type = node:type(),
		start_line = sr + 1,
		end_line = er + 1,
		start_col = sc,
		end_col = ec,
		is_named = node:named(),
	}
end

--- 获取光标所在行的代码块
function M.get_block(bufnr, lnum)
	local ok, ts = pcall(require, "vim.treesitter")
	if not ok then
		return nil
	end

	local parser = ts.get_parser(bufnr)
	if not parser then
		return nil
	end

	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	local root = tree:root()
	if not root then
		return nil
	end

	local ft = Types.get_filetype(bufnr)
	local lang_config = Queries.get(ft)
	if not lang_config then
		return nil
	end

	local lnum0 = lnum - 1
	local current_node = root:named_descendant_for_range(lnum0, 0, lnum0, 0)
	if not current_node then
		return nil
	end

	-- 如果当前节点是注释，查找下一个兄弟节点
	local node_type = current_node:type()
	if node_type == "comment" then
		local next_node = current_node:next_named_sibling()
		if next_node then
			current_node = next_node
		else
			current_node = current_node:parent()
		end
	end

	-- 向上查找代码块节点
	local block_node = nil
	local block_type = nil
	local search_node = current_node

	while search_node do
		local search_type = search_node:type()
		local btype = get_block_type(search_type, lang_config)
		if btype then
			block_node = search_node
			block_type = btype
			break
		end
		search_node = search_node:parent()
	end

	if not block_node then
		return nil
	end

	local srow, scol, erow, ecol = block_node:range()
	local text = get_node_text(block_node, bufnr)
	local name = extract_name(block_node, lang_config, bufnr)
	local signature = extract_signature(block_node, lang_config, bufnr, block_type)
	local is_method = block_type == "method"
	local receiver = is_method and extract_receiver(block_node, lang_config, bufnr) or nil
	local hash_utils = require("todo2.utils.hash")

	-- 获取精细结构信息（精简版）
	local inner_node = root:named_descendant_for_range(lnum0, 0, lnum0, 0)
	local inner_node_info = nil
	local statement_info = nil
	local ancestors_info = nil

	if inner_node then
		inner_node_info = build_node_info(inner_node)

		local stmt_node = find_nearest_statement_node(inner_node)
		if stmt_node then
			statement_info = build_node_info(stmt_node)
		end

		ancestors_info = get_ancestor_chain(inner_node, 5)
	end

	local relative_line = lnum - (srow + 1) + 1

	return {
		source = "treesitter",
		lang = ft,
		bufnr = bufnr,
		type = block_type,
		raw_type = block_node:type(),
		name = name,
		signature = signature or "",
		signature_hash = signature and hash_utils.hash(signature) or "00000000",
		start_line = srow + 1,
		start_col = scol,
		end_line = erow + 1,
		end_col = ecol,
		text = text,
		node = block_node,
		is_method = is_method,
		receiver = receiver,
		inner_node = inner_node_info,
		statement = statement_info,
		ancestors = ancestors_info,
		relative_line = relative_line,
	}
end

--- 获取文件中的所有代码块
function M.get_all(bufnr)
	local ok, ts = pcall(require, "vim.treesitter")
	if not ok then
		return {}
	end

	local parser = ts.get_parser(bufnr)
	if not parser then
		return {}
	end

	local tree = parser:parse()[1]
	if not tree then
		return {}
	end

	local root = tree:root()
	if not root then
		return {}
	end

	local ft = Types.get_filetype(bufnr)
	local lang_config = Queries.get(ft)
	if not lang_config then
		return {}
	end

	local blocks = {}
	local hash_utils = require("todo2.utils.hash")

	local function walk(node)
		local node_type = node:type()
		local block_type = get_block_type(node_type, lang_config)

		if block_type then
			local srow, _, erow, _ = node:range()
			local name = extract_name(node, lang_config, bufnr)
			local signature = extract_signature(node, lang_config, bufnr, block_type)
			local is_method = block_type == "method"
			local receiver = is_method and extract_receiver(node, lang_config, bufnr) or nil

			blocks[#blocks + 1] = {
				source = "treesitter",
				lang = ft,
				bufnr = bufnr,
				type = block_type,
				raw_type = node_type,
				name = name,
				signature = signature or "",
				signature_hash = signature and hash_utils.hash(signature) or "00000000",
				start_line = srow + 1,
				end_line = erow + 1,
				node = node,
				is_method = is_method,
				receiver = receiver,
			}
		end

		for child in node:iter_children() do
			walk(child)
		end
	end

	walk(root)
	return blocks
end

function M.supports(bufnr)
	local ft = Types.get_filetype(bufnr)
	return Queries.get(ft) ~= nil
end

return M
