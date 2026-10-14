-- lua/todo2/core/tree.lua
-- 结构层：不可变任务森林（Forest）。
--
-- 设计原则：
--   * 文本缩进是唯一的父子结构真源；节点保留原始行文本 raw，回放时原样输出，
--     绝不重算缩进（重算是历史上 store↔file 漂移的根源之一）。
--   * 纯数据 + 纯查询函数，不驻留可变状态，不读写 buffer / store。
--   * 只能由 parser 组装，供 serializer / edit 消费。

local M = {}

local config = require("todo2.config")

---@class todo2.TreeNode
---@field id string|nil
---@field raw string|nil 原始任务行文本
---@field indent string 前导空白
---@field indent_cols number 前导空白字符数
---@field level number
---@field line_num number
---@field path string
---@field checkbox string|nil
---@field content string
---@field tags string[]
---@field description string|nil
---@field description_lines string[]|nil 正文原始行（含缩进）
---@field orphan boolean
---@field children todo2.TreeNode[]
---@field parent todo2.TreeNode|nil

---@class todo2.Forest
---@field path string
---@field roots todo2.TreeNode[]
---@field nodes todo2.TreeNode[]
---@field by_id table<string, todo2.TreeNode>
---@field orphans number

local function leading_ws(line)
	return (line or ""):match("^(%s*)") or ""
end

--- 一级缩进的列数（= parser.indent_width）
---@return number
function M.indent_step()
	return config.get("parser.indent_width") or 2
end

--- 子节点应有的缩进字符串
---@param parent_indent string|nil
---@param st number|nil
---@return string
function M.child_indent(parent_indent, st)
	st = st or M.indent_step()
	return (parent_indent or "") .. string.rep(" ", st)
end

---------------------------------------------------------------------
-- 查询
---------------------------------------------------------------------

--- 前序扁平化
---@param roots todo2.TreeNode[]
---@return todo2.TreeNode[]
function M.flatten(roots)
	local out = {}
	local function walk(node)
		out[#out + 1] = node
		for _, c in ipairs(node.children or {}) do
			walk(c)
		end
	end
	for _, r in ipairs(roots) do
		walk(r)
	end
	return out
end

---@param roots todo2.TreeNode[]
---@return table<string, todo2.TreeNode>
function M.index_by_id(roots)
	local map = {}
	for _, n in ipairs(M.flatten(roots)) do
		if n.id then
			map[n.id] = n
		end
	end
	return map
end

--- 所有后代 id（不含自身）
---@param node todo2.TreeNode
---@return string[]
function M.descendant_ids(node)
	local ids = {}
	for _, c in ipairs(node.children or {}) do
		if c.id then
			ids[#ids + 1] = c.id
		end
		vim.list_extend(ids, M.descendant_ids(c))
	end
	return ids
end

--- 原样回放子树（任务行 + 正文行），缩进一律取 raw，不重算
---@param node todo2.TreeNode
---@return string[]
function M.raw_subtree(node)
	local out = {}
	if node.raw then
		out[#out + 1] = node.raw
	end
	for _, l in ipairs(node.description_lines or {}) do
		out[#out + 1] = l
	end
	for _, c in ipairs(node.children or {}) do
		vim.list_extend(out, M.raw_subtree(c))
	end
	return out
end

--- 统计与真实缩进不匹配（显式 orphan）的节点数
---@param roots todo2.TreeNode[]
---@return number
function M.mark_orphans(roots)
	local n = 0
	for _, node in ipairs(M.flatten(roots)) do
		if node.orphan then
			n = n + 1
		end
	end
	return n
end

---------------------------------------------------------------------
-- 组装
---------------------------------------------------------------------

--- 由 parser 结果组装不可变森林（会就地补全 parent/raw/indent，输入即 parser 内部产物）
---@param path string
---@param lines string[] 原始文件行
---@param parsed { roots?: todo2.TreeNode[], archive_trees?: table }
---@return todo2.Forest
function M.from_parser(path, lines, parsed)
	parsed = parsed or {}
	local roots = parsed.roots or {}

	local function annotate(node, parent)
		node.path = node.path or path
		node.raw = node.raw or (node.line_num and lines[node.line_num]) or nil
		node.indent = node.raw and leading_ws(node.raw) or (node.indent or "")
		node.indent_cols = #node.indent
		node.parent = parent
		node.children = node.children or {}
		for _, c in ipairs(node.children) do
			annotate(c, node)
		end
	end

	for _, r in ipairs(roots) do
		annotate(r, nil)
	end

	return {
		path = path,
		roots = roots,
		nodes = M.flatten(roots),
		by_id = M.index_by_id(roots),
		orphans = M.mark_orphans(roots),
		archive_trees = parsed.archive_trees,
	}
end

return M
