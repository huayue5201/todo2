-- lua/todo2/store/utils.lua

local M = {}

--- 格式化时间戳为 YYYY-MM-DD HH:MM:SS
--- @param timestamp number
--- @return string
function M.format_time(timestamp)
	return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

return M
