-- lua/todo2/store/consistency.lua
--- @module todo2.store.consistency
--- 一致性检查

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification")
local lifecycle = require("todo2.store.link_lifecycle")
local id_utils = require("todo2.utils.id")
local config = require("todo2.config")

---------------------------------------------------------------------
-- ⭐ 修改：检查TODO文件内容与存储状态是否一致
---------------------------------------------------------------------
local function check_todo_file_content(todo_link)
	local result = {
		consistent = true,
		file_status = nil,
		expected_status = nil,
		reason = nil,
		region = "main",
	}

	if vim.fn.filereadable(todo_link.path) ~= 1 then
		result.consistent = false
		result.reason = "文件不存在"
		return result
	end

	local lines = vim.fn.readfile(todo_link.path)
	if not lines or #lines == 0 then
		result.consistent = false
		result.reason = "文件为空"
		return result
	end

	if todo_link.line < 1 or todo_link.line > #lines then
		result.consistent = false
		result.reason = string.format("行号%d超出范围", todo_link.line)
		return result
	end

	local line = lines[todo_link.line]
	if not line then
		result.consistent = false
		result.reason = "无法读取行内容"
		return result
	end

	if not id_utils.contains_todo_anchor(line) or id_utils.extract_id_from_todo_anchor(line) ~= todo_link.id then
		result.consistent = false
		result.reason = "行内容不包含链接ID"
		return result
	end

	local checkbox = line:match("%[(.)%]")
	if not checkbox then
		return result
	end

	local full_checkbox = "[" .. checkbox .. "]"

	if full_checkbox == "[ ]" then
		result.file_status = types.STATUS.NORMAL
		result.expected_status = types.STATUS.NORMAL
	elseif full_checkbox == "[x]" then
		result.file_status = types.STATUS.COMPLETED
		result.expected_status = types.STATUS.COMPLETED
	elseif full_checkbox == "[>]" then
		result.file_status = types.STATUS.ARCHIVED
		result.expected_status = types.STATUS.ARCHIVED
	else
		return result
	end

	-- ⭐ 使用配置函数判断归档区域
	for i = 1, todo_link.line do
		if lines[i] and config.is_archive_section_line(lines[i]) then
			result.region = "archive"
			break
		end
	end

	return result
end

local function execute_repair(id, action)
	if not action then
		return false
	end

	local todo_link = store.get_key("todo.links.todo." .. id)
	if not todo_link then
		return false
	end

	local core_status = require("todo2.core.status")

	if action.type == "sync_status" then
		if not core_status.is_allowed(todo_link.status, action.target) then
			vim.notify(
				string.format("跳过非法状态流转: %s → %s", todo_link.status, action.target),
				vim.log.levels.WARN
			)
			return false
		end

		if types.is_active_status(todo_link.status) and action.target == types.STATUS.COMPLETED then
			todo_link.previous_status = todo_link.status
		end

		todo_link.status = action.target
		todo_link.updated_at = os.time()

		if action.target == types.STATUS.COMPLETED then
			todo_link.completed_at = os.time()
		elseif action.target == types.STATUS.ARCHIVED then
			todo_link.archived_at = os.time()
		end

		store.set_key("todo.links.todo." .. id, todo_link)

		local events = require("todo2.core.events")
		if events then
			events.on_state_changed({
				source = "consistency_repair",
				ids = { id },
				file = todo_link.path,
			})
		end
		return true
	elseif action.type == "convert_checkbox" then
		local lines = vim.fn.readfile(todo_link.path)
		if not lines or #lines == 0 or todo_link.line > #lines then
			return false
		end

		local line = lines[todo_link.line]
		if not line then
			return false
		end

		local new_line = line:gsub("%[" .. action.from:sub(2, 2) .. "%]", "[" .. action.to:sub(2, 2) .. "]")
		lines[todo_link.line] = new_line
		vim.fn.writefile(lines, todo_link.path)

		if action.to == "[>]" then
			if todo_link.status == types.STATUS.COMPLETED then
				todo_link.previous_status = todo_link.previous_status or types.STATUS.NORMAL
			end
			todo_link.status = types.STATUS.ARCHIVED
			todo_link.archived_at = os.time()
		elseif action.to == "[x]" then
			if types.is_active_status(todo_link.status) then
				todo_link.previous_status = todo_link.status
			end
			todo_link.status = types.STATUS.COMPLETED
			todo_link.completed_at = os.time()
		end
		todo_link.updated_at = os.time()
		store.set_key("todo.links.todo." .. id, todo_link)

		local events = require("todo2.core.events")
		if events then
			events.on_state_changed({
				source = "consistency_repair",
				ids = { id },
				file = todo_link.path,
			})
		end
		return true
	end

	return false
end

function M.check_link_pair_consistency(id)
	local todo_link = store.get_key("todo.links.todo." .. id)
	local code_link = store.get_key("todo.links.code." .. id)

	local consistent, diff = lifecycle.check_pair_consistency(todo_link, code_link)

	return {
		id = id,
		has_todo = todo_link ~= nil,
		has_code = code_link ~= nil,
		consistent = consistent,
		details = diff,
	}
end

function M.verify_archive_consistency(id)
	local snapshot = link.get_archive_snapshot(id)
	local todo_link = link.get_todo(id, { verify_line = true })
	local core_status = require("todo2.core.status")

	if todo_link then
		todo_link = verification.calibrate_link_active_status(todo_link)
	end

	local result = {
		id = id,
		consistent = true,
		issues = {},
		has_snapshot = snapshot ~= nil,
		has_todo = todo_link ~= nil,
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

	if todo_link then
		if todo_link.status ~= types.STATUS.ARCHIVED then
			local allowed = core_status.is_transition_allowed(snapshot.todo.status, todo_link.status)
			if not allowed then
				result.consistent = false
				table.insert(
					result.issues,
					string.format("非法状态流转: %s → %s", snapshot.todo.status, todo_link.status)
				)
			end
		end
	end

	if snapshot.todo and snapshot.todo.status then
		if not core_status.is_transition_allowed(snapshot.todo.status, types.STATUS.ARCHIVED) then
			result.consistent = false
			table.insert(result.issues, string.format("归档前状态 %s 不能直接归档", snapshot.todo.status))
		end
	end

	if #result.issues > 0 then
		result.summary = string.format("发现 %d 个问题: %s", #result.issues, table.concat(result.issues, "; "))
	else
		result.summary = "归档状态一致"
	end

	return result
end

function M.check_all_pairs()
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local report = {
		total_checked = 0,
		consistent_pairs = 0,
		inconsistent_pairs = 0,
		missing_todo = 0,
		missing_code = 0,
		archive_issues = 0,
		active_inconsistent = 0,
		deleted_inconsistent = 0,
		details = {},
	}

	local all_ids = {}
	for id, _ in pairs(all_todo) do
		all_ids[id] = true
	end
	for id, _ in pairs(all_code) do
		all_ids[id] = true
	end

	for id, _ in pairs(all_ids) do
		report.total_checked = report.total_checked + 1

		local result = M.check_link_pair_consistency(id)
		table.insert(report.details, result)

		if not result.has_todo then
			report.missing_todo = report.missing_todo + 1
		elseif not result.has_code then
			report.missing_code = report.missing_code + 1
		elseif result.consistent then
			report.consistent_pairs = report.consistent_pairs + 1
		else
			report.inconsistent_pairs = report.inconsistent_pairs + 1
			if result.details and result.details.message then
				if result.details.message:find("删除") then
					report.deleted_inconsistent = report.deleted_inconsistent + 1
				elseif result.details.message:find("活跃") then
					report.active_inconsistent = report.active_inconsistent + 1
				end
			end
		end

		local archive_check = M.verify_archive_consistency(id)
		if not archive_check.consistent then
			report.archive_issues = report.archive_issues + 1
		end
	end

	report.summary = string.format(
		"一致性检查完成: 检查了 %d 个链接对，一致: %d，不一致: %d (活跃: %d, 删除: %d)，缺少TODO: %d，缺少代码: %d，归档问题: %d",
		report.total_checked,
		report.consistent_pairs,
		report.inconsistent_pairs,
		report.active_inconsistent,
		report.deleted_inconsistent,
		report.missing_todo,
		report.missing_code,
		report.archive_issues
	)

	return report
end

function M.repair_link_pair(id, strategy)
	strategy = strategy or "latest"

	local todo_key = "todo.links.todo." .. id
	local code_key = "todo.links.code." .. id

	local todo_link = store.get_key(todo_key)
	local code_link = store.get_key(code_key)

	if not todo_link or not code_link then
		return {
			repaired = false,
			message = "缺少链接，无法修复",
		}
	end

	todo_link = verification.calibrate_link_active_status(todo_link)
	code_link = verification.calibrate_link_active_status(code_link)

	local primary, secondary
	if strategy == "todo_first" then
		primary, secondary = todo_link, code_link
	else
		if (todo_link.updated_at or 0) >= (code_link.updated_at or 0) then
			primary, secondary = todo_link, code_link
		else
			primary, secondary = code_link, todo_link
		end
	end

	local changes = {}

	if secondary.status ~= primary.status then
		secondary.status = primary.status
		table.insert(changes, "状态")
	end

	if secondary.active ~= primary.active then
		secondary.active = primary.active
		table.insert(changes, "活跃状态")
	end

	if secondary.deleted_at ~= primary.deleted_at then
		secondary.deleted_at = primary.deleted_at
		table.insert(changes, "删除状态")
	end

	if #changes > 0 then
		secondary.updated_at = os.time()

		if secondary.type == "todo_to_code" then
			store.set_key(todo_key, secondary)
		else
			store.set_key(code_key, secondary)
		end

		return {
			repaired = true,
			message = "已修复: " .. table.concat(changes, ", "),
			changes = changes,
		}
	end

	return {
		repaired = false,
		message = "无需修复",
	}
end

function M.validate_todo_status(id)
	local todo_link = store.get_key("todo.links.todo." .. id)
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
		note = nil,
	}

	if not file_check.consistent then
		result.needs_repair = false
		return result
	end

	if not file_check.file_status then
		return result
	end

	local core_status = require("todo2.core.status")

	if file_check.region == "archive" then
		if todo_link.status ~= types.STATUS.ARCHIVED then
			result.consistent = false
			result.needs_repair = true

			if todo_link.status == types.STATUS.COMPLETED then
				result.repair_action = {
					type = "sync_status",
					target = types.STATUS.ARCHIVED,
					reason = "归档区域中的完成任务应转为archived",
				}
			else
				result.repair_action = {
					type = "sync_status",
					target = types.STATUS.COMPLETED,
					reason = "归档区域中的任务应先完成",
				}
				result.note = "任务已在归档区域，请先标记完成"
			end
		end

		if file_check.file_status == types.STATUS.COMPLETED then
			result.consistent = false
			result.needs_repair = true
			result.repair_action = {
				type = "convert_checkbox",
				from = "[x]",
				to = "[>]",
				reason = "归档区域中的完成任务应转为[>]",
			}
		end
	else
		if file_check.file_status ~= todo_link.status then
			if core_status.is_allowed(todo_link.status, file_check.file_status) then
				result.consistent = false
				result.needs_repair = true
				result.repair_action = {
					type = "sync_status",
					target = file_check.file_status,
					reason = string.format(
						"复选框与存储状态不一致: 文件=%s, 存储=%s",
						file_check.file_status,
						todo_link.status
					),
				}
			else
				result.consistent = false
				result.needs_repair = false
				result.note = string.format("非法状态流转: %s → %s", todo_link.status, file_check.file_status)
			end
		end

		if file_check.file_status == types.STATUS.ARCHIVED then
			result.consistent = false
			result.needs_repair = true
			result.repair_action = {
				type = "convert_checkbox",
				from = "[>]",
				to = "[x]",
				reason = "主区域中的归档任务应转为[x]",
			}
		end
	end

	return result
end

function M.repair_todo_status(id, action)
	return execute_repair(id, action)
end

function M.fix_inconsistent_status(opts)
	opts = opts or {}
	local dry_run = opts.dry_run or false
	local verbose = opts.verbose or false

	local all_todo = link.get_all_todo()
	local report = {
		checked = 0,
		fixed = 0,
		skipped = 0,
		details = {},
	}

	for id, _ in pairs(all_todo) do
		report.checked = report.checked + 1

		local result = M.validate_todo_status(id)

		if result.needs_repair and result.repair_action then
			if verbose then
				vim.notify(
					string.format("发现不一致: %s - %s", id:sub(1, 6), result.repair_action.reason),
					vim.log.levels.INFO
				)
			end

			table.insert(report.details, {
				id = id,
				action = result.repair_action,
				file_status = result.file_status,
				stored_status = result.stored_status,
				region = result.region,
				note = result.note,
			})

			if not dry_run then
				local success = execute_repair(id, result.repair_action)
				if success then
					report.fixed = report.fixed + 1
				end
			else
				report.fixed = report.fixed + 1
			end
		else
			report.skipped = report.skipped + 1
		end
	end

	report.summary = string.format(
		"检查 %d 个TODO链接，发现 %d 个不一致，%s %d 个",
		report.checked,
		report.fixed,
		dry_run and "将修复" or "已修复",
		report.fixed
	)

	return report
end

return M
