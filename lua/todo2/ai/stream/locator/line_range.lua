-- 行号定位：直接使用协议中的 start/end
local M = {}

function M.locate(protocol, ctx)
	return {
		start_line = protocol.start_line,
		end_line = protocol.end_line,
	}
end

return M
