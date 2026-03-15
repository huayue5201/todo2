-- lua/todo2/ai/init.lua

local M = {}

local config = require("todo2.config")

local backends = {}
local current = nil

function M.register(name, adapter)
	backends[name] = adapter
end

function M.use(name)
	local adapter = backends[name]
	if not adapter then
		error("未知的 AI 模型后端: " .. tostring(name))
	end
	current = adapter
end

local function ensure_current()
	if current then
		return current
	end

	local name = config.model or "ollama"
	local adapter = backends[name]

	if not adapter then
		error("未找到模型适配器: " .. tostring(name))
	end

	current = adapter
	return current
end

function M.generate_stream(prompt, on_chunk, on_done)
	local adapter = ensure_current()
	return adapter.generate_stream(prompt, on_chunk, on_done)
end

-- ⭐ 主动加载适配器（不会循环）
require("todo2.ai.adapters.ollama")(M)
-- 如果有其他适配器，也这样加载
-- require("todo2.ai.adapters.copilot")(M)

return M
