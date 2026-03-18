-- lua/todo2/store/consistency.lua
-- 一致性检查：统一API，旧函数转发到新实现

---@module "todo2.store.consistency"

local M = {}

local scheduler = require("todo2.render.scheduler")
local core = require("todo2.store.link.core")
local types = require("todo2.store.types")
local id_utils = require("todo2.utils.id")
local core_status = require("todo2.core.status")
local archive_link = require("todo2.store.link.archive")

-- 警告记录
local warned = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---读取文件行
---@param filepath string 文件路径
---@return string[] 行数组
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

---判断行是否包含指定ID
---@param line string 行内容
---@param id string 任务ID
---@return boolean
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

---从任务对象获取TODO链接信息
---@param task table 任务对象
---@return table? 链接信息
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

---检查TODO文件内容与存储的一致性
---@param task table 任务对象
---@return { consistent: boolean, file_status: string?, region: string, reason: string? }
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

	for i = 1, task.locations.todo.line do
		local l = lines[i]
		if l:match("^#+%s*Archive") or l:match("^#+%s*归档") then
			result.region = "archive"
			break
		end
	end

	return result
end

---应用状态修复
---@param task table 任务对象
---@param action { type: string, target?: string, from?: string, to?: string, reason?: string }
---@return boolean 修复是否成功
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
-- ⭐ 核心实现（唯一）
---------------------------------------------------------------------

---验证归档快照完整性（内部实现）
---@param id string 任务ID
---@return { id: string, consistent: boolean, issues: string[], has_relations: boolean, children_checked: number, version: number }
local function verify_archive_consistency_impl(id)
	local snapshot = archive_link.get_archive_snapshot(id)
	local task = core.get_task(id)
	local ok, relation = pcall(require, "todo2.store.link.relation")

	local result = {
		id = id,
		consistent = true,
		issues = {},
		has_relations = false,
		children_checked = 0,
		version = snapshot and snapshot.metadata and snapshot.metadata.version or 0,
	}

	if not snapshot then
		result.consistent = false
		table.insert(result.issues, "缺少归档快照")
		return result
	end

	if not snapshot.task then
		result.consistent = false
		table.insert(result.issues, "归档快照不完整")
	end

	if snapshot.relations then
		result.has_relations = true
	end

	if ok and snapshot.relations and snapshot.relations.child_ids then
		for _, child_id in ipairs(snapshot.relations.child_ids) do
			local child_snapshot = archive_link.get_archive_snapshot(child_id)
			if not child_snapshot then
				result.consistent = false
				table.insert(result.issues, string.format("子任务 %s 缺少快照", child_id))
			else
				result.children_checked = result.children_checked + 1
			end
		end
	end

	if task and task.core.status ~= types.STATUS.ARCHIVED then
		local allowed = core_status.is_transition_allowed(snapshot.task.status, task.core.status)
		if not allowed then
			result.consistent = false
			table.insert(
				result.issues,
				string.format("非法状态流转: %s → %s", snapshot.task.status, task.core.status)
			)
		end
	end

	return result
end

---升级旧格式快照（内部实现）
---@param id? string 可选，指定任务ID，不指定则升级所有
---@return number 升级的快照数量
local function upgrade_old_snapshots_impl(id)
	local upgraded = 0

	if id then
		local snapshot = archive_link.get_archive_snapshot(id)
		if snapshot and not snapshot.relations then
			local task = core.get_task(id)
			if task and task.relations then
				snapshot.relations = {
					parent_id = task.relations.parent_id,
					child_ids = task.relations.child_ids,
					level = task.relations.level,
				}
				snapshot.metadata = snapshot.metadata or {}
				snapshot.metadata.version = 5
				snapshot.metadata.has_relations = true
				archive_link.save_archive_snapshot(id, snapshot)
				upgraded = 1
			end
		end
	else
		local snapshots = archive_link.get_all_archive_snapshots()
		for _, snapshot in ipairs(snapshots) do
			if not snapshot.relations then
				local task = core.get_task(snapshot.id)
				if task and task.relations then
					snapshot.relations = {
						parent_id = task.relations.parent_id,
						child_ids = task.relations.child_ids,
						level = task.relations.level,
					}
					snapshot.metadata = snapshot.metadata or {}
					snapshot.metadata.version = 5
					snapshot.metadata.has_relations = true
					archive_link.save_archive_snapshot(snapshot.id, snapshot)
					upgraded = upgraded + 1
				end
			end
		end
	end

	return upgraded
end

---------------------------------------------------------------------
-- ⚠️ 旧API转发（带警告）
---------------------------------------------------------------------

---验证归档快照一致性
---@deprecated 此函数现在会检查子任务快照
---@param id string 任务ID
---@return table 验证结果
function M.verify_archive_consistency(id)
	if not warned.verify_archive_consistency then
		vim.notify("[todo2] verify_archive_consistency now checks child snapshots", vim.log.levels.WARN)
		warned.verify_archive_consistency = true
	end
	return verify_archive_consistency_impl(id)
end

---升级旧格式快照
---@deprecated 这是一次性迁移函数，仅在版本升级时使用
---@param id? string 可选，指定任务ID
---@return number 升级的快照数量
function M.upgrade_old_snapshots(id)
	if not warned.upgrade_old_snapshots then
		vim.notify("[todo2] upgrade_old_snapshots is a one-time migration function", vim.log.levels.WARN)
		warned.upgrade_old_snapshots = true
	end
	return upgrade_old_snapshots_impl(id)
end

---------------------------------------------------------------------
-- 公开API（已是最佳实践）
---------------------------------------------------------------------

---验证TODO任务状态
---@param id string 任务ID
---@return { consistent: boolean, file_status: string?, stored_status: string, region: string, needs_repair: boolean, repair_action: table? }
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

---修复TODO任务状态
---@param id string 任务ID
---@param action { type: string, target?: string, from?: string, to?: string, reason?: string } 修复动作
---@return boolean 修复是否成功
function M.repair_todo_status(id, action)
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		return false
	end
	return apply_status_repair(task, action)
end

---检查所有TODO任务的一致性
---@return table<string, table> 任务ID到验证结果的映射
function M.check_all_todos()
	local query = require("todo2.store.link.query")
	local tasks = query.get_todo_tasks()
	local results = {}

	for id, _ in pairs(tasks) do
		results[id] = M.validate_todo_status(id)
	end

	return results
end

---修复所有不一致的TODO任务
---@return number 修复的任务数量
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

---检查所有归档任务的一致性
---@return { total: number, consistent: number, inconsistent: number, missing_relations: number, details: table<string, table> }
function M.check_all_archived()
	local snapshots = archive_link.get_all_archive_snapshots()
	local results = {
		total = #snapshots,
		consistent = 0,
		inconsistent = 0,
		missing_relations = 0,
		details = {},
	}

	for _, snapshot in ipairs(snapshots) do
		local check = M.verify_archive_consistency(snapshot.id)
		if check.consistent then
			results.consistent = results.consistent + 1
		else
			results.inconsistent = results.inconsistent + 1
		end

		if not check.has_relations then
			results.missing_relations = results.missing_relations + 1
		end

		results.details[snapshot.id] = check
	end

	return results
end

return M
