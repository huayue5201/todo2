-- lua/todo2/store/link/handler.lua
-- 事件处理器：处理定位结果并更新存储
-- 这是新的事件驱动方式的处理器，与旧版locate_task并存

local M = {}
local core = require("todo2.store.link.core")

-- 确保不重复注册
local registered = false

---处理定位结果事件
---@param data { link: table, located: { line: number } } 事件数据
function M.handle_location_found(data)
	if not data or not data.link or not data.located then
		return
	end

	local link = data.link
	local located = data.located

	local task = core.get_task(link.id)
	if not task then
		return
	end

	-- 更新任务位置
	if link.type == "todo_to_code" and task.locations.todo then
		task.locations.todo.line = located.line
		task.verification.line_verified = true
		task.verification.last_verified_at = os.time()
		task.timestamps.updated = os.time()
		core.save_task(link.id, task)
		vim.notify(string.format("[todo2] Updated todo location for task %s", link.id), vim.log.levels.INFO)
	elseif link.type == "code_to_todo" and task.locations.code then
		task.locations.code.line = located.line
		task.verification.line_verified = true
		task.verification.last_verified_at = os.time()
		task.timestamps.updated = os.time()
		core.save_task(link.id, task)
		vim.notify(string.format("[todo2] Updated code location for task %s", link.id), vim.log.levels.INFO)
	end
end

---初始化事件监听
function M.setup()
	if registered then
		return
	end

	local ok, events = pcall(require, "todo2.core.events")
	if ok and events then
		events.on("task_location_found", M.handle_location_found)
		registered = true
		vim.notify("[todo2] Location handler registered", vim.log.levels.DEBUG)
	else
		vim.notify("[todo2] Events module not found, location handler not registered", vim.log.levels.WARN)
	end
end

-- 自动设置
M.setup()

return M
