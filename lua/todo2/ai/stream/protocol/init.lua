-- lua/todo2/ai/stream/protocol/init.lua
local M = {}

local strategies = {
	require("todo2.ai.stream.protocol.line_range"),
	-- 未来可以继续扩展 block / semantic 等
}

---创建新的协议解析器
---@return table 解析器对象
function M.new()
	-- 返回第一个策略的解析器（目前是 line_range）
	return strategies[1].new()
end

---快速解析（非流式，用于完整 chunk）
---@param chunk string
---@return table|nil
function M.parse(chunk)
	if not chunk or chunk == "" then
		return nil
	end

	for _, s in ipairs(strategies) do
		local result = s.match(chunk)
		if result then
			return result
		end
	end
	return nil
end

return M
