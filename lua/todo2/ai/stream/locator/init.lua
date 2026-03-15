local M = {}

local strategies = {
	line_range = require("todo2.ai.stream.locator.line_range"),
	-- block = require("todo2.ai.stream.locator.block"),
}

function M.locate(protocol, ctx)
	local s = strategies[protocol.mode]
	if not s then
		return nil, "未知定位模式: " .. tostring(protocol.mode)
	end
	return s.locate(protocol, ctx)
end

return M
