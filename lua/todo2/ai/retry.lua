-- lua/todo2/ai/retry.lua
-- 重试机制：保存失败上下文，支持智能重试

local M = {}

local store = require("todo2.store.nvim_store")
local file = require("todo2.utils.file")

-- 命名空间
local NAMESPACE = "todo.ai.retry."

---@class RetryContext
---@field task_id string 任务ID
---@field original_request string 原始请求
---@field error_message string 错误信息
---@field attempted_code string|nil 尝试生成的代码
---@field diff string|nil 失败尝试的 diff
---@field timestamp integer 时间戳
---@field retry_count integer 重试次数
---@field files_affected string[] 受影响的文件

---保存失败上下文
---@param task_id string
---@param context RetryContext
---@return boolean
function M.save(task_id, context)
	if not task_id then
		return false
	end

	context.timestamp = os.time()
	context.retry_count = (context.retry_count or 0) + 1

	local key = NAMESPACE .. task_id
	local ok, encoded = pcall(vim.json.encode, context)
	if not ok then
		return false
	end

	store.set_key(key, encoded)
	return true
end

---加载失败上下文
---@param task_id string
---@return RetryContext|nil
function M.load(task_id)
	if not task_id then
		return nil
	end

	local key = NAMESPACE .. task_id
	local raw = store.get_key(key)
	if not raw then
		return nil
	end

	local ok, context = pcall(vim.json.decode, raw)
	if not ok then
		return nil
	end

	return context
end

---删除失败上下文
---@param task_id string
---@return boolean
function M.delete(task_id)
	if not task_id then
		return false
	end

	local key = NAMESPACE .. task_id
	store.delete_key(key)
	return true
end

---获取所有待重试的任务
---@return table<string, RetryContext>
function M.list()
	local keys = store.get_namespace_keys(NAMESPACE) or {}
	local result = {}

	for _, key in ipairs(keys) do
		local task_id = key:match("^" .. NAMESPACE .. "(.*)$")
		if task_id then
			local context = M.load(task_id)
			if context then
				result[task_id] = context
			end
		end
	end

	return result
end

---构建重试 Prompt
---@param context RetryContext
---@return string
function M.build_retry_prompt(context)
	local parts = {
		"## 之前的尝试失败了",
		"",
		"**原始任务**: " .. (context.original_request or ""),
		"",
		"**错误信息**: " .. (context.error_message or "未知错误"),
		"",
	}

	if context.attempted_code and context.attempted_code ~= "" then
		parts[#parts + 1] = "**之前尝试生成的代码**:"
		parts[#parts + 1] = "```"
		parts[#parts + 1] = context.attempted_code:sub(1, 2000)
		if #context.attempted_code > 2000 then
			parts[#parts + 1] = "... (截断)"
		end
		parts[#parts + 1] = "```"
		parts[#parts + 1] = ""
	end

	if context.diff and context.diff ~= "" then
		parts[#parts + 1] = "**之前的变更（已回滚）**:"
		parts[#parts + 1] = "```diff"
		parts[#parts + 1] = context.diff:sub(1, 3000)
		if #context.diff > 3000 then
			parts[#parts + 1] = "... (截断)"
		end
		parts[#parts + 1] = "```"
		parts[#parts + 1] = ""
	end

	parts[#parts + 1] = "**重试要求**:"
	parts[#parts + 1] = "- 分析之前的错误，不要重复同样的错误"
	parts[#parts + 1] = "- 如果之前的代码方向正确，修复问题后重新生成"
	parts[#parts + 1] = "- 如果之前的代码方向完全错误，请重新思考解决方案"
	parts[#parts + 1] = "- 确保生成的代码语法正确、可以编译"

	return table.concat(parts, "\n")
end

---清理过期的重试上下文（超过 7 天）
---@return integer cleaned_count
function M.cleanup_old(days)
	days = days or 7
	local cutoff = os.time() - (days * 86400)

	local contexts = M.list()
	local cleaned = 0

	for task_id, context in pairs(contexts) do
		if context.timestamp and context.timestamp < cutoff then
			M.delete(task_id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

return M
