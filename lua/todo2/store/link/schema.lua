-- lua/todo2/store/schema.lua
-- 统一数据模型定义

local M = {}

-- 内部统一结构（只存一份核心数据）
M.InternalLink = {
	-- 唯一标识
	id = "string", -- 链接ID

	-- 核心任务数据（唯一存储）
	core = {
		content = "string", -- 任务内容
		content_hash = "string", -- 内容哈希
		status = "string", -- 状态 (normal/urgent/waiting/completed/archived)
		previous_status = "string", -- 前状态
		tags = "table", -- 标签数组 ["FIX", "TODO"]
		ai_executable = "boolean", -- AI可执行标记
		sync_status = "string", -- "local" 或 "synced"
	},

	-- 时间戳统一管理
	timestamps = {
		created = "number",
		updated = "number",
		completed = "number?",
		archived = "number?",
		archived_reason = "string?",
	},

	-- 验证信息统一管理
	verification = {
		line_verified = "boolean",
		last_verified_at = "number?",
	},

	-- 位置信息分离
	locations = {
		todo = { -- TODO特有
			path = "string",
			line = "number",
		},
		code = { -- 代码特有
			path = "string",
			line = "number",
			context = "table?", -- 上下文信息
			context_matched = "boolean?",
			context_similarity = "number?",
			context_updated_at = "number?",
		},
	},
}

return M
