-- lua/todo2/utils/time.lua
--- @module todo2.utils.time
--- @brief 纯时间处理工具，不耦合业务状态

local M = {}

---------------------------------------------------------------------
-- 基础格式化
---------------------------------------------------------------------

--- 格式化为紧凑字符串 YYYY/MM/DD/HH:MM
--- @param timestamp number|nil
--- @return string
function M.format_compact(timestamp)
	if not timestamp or timestamp == 0 then
		return ""
	end
	return os.date("%Y/%m/%d/%H:%M", timestamp)
end

--- 智能相对时间格式
--- @param timestamp number
--- @return string
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
-- 业务相关：根据链接对象获取应显示的时间戳
-- 此函数虽与业务耦合，但作为工具模块的统一入口，保持简单
---------------------------------------------------------------------

--- 获取链接对象最适合显示的时间戳
--- 规则：
---   - 已归档：显示 archived_at
---   - 已完成：显示 completed_at
---   - 其他：显示 updated_at，若无则显示 created_at
--- @param link table 链接对象（必须包含 status 字段）
--- @return number|nil
function M.get_display_timestamp(link)
	if not link then
		return nil
	end

	-- 1. 归档状态优先显示归档时间
	if link.status == "archived" and link.archived_at then
		return link.archived_at
	end

	-- 2. 完成状态显示完成时间
	if link.status == "completed" and link.completed_at then
		return link.completed_at
	end

	-- 3. 其他状态：优先最后更新时间，否则创建时间
	return link.updated_at or link.created_at
end

--- 获取时间显示文本，支持不同格式
--- @param link table 链接对象
--- @param format string "compact"|"smart"|nil 默认 compact
--- @return string
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
		return M.format_compact(timestamp)
	end
end

return M
