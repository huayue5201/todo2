-- lua/todo2/store/consistency.lua
-- 重写版：统一 scheduler + id_utils + link 中心
-- 保留旧接口，内部逻辑完全简化

local M = {}

local scheduler = require("todo2.render.scheduler")
local link_mod = require("todo2.store.link")
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
-- 检查 TODO 文件内容是否与存储一致（简化版）
---------------------------------------------------------------------
local function check_todo_file_content(todo_link)
	local result = {
		consistent = true,
		file_status = nil,
		region = "main",
		reason = nil,
	}

	local lines = read_lines(todo_link.path)
	if #lines == 0 then
		result.consistent = false
		result.reason = "文件为空"
		return result
	end

	if todo_link.line < 1 or todo_link.line > #lines then
		result.consistent = false
		result.reason = "行号超出范围"
		return result
	end

	local line = lines[todo_link.line]
	if not line or not line_contains_id(line, todo_link.id) then
		result.consistent = false
		result.reason = "行内容不包含链接ID"
		return result
	end

	-- 解析复选框
	local checkbox = line:match("%[(.)%]")
	if checkbox == " " then
		result.file_status = types.STATUS.NORMAL
	elseif checkbox == "x" then
		result.file_status = types.STATUS.COMPLETED
	elseif checkbox == ">" then
		result.file_status = types.STATUS.ARCHIVED
	end

	-- 判断是否在归档区域
	for i = 1, todo_link.line do
		if line:match("^#+%s*Archive") or line:match("^#+%s*归档") then
			result.region = "archive"
			break
		end
	end

	return result
end

---------------------------------------------------------------------
-- 修复 TODO 状态（统一走 link_mod.update_todo）
---------------------------------------------------------------------
local function apply_status_repair(id, todo_link, action)
	if not action or not action.type then
		return false
	end

	local updated = vim.deepcopy(todo_link)

	if action.type == "sync_status" then
		if not core_status.is_allowed(todo_link.status, action.target) then
			return false
		end

		updated.status = action.target
		updated.updated_at = os.time()

		if action.target == types.STATUS.COMPLETED then
			updated.completed_at = os.time()
		elseif action.target == types.STATUS.ARCHIVED then
			updated.archived_at = os.time()
		end

		return link_mod.update_todo(id, updated)
	end

	if action.type == "convert_checkbox" then
		-- 修改文件内容（scheduler 不负责写入，这里仍需 writefile）
		local lines = read_lines(todo_link.path)
		local line = lines[todo_link.line]
		if not line then
			return false
		end

		local new_line = line:gsub("%[" .. action.from:sub(2, 2) .. "%]", "[" .. action.to:sub(2, 2) .. "]")
		lines[todo_link.line] = new_line
		vim.fn.writefile(lines, todo_link.path)

		-- 同步状态
		if action.to == "[x]" then
			updated.status = types.STATUS.COMPLETED
			updated.completed_at = os.time()
		elseif action.to == "[>]" then
			updated.status = types.STATUS.ARCHIVED
			updated.archived_at = os.time()
		end

		updated.updated_at = os.time()
		return link_mod.update_todo(id, updated)
	end

	return false
end

---------------------------------------------------------------------
-- 归档快照一致性（保留旧接口）
---------------------------------------------------------------------
function M.verify_archive_consistency(id)
	local snapshot = archive_link.get_archive_snapshot(id)
	local todo_link = link_mod.get_todo(id )

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

	if todo_link and todo_link.status ~= types.STATUS.ARCHIVED then
		local allowed = core_status.is_transition_allowed(snapshot.todo.status, todo_link.status)
		if not allowed then
			result.consistent = false
			table.insert(
				result.issues,
				string.format("非法状态流转: %s → %s", snapshot.todo.status, todo_link.status)
			)
		end
	end

	return result
end

---------------------------------------------------------------------
-- 校验 TODO 状态（文件 ↔ 存储）
---------------------------------------------------------------------
function M.validate_todo_status(id)
	local todo_link = link_mod.get_todo(id)
	if not todo_link then
		return { consistent = true }
	end

	local file_check = check_todo_file_content(todo_link)

	local result = {
		consistent = file_check.consistent,
		file_status = file_check.file_status,
		stored_status = todo_link.status,
		region = file_check.region,
		needs_repair = false,
		repair_action = nil,
	}

	if not file_check.consistent then
		return result
	end

	-- 归档区域
	if file_check.region == "archive" then
		if todo_link.status ~= types.STATUS.ARCHIVED then
			result.needs_repair = true
			result.repair_action = {
				type = "sync_status",
				target = types.STATUS.ARCHIVED,
				reason = "归档区域中的任务必须为 archived",
			}
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
	if file_check.file_status ~= todo_link.status then
		if core_status.is_allowed(todo_link.status, file_check.file_status) then
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
-- 执行修复（统一走 link_mod.update_todo）
---------------------------------------------------------------------
function M.repair_todo_status(id, action)
	local todo_link = link_mod.get_todo(id)
	if not todo_link then
		return false
	end
	return apply_status_repair(id, todo_link, action)
end

return M
