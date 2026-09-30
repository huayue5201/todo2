-- lua/todo2/utils/async.lua
-- vim.async 便捷封装：统一本插件里重复出现的「延后一轮」与「防抖」模式。

local M = {}

local async = vim.async

--- 是否为任务取消（close）而非真正的失败
---@param err any
---@return boolean
local function is_cancel(err)
	return err == nil or tostring(err):find("closed", 1, true) ~= nil
end

--- 观测任务失败：忽略取消，其余错误显式报出。
--- 顶层任务是静默的，必须显式观测，否则异步失败会被吞掉。
--- on_complete 可能在快速上下文中触发，必须切回主循环再调 UI API。
---@param task vim.async.Task
---@return vim.async.Task
local function observe(task)
	task:on_complete(function(err)
		if is_cancel(err) then
			return
		end
		local message = tostring(err)
		vim.schedule(function()
			vim.notify("todo2 async: " .. message, vim.log.levels.ERROR)
		end)
	end)
	return task
end

--- 延后到下一轮事件循环执行（等价 vim.schedule，但运行在任务中、可取消）。
---@param fn fun()
---@return vim.async.Task
function M.defer(fn)
	return observe(async.run(function()
		async.sleep(0)
		fn()
	end))
end

--- 延迟 delay 毫秒后在任务中执行一次（一次性，非防抖）。
---@param delay integer
---@param fn fun()
---@return vim.async.Task
function M.delay(delay, fn)
	return observe(async.run(function()
		async.sleep(delay)
		fn()
	end))
end

--- 防抖：取消同一 key 上一轮尚未执行的任务，延迟 delay 毫秒后执行 fn。
---@param tasks table<string|number, vim.async.Task> 调用方持有的任务表
---@param key string|number 防抖键
---@param delay integer 延迟毫秒
---@param fn fun()
---@return vim.async.Task
function M.debounce(tasks, key, delay, fn)
	local prev = tasks[key]
	if prev then
		prev:close()
	end

	local task = observe(async.run(function()
		async.sleep(delay)
		tasks[key] = nil
		fn()
	end))
	tasks[key] = task
	return task
end

--- 取消并清除指定 key 的防抖任务
---@param tasks table<string|number, vim.async.Task>
---@param key string|number
function M.cancel(tasks, key)
	local task = tasks[key]
	if task then
		task:close()
		tasks[key] = nil
	end
end

return M
