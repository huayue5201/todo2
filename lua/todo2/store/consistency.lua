-- lua/todo2/store/consistency.lua
-- 适配新格式：使用内部格式检查状态一致性

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")
local types = require("todo2.store.types")
local id_utils = require("todo2.utils.id")
local core_status = require("todo2.core.status")
local archive_link = require("todo2.store.link.archive")

---------------------------------------------------------------------
-- 工具：统一读取文件行
---------------------------------------------------------------------
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

---------------------------------------------------------------------
-- 工具：判断某行是否包含 ID
---------------------------------------------------------------------
local function line_contains_id(line, id)
	if not line or not id then
		return false
	end
	if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
		return true
	end
	if id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id then
		return true
	end
	return false
end

---------------------------------------------------------------------
-- 从任务中获取TODO链接信息（用于兼容旧函数）
---------------------------------------------------------------------
local function get_todo_link_from_task(task)
	if not task or not task.locations.todo then
		return nil
	end

	return {
		id = task.id,
		path = task.locations.todo.path,
		line = task.locations.todo.line,
		content = task.core.content,
		tag = task.core.tags[1],
		status = task.core.status,
		previous_status = task.core.previous_status,
		created_at = task.timestamps.created,
		updated_at = task.timestamps.updated,
		completed_at = task.timestamps.completed,
		archived_at = task.timestamps.archived,
		archived_reason = task.timestamps.archived_reason,
	}
end

---------------------------------------------------------------------
-- 检查 TODO 文件内容是否与存储一致
---------------------------------------------------------------------
local function check_todo_file_content(task)
	local result = {
		consistent = true,
		file_status = nil,
		region = "main",
		reason = nil,
	}

	if not task or not task.locations.todo then
		result.consistent = false
		result.reason = "没有TODO位置"
		return result
	end

	local lines = read_lines(task.locations.todo.path)
	if #lines == 0 then
		result.consistent = false
		result.reason = "文件为空"
		return result
	end

	if task.locations.todo.line < 1 or task.locations.todo.line > #lines then
		result.consistent = false
		result.reason = "行号超出范围"
		return result
	end

	local line = lines[task.locations.todo.line]
	if not line or not line_contains_id(line, task.id) then
		result.consistent = false
		result.reason = "行内容不包含链接ID"
		return result
	end

	local checkbox = line:match("%[(.)%]")
	if checkbox == " " then
		result.file_status = types.STATUS.NORMAL
	elseif checkbox == "x" then
		result.file_status = types.STATUS.COMPLETED
	elseif checkbox == ">" then
		result.file_status = types.STATUS.ARCHIVED
	end

	-- 判断是否在归档区域
	for i = 1, task.locations.todo.line do
		local l = lines[i]
		if l:match("^#+%s*Archive") or l:match("^#+%s*归档") then
			result.region = "archive"
			break
		end
	end

	return result
end

---------------------------------------------------------------------
-- 修复 TODO 状态
---------------------------------------------------------------------
local function apply_status_repair(task, action)
	if not action or not action.type then
		return false
	end

	if action.type == "sync_status" then
		if not core_status.is_allowed(task.core.status, action.target) then
			return false
		end

		task.core.previous_status = task.core.status
		task.core.status = action.target
		task.timestamps.updated = os.time()

		if action.target == types.STATUS.COMPLETED then
			task.timestamps.completed = os.time()
		elseif action.target == types.STATUS.ARCHIVED then
			task.timestamps.archived = os.time()
		end

		return core.save_task(task.id, task)
	end

	if action.type == "convert_checkbox" then
		local lines = read_lines(task.locations.todo.path)
		local line = lines[task.locations.todo.line]
		if not line then
			return false
		end

		local new_line = line:gsub("%[" .. action.from:sub(2, 2) .. "%]", "[" .. action.to:sub(2, 2) .. "]")
		lines[task.locations.todo.line] = new_line
		vim.fn.writefile(lines, task.locations.todo.path)

		if action.to == "[x]" then
			task.core.previous_status = task.core.status
			task.core.status = types.STATUS.COMPLETED
			task.timestamps.completed = os.time()
		elseif action.to == "[>]" then
			task.core.previous_status = task.core.status
			task.core.status = types.STATUS.ARCHIVED
			task.timestamps.archived = os.time()
		end

		task.timestamps.updated = os.time()
		return core.save_task(task.id, task)
	end

	return false
end

---------------------------------------------------------------------
-- 归档快照一致性
---------------------------------------------------------------------
function M.verify_archive_consistency(id)
	local snapshot = archive_link.get_archive_snapshot(id)
	local task = core.get_task(id)

	local result = {
		id = id,
		consistent = true,
		issues = {},
	}

	if not snapshot then
		result.consistent = false
		table.insert(result.issues, "缺少归档快照")
		return result
	end

	if not snapshot.todo or not snapshot.todo.status then
		result.consistent = false
		table.insert(result.issues, "归档快照不完整")
	end

	if task and task.core.status ~= types.STATUS.ARCHIVED then
		local allowed = core_status.is_transition_allowed(snapshot.todo.status, task.core.status)
		if not allowed then
			result.consistent = false
			table.insert(
				result.issues,
				string.format("非法状态流转: %s → %s", snapshot.todo.status, task.core.status)
			)
		end
	end

	return result
end

---------------------------------------------------------------------
-- 校验 TODO 状态
---------------------------------------------------------------------
function M.validate_todo_status(id)
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		return { consistent = true }
	end

	local file_check = check_todo_file_content(task)

	local result = {
		consistent = file_check.consistent,
		file_status = file_check.file_status,
		stored_status = task.core.status,
		region = file_check.region,
		needs_repair = false,
		repair_action = nil,
	}

	if not file_check.consistent then
		return result
	end

	-- 归档区域：必须 archived，且复选框应为 [>]
	if file_check.region == "archive" then
		if task.core.status ~= types.STATUS.ARCHIVED then
			result.needs_repair = true
			result.repair_action = {
				type = "sync_status",
				target = types.STATUS.ARCHIVED,
				reason = "归档区域中的任务必须为 archived",
			}
			return result
		end

		if file_check.file_status == types.STATUS.COMPLETED then
			result.needs_repair = true
			result.repair_action = {
				type = "convert_checkbox",
				from = "[x]",
				to = "[>]",
				reason = "归档区域中的完成任务应转为 [>]",
			}
		end

		return result
	end

	-- 主区域：复选框 ↔ 存储状态不一致
	if file_check.file_status and file_check.file_status ~= task.core.status then
		if core_status.is_allowed(task.core.status, file_check.file_status) then
			result.needs_repair = true
			result.repair_action = {
				type = "sync_status",
				target = file_check.file_status,
				reason = "复选框与存储状态不一致",
			}
		end
	end

	return result
end

---------------------------------------------------------------------
-- 执行修复
---------------------------------------------------------------------
function M.repair_todo_status(id, action)
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		return false
	end
	return apply_status_repair(task, action)
end

---------------------------------------------------------------------
-- 新增：检查所有任务的一致性
---------------------------------------------------------------------
function M.check_all_todos()
	local query = require("todo2.store.link.query")
	local tasks = query.get_todo_tasks()
	local results = {}

	for id, _ in pairs(tasks) do
		results[id] = M.validate_todo_status(id)
	end

	return results
end

---------------------------------------------------------------------
-- 新增：修复所有不一致的任务
---------------------------------------------------------------------
function M.repair_all_todos()
	local results = M.check_all_todos()
	local repaired = 0

	for id, result in pairs(results) do
		if result.needs_repair and result.repair_action then
			if M.repair_todo_status(id, result.repair_action) then
				repaired = repaired + 1
			end
		end
	end

	return repaired
end

return M
