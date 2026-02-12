-- lua/todo2/store/utils.lua

local M = {}

--- 格式化时间戳为 YYYY-MM-DD HH:MM:SS
--- @param timestamp number
--- @return string
function M.format_time(timestamp)
	return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

-- ⭐ 用户要求保留的函数
--- 生成唯一 ID（6位十六进制）
--- @return string
function M.generate_id()
	return string.format("%06x", math.random(0, 0xFFFFFF))
end

return M
