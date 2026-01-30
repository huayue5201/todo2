-- lua/todo2/utils/time.lua
--- @module todo2.utils.time
--- @brief 时间处理工具模块

local M = {}

---------------------------------------------------------------------
-- 格式化时间戳为 YYYY/MM/DD/HH:MM
---------------------------------------------------------------------
function M.format_compact(timestamp)
	if not timestamp or timestamp == 0 then
		return ""
	end
	return os.date("%Y/%m/%d/%H:%M", timestamp)
end

---------------------------------------------------------------------
-- 智能格式化时间（相对时间）
---------------------------------------------------------------------
function M.format_smart(timestamp)
	if not timestamp then
		return ""
	end

	local now = os.time()
	local diff = now - timestamp

	if diff < 60 then
		return "刚刚"
	elseif diff < 3600 then
		return string.format("%d分钟前", math.floor(diff / 60))
	elseif diff < 86400 then
		return string.format("%d小时前", math.floor(diff / 3600))
	elseif diff < 604800 then
		return string.format("%d天前", math.floor(diff / 86400))
	else
		return M.format_compact(timestamp)
	end
end

---------------------------------------------------------------------
-- 获取任务应显示的时间戳
---------------------------------------------------------------------
function M.get_display_timestamp(link)
	if not link then
		return nil
	end

	-- 完成状态显示完成时间，其他状态显示创建时间
	if link.status == "completed" and link.completed_at then
		return link.completed_at
	else
		return link.created_at
	end
end

---------------------------------------------------------------------
-- 获取时间显示文本
---------------------------------------------------------------------
function M.get_time_display(link, format)
	local timestamp = M.get_display_timestamp(link)
	if not timestamp then
		return ""
	end

	if format == "compact" then
		return M.format_compact(timestamp)
	elseif format == "smart" then
		return M.format_smart(timestamp)
	else
		-- 默认显示完整格式
		return M.format_compact(timestamp)
	end
end

return M
