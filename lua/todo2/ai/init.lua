-- lua/todo2/ai/init.lua
-- 模型适配层统一入口：ai.generate(prompt)

-- TODO:ref:0f8edb
local M = {}

local config = require("todo2.config")

-- 所有模型适配器
local adapters = {
	copilot = require("todo2.ai.adapters.copilot"),
	opencode = require("todo2.ai.adapters.opencode"),
}

--- 调用大模型生成代码
--- @param prompt string
--- @return string|nil 统一返回字符串，失败返回 nil
function M.generate(prompt)
	-- 默认模型：copilot
	local model = config.get("ai.model") or "copilot"
	local adapter = adapters[model]

	if not adapter then
		error("未知模型适配器: " .. model)
	end

	local result = adapter.generate(prompt)

	-- ⭐ 统一返回值格式：所有适配器必须在这里被转换为字符串
	if result == nil then
		return nil
	end

	if type(result) == "string" then
		-- copilot 风格：直接返回字符串
		return result
	elseif type(result) == "table" then
		-- opencode 风格：返回表，需要提取 content
		if result.ok and result.content then
			return result.content
		elseif result.content then
			return result.content
		elseif result.code then
			return result.code
		else
			-- 无法识别的表结构，记录错误并返回 nil
			vim.notify("AI 适配器返回了无法识别的表结构: " .. vim.inspect(result), vim.log.levels.ERROR)
			return nil
		end
	else
		-- 其他类型（number, boolean 等），转为字符串或返回 nil
		vim.notify("AI 适配器返回了未知类型: " .. type(result), vim.log.levels.ERROR)
		return tostring(result)
	end
end

return M
