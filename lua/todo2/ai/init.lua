-- lua/todo2/ai/init.lua
-- AI 统一入口（仅流式）

local M = {}

local config = require("todo2.config")

-- 适配器
local adapters = {
	ollama = require("todo2.ai.adapters.ollama"),
	copilot = require("todo2.ai.adapters.copilot"),
}

local function get_adapter()
	local name = config.model or "ollama"
	local adapter = adapters[name]
	if not adapter then
		error("未知的 AI 适配器: " .. tostring(name))
	end
	return adapter
end

-- ⭐ 仅保留流式生成
function M.generate_stream(prompt, on_chunk, on_done)
	local adapter = get_adapter()

	if not adapter.generate_stream then
		error("适配器未实现 generate_stream()")
	end

	return adapter.generate_stream(prompt, on_chunk, on_done)
end

return M
