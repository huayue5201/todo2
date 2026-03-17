-- lua/todo2/ai/stream/protocol/line_range.lua
local M = {}

function M.match(buffer)
	if not buffer or buffer == "" then
		return nil
	end

	-- 先尝试标准格式
	local start_line = buffer:match("start:%s*(%d+)")
	local end_line = buffer:match("end:%s*(%d+)")

	if start_line and end_line then
		return {
			type = "replace",
			mode = "line_range",
			start_line = tonumber(start_line),
			end_line = tonumber(end_line),
		}
	end

	-- 如果标准格式失败，尝试宽松匹配
	local s = buffer:match("start(%d+)") or buffer:match("start[^%d]*(%d+)")
	local e = buffer:match("end(%d+)") or buffer:match("end[^%d]*(%d+)")

	if s and e then
		return {
			type = "replace",
			mode = "line_range",
			start_line = tonumber(s),
			end_line = tonumber(e),
		}
	end

	return nil
end

return M
