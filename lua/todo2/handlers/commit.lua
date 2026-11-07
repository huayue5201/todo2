-- lua/todo2/handlers/commit.lua
-- 写回尾巴：store 已经改完 → 重写 TODO 文件行 → 刷新渲染 → 发事件。
--
-- 日期 / 标签 / 关系三个 handler 原本各抄一遍「rewrite → line_refresh → emit」，
-- 任何一步顺序写错都会造成「store 变了、文件没变」或「渲染没跟」。统一走这里。

local M = {}

local task_line = require("todo2.utils.task_line")
local line_refresh = require("todo2.render.line_refresh")

---@param id string
---@param event string|nil 事件名；nil 表示不发事件
---@return boolean ok
---@return string|nil err
function M.after_write(id, event)
	local ok, err = task_line.rewrite(id)
	if not ok then
		return false, err
	end

	if event then
		local ok_emit = pcall(function()
			require("todo2.core.events").emit(event, { changed_ids = { id } })
		end)
		if ok_emit then
			return true
		end
	end

	-- 没有事件（或事件派发失败）时不会触发调度器刷新，这里退化为逐行重绘。
	line_refresh.task_line(id)
	return true
end

return M
