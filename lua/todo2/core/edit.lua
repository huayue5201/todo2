-- lua/todo2/core/edit.lua
-- 编辑层：纯函数 tree -> tree'。
--
-- 语义要点：
--   * 所有操作先深拷贝森林，绝不修改入参（调用方持有的 Forest 保持不可变）。
--   * remove_subtree 展开整棵子树；remove_promote 只删自身并把子节点提升一级。
--   * 缩进由 tree.child_indent 派生，不查 store。

local M = {}

local tree = require("todo2.core.tree")
local serializer = require("todo2.core.serializer")

--- 深拷贝森林结构（丢弃原 parent 引用，重新挂接）
---@param roots todo2.TreeNode[]
---@return todo2.TreeNode[]
local function clone_forest(roots)
	local function clone(n, parent)
		local c = {
			id = n.id,
			raw = n.raw,
			indent = n.indent,
			indent_cols = n.indent_cols,
			level = n.level,
			line_num = n.line_num,
			path = n.path,
			checkbox = n.checkbox,
			status = n.status,
			content = n.content,
			tags = n.tags,
			description = n.description,
			description_lines = n.description_lines,
			orphan = n.orphan,
			parent = parent,
			children = {},
		}
		for _, ch in ipairs(n.children or {}) do
			local cc = clone(ch, c)
			c.children[#c.children + 1] = cc
		end
		return c
	end
	local out = {}
	for _, r in ipairs(roots) do
		out[#out + 1] = clone(r, nil)
	end
	return out
end

local function reindent_deep(node, delta)
	local function walk(n)
		local cols = n.indent_cols + delta
		if cols < 0 then
			cols = 0
		end
		n.indent = string.rep(" ", cols)
		n.indent_cols = cols
		for _, c in ipairs(n.children or {}) do
			walk(c)
		end
	end
	walk(node)
end

--- 删除整棵子树
---@param roots todo2.TreeNode[]
---@param id string
---@return todo2.TreeNode[]
function M.remove_subtree(roots, id)
	local out = clone_forest(roots)
	local function prune(nodes)
		for i = #nodes, 1, -1 do
			if nodes[i].id == id then
				table.remove(nodes, i)
			else
				prune(nodes[i].children)
			end
		end
	end
	prune(out)
	return out
end

--- 删除自身，子节点提升一级（缩进各减 step）
---@param roots todo2.TreeNode[]
---@param id string
---@return todo2.TreeNode[]
function M.remove_promote(roots, id)
	local out = clone_forest(roots)
	local step = tree.indent_step()
	local function walk(nodes)
		for i = #nodes, 1, -1 do
			local n = nodes[i]
			if n.id == id then
				local kids = n.children or {}
				for _, k in ipairs(kids) do
					reindent_deep(k, -step)
					k.parent = n.parent
				end
				table.remove(nodes, i)
				for k = #kids, 1, -1 do
					table.insert(nodes, i, kids[k])
				end
			else
				walk(n.children)
			end
		end
	end
	walk(out)
	return out
end

--- 在 parent_id 下新增节点（缩进对齐到子级；parent_id 为 nil 时作为根）
---@param roots todo2.TreeNode[]
---@param parent_id string|nil
---@param node todo2.TreeNode
---@param position number|nil
---@return todo2.TreeNode[]
---@return boolean ok
function M.insert_child(roots, parent_id, node, position)
	local out = clone_forest(roots)
	local target = nil
	if parent_id == nil then
		target = { indent = "", indent_cols = 0, children = out, parent = nil }
	else
		for _, n in ipairs(tree.flatten(out)) do
			if n.id == parent_id then
				target = n
				break
			end
		end
	end
	if not target then
		return roots, false
	end

	local step = tree.indent_step()
	local parent_indent = target.indent or ""
	local indent = parent_id == nil and "" or tree.child_indent(parent_indent, step)
	local copy = serializer.with_indent(node, indent)
	copy.parent = parent_id and target or nil

	if parent_id == nil then
		local pos = position or (#out + 1)
		table.insert(out, pos, copy)
	else
		local pos = position or (#target.children + 1)
		table.insert(target.children, pos, copy)
	end
	return out, true
end

--- 移动节点到 new_parent_id 下（new_parent_id 为 nil 时移到根层）
---@param roots todo2.TreeNode[]
---@param id string
---@param new_parent_id string|nil
---@param position number|nil
---@return todo2.TreeNode[]
---@return boolean ok
function M.move(roots, id, new_parent_id, position)
	local forest = { roots = roots }
	local nodes = tree.flatten(roots)
	local node = nil
	for _, n in ipairs(nodes) do
		if n.id == id then
			node = n
			break
		end
	end
	if not node then
		return roots, false
	end
	if node.id == new_parent_id then
		return roots, false
	end

	-- 收集被移动子树（原样）
	local subtree_raw = {
		id = node.id,
		raw = node.raw,
		indent = node.indent,
		indent_cols = node.indent_cols,
		level = node.level,
		path = node.path,
		checkbox = node.checkbox,
		status = node.status,
		content = node.content,
		tags = node.tags,
		description = node.description,
		description_lines = node.description_lines,
		orphan = node.orphan,
		children = vim.deepcopy(node.children),
	}
	for _, c in ipairs(subtree_raw.children or {}) do
		c.parent = subtree_raw
	end

	local without = M.remove_subtree(roots, id)
	local new_roots, ok = M.insert_child(without, new_parent_id, subtree_raw, position)
	return new_roots, ok
end

return M
