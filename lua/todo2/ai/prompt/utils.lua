-- lua/todo2/ai/prompt/utils.lua
-- Prompt 工具函数（不依赖 base.lua）

local M = {}
local comment = require("todo2.utils.comment")

--- 根据语言获取注释格式
--- @param lang string
--- @return table
function M.get_comment_style(lang)
	local prefix = comment.get_by_filetype(lang)

	if prefix then
		if prefix == "/*" or prefix == "<!--" or prefix == '"""' or prefix == "--[[" then
			local block_end = {
				["/*"] = "*/",
				["<!--"] = "-->",
				['"""'] = '"""',
				["--[["] = "--]]",
			}
			return {
				line = prefix,
				block_start = prefix,
				block_end = block_end[prefix] or prefix,
			}
		else
			return {
				line = prefix,
				block_start = nil,
				block_end = nil,
			}
		end
	end

	return { line = "//", block_start = "/*", block_end = "*/" }
end

--- 格式化任务节点
--- @param node table
--- @return string
function M.format_task_node(node)
	if not node then
		return ""
	end

	local content = node.content or ""
	local parts = { content }

	if node.id then
		parts[#parts + 1] = string.format("(%s)", node.id)
	end

	if node.code_summary and node.code_summary.location then
		parts[#parts + 1] = string.format("[%s]", node.code_summary.location)
	elseif node.path then
		local location = vim.fn.fnamemodify(node.path, ":t")
		if node.line then
			location = string.format("%s:%d", location, node.line)
		end
		parts[#parts + 1] = string.format("[%s]", location)
	end

	return "- " .. table.concat(parts, " ")
end

--- 格式化任务列表
--- @param list table[]
--- @return string
function M.format_task_list(list)
	if not list or #list == 0 then
		return "- 无"
	end

	local out = {}
	for _, node in ipairs(list) do
		table.insert(out, M.format_task_node(node))
	end
	return table.concat(out, "\n")
end

--- 截断文本
--- @param text string
--- @param max_len number
--- @return string
function M.truncate(text, max_len)
	if not text or #text <= max_len then
		return text or ""
	end
	return text:sub(1, max_len) .. "..."
end

--- 提取代码摘要
--- @param code string
--- @param max_lines number
--- @return string
function M.extract_code_summary(code, max_lines)
	if not code then
		return ""
	end

	local lines = vim.split(code, "\n")
	if #lines <= max_lines then
		return code
	end

	local half = math.floor(max_lines / 2)
	local first_half = {}
	local second_half = {}

	for i = 1, half do
		table.insert(first_half, lines[i])
	end

	for i = #lines - half + 1, #lines do
		table.insert(second_half, lines[i])
	end

	return table.concat(first_half, "\n") .. "\n...\n" .. table.concat(second_half, "\n")
end

--- 获取标签对应的策略名
--- @param tags table
--- @return string
function M.get_strategy_by_tags(tags)
	local tag_strategy_map = {
		FIX = "bug_fix",
		BUG = "bug_fix",
		HOTFIX = "bug_fix",
		REFACTOR = "refactor",
		OPTIMIZE = "refactor",
		CLEANUP = "refactor",
		FEATURE = "feature",
		TODO = "feature",
		ENHANCE = "feature",
		TEST = "testing",
		SPEC = "testing",
		DOC = "documentation",
		COMMENT = "comment",
		NOTE = "comment",
	}

	for _, tag in ipairs(tags or {}) do
		local strategy = tag_strategy_map[tag]
		if strategy then
			return strategy
		end
	end

	return "default"
end

return M
