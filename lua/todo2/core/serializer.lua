-- lua/todo2/core/serializer.lua
-- 序列化层：TreeNode → 文本行。
--
-- 与 tree.raw_subtree 的分工：
--   * raw_subtree —— 原样回放（未修改的既有节点，缩进/正文一字不改）。
--   * serializer  —— 由节点字段重新生成（新建 / 编辑后的节点），缩进取 node.indent。
-- 二者都不会去 store 里反查缩进。

local M = {}

local format = require("todo2.utils.format")
local description = require("todo2.core.description")
local tree = require("todo2.core.tree")

--- 单条任务行（不含换行）
---@param node todo2.TreeNode
---@return string
function M.line(node)
	return format.format_task_line({
		indent = node.indent or "",
		checkbox = node.checkbox or "[ ]",
		id = node.id,
		status = node.status,
		tags = node.tags,
		content = node.content or "",
	})
end

--- 正文行（按内容列重新缩进）
---@param node todo2.TreeNode
---@return string[]
function M.description_lines(node)
	if not node.description or node.description == "" then
		return {}
	end
	local indent = (node.indent or "") .. string.rep(" ", description.CONTENT_OFFSET)
	return description.to_lines(node.description, indent)
end

--- 节点自身（任务行 + 正文）
---@param node todo2.TreeNode
---@return string[]
function M.node(node)
	local out = { M.line(node) }
	vim.list_extend(out, M.description_lines(node))
	return out
end

--- 子树（前序）
---@param node todo2.TreeNode
---@return string[]
function M.subtree(node)
	local out = {}
	for _, n in ipairs(tree.flatten({ node })) do
		vim.list_extend(out, M.node(n))
	end
	return out
end

--- 森林
---@param roots todo2.TreeNode[]
---@return string[]
function M.forest(roots)
	local out = {}
	for _, n in ipairs(tree.flatten(roots)) do
		vim.list_extend(out, M.node(n))
	end
	return out
end

--- 浅拷贝并替换缩进（不重算，显式给出）
---@param node todo2.TreeNode
---@param indent string
---@return todo2.TreeNode
function M.with_indent(node, indent)
	local copy = vim.tbl_extend("force", {}, node)
	copy.indent = indent
	copy.indent_cols = #indent
	return copy
end

--- 深拷贝子树并整体调整缩进（delta_cols 可为负，最小 0）
---@param node todo2.TreeNode
---@param delta_cols number
---@return todo2.TreeNode
function M.reindent_subtree(node, delta_cols)
	local function adj(indent)
		local cols = #indent + delta_cols
		if cols < 0 then
			cols = 0
		end
		return string.rep(" ", cols)
	end
	local function clone(n)
		local c = vim.tbl_extend("force", {}, n)
		c.indent = adj(n.indent or "")
		c.indent_cols = #c.indent
		c.children = {}
		for _, ch in ipairs(n.children or {}) do
			local cc = clone(ch)
			cc.parent = c
			c.children[#c.children + 1] = cc
		end
		return c
	end
	return clone(node)
end

return M
