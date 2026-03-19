-- lua/todo2/core/block_signature.lua
-- 轻量 AST：结构签名生成器
---@module "todo2.core.block_signature"

local M = {}

---------------------------------------------------------------------
-- 生成文本 hash（使用 Neovim 内置函数）
---------------------------------------------------------------------

---计算文本的哈希值
---@param text string 文本内容
---@return string 哈希值（16进制字符串）
local function text_hash(text)
	if not text or text == "" then
		return ""
	end

	-- 使用 vim.fn.sha256（Neovim 内置）
	local ok, hash = pcall(vim.fn.sha256, text)
	if ok and hash then
		return hash
	end

	return ""
end

---------------------------------------------------------------------
-- 生成结构签名
-- 输入：AST 节点（来自 code_block_parser）
-- 输出：一个可比较的 signature 表
---------------------------------------------------------------------

---生成节点签名
---@param node table AST节点
---@return table 签名表，包含 type, indent, child_count, task_ids, hash
function M.signature(node)
	-- node.line 是原始文本
	local text = node.line or ""

	-- 任务 ID 是最强特征
	local task_ids = node.task_ids or {}

	-- 子节点数量（结构特征）
	local child_count = #(node.children or {})

	-- 文本 hash（弱特征，但用于区分同类型块）
	local hash = text_hash(text)

	return {
		type = node.type, -- function / class / if / for / while / brace_block / line
		indent = node.indent, -- 缩进层级
		child_count = child_count,
		task_ids = task_ids, -- ⭐ 最重要：任务 ID
		hash = hash, -- 文本 hash（可选）
	}
end

---------------------------------------------------------------------
-- 比较两个签名是否“相同结构”
-- 用于 AST diff
---------------------------------------------------------------------

---比较两个签名是否相等
---@param sig1 table 第一个签名
---@param sig2 table 第二个签名
---@return boolean 是否相等
function M.equals(sig1, sig2)
	if sig1.type ~= sig2.type then
		return false
	end

	-- 任务 ID 完全一致 → 100% 是同一个块
	if #sig1.task_ids > 0 or #sig2.task_ids > 0 then
		if #sig1.task_ids ~= #sig2.task_ids then
			return false
		end
		for i, id in ipairs(sig1.task_ids) do
			if sig2.task_ids[i] ~= id then
				return false
			end
		end
		return true
	end

	-- 没有任务 ID 的块，用结构特征匹配
	if sig1.child_count ~= sig2.child_count then
		return false
	end

	-- 文本 hash 匹配（弱特征）
	if sig1.hash ~= "" and sig2.hash ~= "" and sig1.hash ~= sig2.hash then
		return false
	end

	return true
end

return M
