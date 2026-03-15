-- 解析：REPLACE 10-20:
local M = {}

function M.match(buffer)
	if not buffer or buffer == "" then
		return nil
	end
	local compact = buffer:gsub("%s+", "")
	local s, e = compact:match("REPLACE(%d+)%-(%d+):?")
	if not s then
		return nil
	end
	return {
		type = "replace",
		mode = "line_range",
		start_line = tonumber(s),
		end_line = tonumber(e),
	}
end

return M
