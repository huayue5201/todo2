-- lua/todo2/core/code_block_parser.lua
-- 轻量 AST：基于缩进 + 结构特征的代码块解析器

local M = {}

local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 工具：统计缩进
---------------------------------------------------------------------
local function count_indent(line)
	local spaces = line:match("^(%s*)")
	return spaces and #spaces or 0
end

---------------------------------------------------------------------
-- 工具：检测块类型（非常轻量）
---------------------------------------------------------------------
local function detect_block_type(line)
	line = line:match("^%s*(.-)%s*$") or ""

	if line:match("^function ") or line:match("=%s*function%s*%(") then
		return "function"
	elseif line:match("^class ") then
		return "class"
	elseif line:match("^if ") then
		return "if"
	elseif line:match("^for ") then
		return "for"
	elseif line:match("^while ") then
		return "while"
	elseif line:match("{$") then
		return "brace_block"
	end

	return "line"
end

---------------------------------------------------------------------
-- 工具：提取任务 ID（来自 code mark）
---------------------------------------------------------------------
local function extract_task_ids(line)
	local ids = {}

	if id_utils.contains_code_mark(line) then
		local id = id_utils.extract_id_from_code_mark(line)
		if id then
			table.insert(ids, id)
		end
	end

	return ids
end

---------------------------------------------------------------------
-- 主逻辑：构建轻量 AST
---------------------------------------------------------------------
function M.parse(lines)
	local root = {
		type = "root",
		indent = -1,
		start_line = 1,
		end_line = #lines,
		children = {},
		task_ids = {},
	}

	local stack = { root }

	for i, line in ipairs(lines) do
		local indent = count_indent(line)
		local block_type = detect_block_type(line)
		local ids = extract_task_ids(line)

		local node = {
			type = block_type,
			indent = indent,
			start_line = i,
			end_line = i,
			children = {},
			task_ids = ids,
			line = line,
		}

		-- 找父节点（缩进比当前小的）
		while #stack > 0 and stack[#stack].indent >= indent do
			stack[#stack].end_line = i - 1
			table.remove(stack)
		end

		-- 挂到父节点
		table.insert(stack[#stack].children, node)

		-- 如果是结构块，入栈
		if block_type ~= "line" then
			table.insert(stack, node)
		end
	end

	return root
end

---------------------------------------------------------------------
-- 工具：遍历 AST（用于调试）
---------------------------------------------------------------------
function M.walk(node, fn)
	fn(node)
	for _, child in ipairs(node.children or {}) do
		M.walk(child, fn)
	end
end

return M
