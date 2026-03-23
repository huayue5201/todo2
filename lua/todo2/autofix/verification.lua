-- lua/todo2/autofix/verification.lua
-- 验证模块：调用 locator 获取修复建议，执行存储更新

local M = {}
local locator = require("todo2.autofix.locator")
local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- TODO 行验证
---------------------------------------------------------------------

--- 验证 TODO 行与存储状态是否一致
---@param line string TODO行内容
---@param stored_status string 存储中的状态
---@return boolean ok 是否一致
---@return string err 错误信息（ok 为 false 时有值）
local function validate_todo_line(line, stored_status)
	local checkbox = line:match("%[(.)%]")
	if not checkbox then
		return false, "不是有效的任务行"
	end

	local full_checkbox = "[" .. checkbox .. "]"

	if full_checkbox == "[ ]" or full_checkbox == "[x]" or full_checkbox == "[>]" then
		local line_status = types.checkbox_to_status(full_checkbox)
		if line_status ~= stored_status then
			return false,
				string.format("状态不一致: 文件显示 %s, 存储记录为 %s", line_status, stored_status)
		end
		return true, ""
	end

	return true, ""
end

--- 修复 TODO 行状态不一致
---@param task table 任务对象
---@param line string TODO行内容
---@return boolean success 是否修复成功
local function fix_todo_status(task, line)
	local checkbox = line:match("%[(.)%]")
	if not checkbox then
		return false
	end

	local full_checkbox = "[" .. checkbox .. "]"
	local line_status = types.checkbox_to_status(full_checkbox)

	if line_status ~= task.core.status then
		core.update_status(task.id, line_status)
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 私有函数：执行修复建议
---------------------------------------------------------------------

--- 执行修复建议
---@param task table 任务对象
---@param location_type "todo"|"code"
---@param result table locator 返回的修复建议
---@return boolean success 是否成功
---@return boolean updated 是否更新了数据
local function apply_fix(task, location_type, result)
	if not task or not result then
		return false, false
	end

	local location = task.locations[location_type]
	if not location then
		return false, false
	end

	if result.action == "no_change" then
		return true, false
	elseif result.action == "update_context" then
		if location.context and result.block then
			location.context.code_block_info = result.block
			task.timestamps.updated = os.time()
			core.save_task(task.id, task)
			return true, true
		end
		return true, false
	elseif result.action == "update_location" then
		location.line = result.new_line
		if result.block and location.context then
			location.context.code_block_info = result.block
		end
		task.verified = true
		task.timestamps.updated = os.time()
		core.save_task(task.id, task)
		return true, true
	elseif result.action == "relocate" then
		location.line = result.new_line
		if result.new_block and location.context then
			location.context.code_block_info = result.new_block
		end
		task.verified = true
		task.timestamps.updated = os.time()
		core.save_task(task.id, task)
		return true, true
	elseif result.action == "restore_mark" then
		task.has_missing_mark = true
		task.missing_mark_line = result.line
		task.missing_mark_block = result.block
		task.timestamps.updated = os.time()
		core.save_task(task.id, task)
		return true, true
	elseif result.action == "mark_orphaned" then
		task.orphaned = true
		task.orphaned_reason = result.reason
		task.orphaned_at = os.time()
		task.timestamps.updated = os.time()
		core.save_task(task.id, task)
		return true, true
	elseif result.action == "delete_task" then
		core.delete_task(task.id)
		return true, true
	end

	return false, false
end

---------------------------------------------------------------------
-- 公开 API
---------------------------------------------------------------------

--- 验证并更新单个任务
---@param task_id string 任务ID
---@param location_type "todo"|"code"
---@return boolean success 是否成功
---@return boolean updated 是否更新了数据
function M.verify_and_update(task_id, location_type)
	local task = core.get_task(task_id)
	if not task then
		return false, false
	end

	local location = task.locations[location_type]
	if not location then
		return false, false
	end

	if task.core.status == types.STATUS.ARCHIVED then
		return true, false
	end

	-- TODO 类型：额外验证 checkbox 状态
	if location_type == "todo" then
		local lines = vim.fn.readfile(location.path) or {}
		if lines and lines[location.line] then
			local ok, _ = validate_todo_line(lines[location.line], task.core.status)
			if not ok then
				fix_todo_status(task, lines[location.line])
				task = core.get_task(task_id)
				if not task then
					return false, false
				end
			end
		end
	end

	-- 调用 locator 获取修复建议
	local result = locator.locate(task, location_type)
	if not result or result.action == "error" then
		return false, false
	end

	return apply_fix(task, location_type, result)
end

--- 异步验证并更新单个任务
---@param task_id string
---@param location_type "todo"|"code"
---@param callback fun(success:boolean, updated:boolean)
function M.verify_and_update_async(task_id, location_type, callback)
	vim.schedule(function()
		local success, updated = M.verify_and_update(task_id, location_type)
		if callback then
			callback(success, updated)
		end
	end)
end

--- 验证文件中的所有任务
---@param filepath string
---@param callback fun(results: table)
function M.verify_file(filepath, callback)
	local todo_tasks = index.find_todo_links_by_file(filepath)
	local code_tasks = index.find_code_links_by_file(filepath)

	local total = #todo_tasks + #code_tasks
	local results = {
		verified = {},
		updated = {},
		orphaned = {},
		deleted = {},
		failed = {},
	}
	local completed = 0

	if total == 0 then
		if callback then
			callback(results)
		end
		return
	end

	local function on_done(id, success, updated, was_deleted, was_orphaned)
		if not success then
			table.insert(results.failed, id)
		elseif was_deleted then
			table.insert(results.deleted, id)
		elseif was_orphaned then
			table.insert(results.orphaned, id)
		elseif updated then
			table.insert(results.updated, id)
		else
			table.insert(results.verified, id)
		end

		completed = completed + 1
		if completed >= total and callback then
			callback(results)
		end
	end

	for _, task in ipairs(todo_tasks) do
		local success, updated = M.verify_and_update(task.id, "todo")
		local after = core.get_task(task.id)
		on_done(task.id, success, updated, after == nil, after and after.orphaned == true)
	end

	for _, task in ipairs(code_tasks) do
		local success, updated = M.verify_and_update(task.id, "code")
		local after = core.get_task(task.id)
		on_done(task.id, success, updated, after == nil, after and after.orphaned == true)
	end
end

--- 清理过期的悬挂任务
---@param days number 保留天数
---@return number deleted 删除数量
function M.cleanup_orphaned(days)
	days = days or 30
	local cutoff = os.time() - (days * 86400)
	local all_tasks = require("todo2.store.link.query").get_all_tasks()
	local deleted = 0

	for id, task in pairs(all_tasks) do
		if task.orphaned and task.orphaned_at and task.orphaned_at < cutoff then
			core.delete_task(id)
			deleted = deleted + 1
		end
	end

	return deleted
end

return M
