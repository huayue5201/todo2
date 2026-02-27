-- lua/todo2/store/consistency.lua
--- @module todo2.store.consistency
--- 一致性检查（修复版：添加状态校准）

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification")
local lifecycle = require("todo2.store.link_lifecycle")

---------------------------------------------------------------------
-- ⭐ 内部辅助函数（不暴露到M表）
---------------------------------------------------------------------

--- 检查TODO文件内容与存储状态是否一致
--- @param todo_link table TODO链接
--- @return table 检查结果 { consistent, file_status, expected_status, reason, region }
local function check_todo_file_content(todo_link)
	local result = {
		consistent = true,
		file_status = nil,
		expected_status = nil,
		reason = nil,
		region = "main",
	}

	-- 检查文件是否存在
	if vim.fn.filereadable(todo_link.path) ~= 1 then
		result.consistent = false
		result.reason = "文件不存在"
		return result
	end

	-- 读取文件内容
	local lines = vim.fn.readfile(todo_link.path)
	if not lines or #lines == 0 then
		result.consistent = false
		result.reason = "文件为空"
		return result
	end

	-- 检查行号是否有效
	if todo_link.line < 1 or todo_link.line > #lines then
		result.consistent = false
		result.reason = string.format("行号%d超出范围", todo_link.line)
		return result
	end

	-- 获取该行内容
	local line = lines[todo_link.line]
	if not line then
		result.consistent = false
		result.reason = "无法读取行内容"
		return result
	end

	-- 检查是否包含ID
	if not line:match("{%#" .. todo_link.id .. "%}") then
		result.consistent = false
		result.reason = "行内容不包含链接ID"
		return result
	end

	-- 提取复选框
	local checkbox = line:match("%[(.)%]")
	if not checkbox then
		-- 非任务行，跳过
		return result
	end

	local full_checkbox = "[" .. checkbox .. "]"

	-- 复选框 -> 状态映射
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
		-- [!] 和 [?] 由图标处理
		return result
	end

	-- 判断区域（简单判断）
	for i = 1, todo_link.line do
		if lines[i] and lines[i]:match("^## Archived %(%d%d%d%d%-%d%d%)") then
			result.region = "archive"
			break
		end
	end

	return result
end

--- 执行状态修复（带状态流转检查）
--- @param id string 链接ID
--- @param action table 修复动作
--- @return boolean 是否成功
local function execute_repair(id, action)
	if not action then
		return false
	end

	local todo_link = store.get_key("todo.links.todo." .. id)
	if not todo_link then
		return false
	end

	-- 获取状态流转规则
	local core_status = require("todo2.core.status")

	if action.type == "sync_status" then
		-- 检查状态流转是否允许
		if not core_status.is_allowed(todo_link.status, action.target) then
			vim.notify(
				string.format("跳过非法状态流转: %s → %s", todo_link.status, action.target),
				vim.log.levels.WARN
			)
			return false
		end

		-- 保护 previous_status：只有从活跃状态变为完成时才记录
		if types.is_active_status(todo_link.status) and action.target == types.STATUS.COMPLETED then
			todo_link.previous_status = todo_link.status
		end

		-- 更新存储状态
		todo_link.status = action.target
		todo_link.updated_at = os.time()

		-- 更新相关时间戳
		if action.target == types.STATUS.COMPLETED then
			todo_link.completed_at = os.time()
		elseif action.target == types.STATUS.ARCHIVED then
			todo_link.archived_at = os.time()
		end

		store.set_key("todo.links.todo." .. id, todo_link)

		-- 触发事件更新UI
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
		-- 转换复选框（需要修改文件）
		local lines = vim.fn.readfile(todo_link.path)
		if not lines or #lines == 0 or todo_link.line > #lines then
			return false
		end

		local line = lines[todo_link.line]
		if not line then
			return false
		end

		-- 替换复选框
		local new_line = line:gsub("%[" .. action.from:sub(2, 2) .. "%]", "[" .. action.to:sub(2, 2) .. "]")
		lines[todo_link.line] = new_line
		vim.fn.writefile(lines, todo_link.path)

		-- 更新存储状态并保护 previous_status
		if action.to == "[>]" then
			-- 转为归档状态：如果是完成状态转归档，记录 previous_status
			if todo_link.status == types.STATUS.COMPLETED then
				todo_link.previous_status = todo_link.previous_status or types.STATUS.NORMAL
			end
			todo_link.status = types.STATUS.ARCHIVED
			todo_link.archived_at = os.time()
		elseif action.to == "[x]" then
			-- 转为完成状态：记录 previous_status
			if types.is_active_status(todo_link.status) then
				todo_link.previous_status = todo_link.status
			end
			todo_link.status = types.STATUS.COMPLETED
			todo_link.completed_at = os.time()
		end
		todo_link.updated_at = os.time()
		store.set_key("todo.links.todo." .. id, todo_link)

		-- 触发事件
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

---------------------------------------------------------------------
-- 原有函数保持不变
---------------------------------------------------------------------

--- 检查链接对一致性
--- @param id string 链接ID
--- @return table 检查结果
function M.check_link_pair_consistency(id)
	-- 直接使用 lifecycle.check_pair_consistency
	local todo_link = store.get_key("todo.links.todo." .. id)
	local code_link = store.get_key("todo.links.code." .. id)

	local consistent, diff = lifecycle.check_pair_consistency(todo_link, code_link)

	-- 包装成需要的格式
	return {
		id = id,
		has_todo = todo_link ~= nil,
		has_code = code_link ~= nil,
		consistent = consistent,
		details = diff,
	}
end

-- ⭐ 验证归档状态一致性
function M.verify_archive_consistency(id)
	local snapshot = link.get_archive_snapshot(id)
	local todo_link = link.get_todo(id, { verify_line = true })
	local core_status = require("todo2.core.status")

	-- ⭐ 校准活跃状态
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

	-- 检查快照是否存在
	if not snapshot then
		result.consistent = false
		table.insert(result.issues, "缺少归档快照")
		return result
	end

	-- 检查快照完整性
	if not snapshot.todo or not snapshot.todo.status then
		result.consistent = false
		table.insert(result.issues, "归档快照不完整")
	end

	-- 如果任务存在，检查状态流转合法性
	if todo_link then
		-- 如果任务已恢复，检查是否符合状态流转
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

	-- 检查归档前状态的合法性
	if snapshot.todo and snapshot.todo.status then
		if not core_status.is_transition_allowed(snapshot.todo.status, types.STATUS.ARCHIVED) then
			result.consistent = false
			table.insert(result.issues, string.format("归档前状态 %s 不能直接归档", snapshot.todo.status))
		end
	end

	-- 生成摘要
	if #result.issues > 0 then
		result.summary = string.format("发现 %d 个问题: %s", #result.issues, table.concat(result.issues, "; "))
	else
		result.summary = "归档状态一致"
	end

	return result
end

--- 批量检查所有链接对的一致性
--- @return table 一致性报告
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

	-- 收集所有ID
	local all_ids = {}
	for id, _ in pairs(all_todo) do
		all_ids[id] = true
	end
	for id, _ in pairs(all_code) do
		all_ids[id] = true
	end

	-- 检查每个ID
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

		-- 检查归档状态
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

--- 修复链接对不一致
--- @param id string 链接ID
--- @param strategy string|nil 修复策略，"latest"或"todo_first"
--- @return table 修复结果
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

	-- ⭐ 校准活跃状态
	todo_link = verification.calibrate_link_active_status(todo_link)
	code_link = verification.calibrate_link_active_status(code_link)

	-- 确定主链接（根据策略）
	local primary, secondary
	if strategy == "todo_first" then
		primary, secondary = todo_link, code_link
	else
		-- 默认使用更新时间最新的
		if (todo_link.updated_at or 0) >= (code_link.updated_at or 0) then
			primary, secondary = todo_link, code_link
		else
			primary, secondary = code_link, todo_link
		end
	end

	local changes = {}

	-- 同步状态
	if secondary.status ~= primary.status then
		secondary.status = primary.status
		table.insert(changes, "状态")
	end

	-- ⭐ 同步活跃状态
	if secondary.active ~= primary.active then
		secondary.active = primary.active
		table.insert(changes, "活跃状态")
	end

	-- ⭐ 同步删除状态
	if secondary.deleted_at ~= primary.deleted_at then
		secondary.deleted_at = primary.deleted_at
		table.insert(changes, "删除状态")
	end

	-- 如果有变化，更新时间戳并保存
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

---------------------------------------------------------------------
-- ⭐ 核心校验函数（文件复选框 vs 存储状态）
---------------------------------------------------------------------
--- 校验TODO端状态一致性
--- @param id string 链接ID
--- @return table 校验结果 { consistent, needs_repair, repair_action, file_status, stored_status, region, note }
function M.validate_todo_status(id)
	local todo_link = store.get_key("todo.links.todo." .. id)
	if not todo_link then
		return { consistent = true } -- 没有TODO端，跳过
	end

	-- 使用内部函数检查文件内容
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

	-- 如果文件检查已经不一致，直接返回
	if not file_check.consistent then
		result.needs_repair = false -- 文件问题不自动修复
		return result
	end

	-- 如果没有文件状态（非任务行），跳过
	if not file_check.file_status then
		return result
	end

	-- 获取状态流转规则
	local core_status = require("todo2.core.status")

	-- 核心校验规则
	if file_check.region == "archive" then
		-- 归档区域：必须为 archived 状态
		if todo_link.status ~= types.STATUS.ARCHIVED then
			result.consistent = false
			result.needs_repair = true

			-- 根据当前状态选择合法路径
			if todo_link.status == types.STATUS.COMPLETED then
				-- completed → archived 是允许的
				result.repair_action = {
					type = "sync_status",
					target = types.STATUS.ARCHIVED,
					reason = "归档区域中的完成任务应转为archived",
				}
			else
				-- 其他状态不能直接到 archived
				-- 先转为 completed
				result.repair_action = {
					type = "sync_status",
					target = types.STATUS.COMPLETED,
					reason = "归档区域中的任务应先完成",
				}
				result.note = "任务已在归档区域，请先标记完成"
			end
		end

		-- 归档区域中的 [x] 应转为 [>]
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
		-- 主区域：状态应与复选框一致
		if file_check.file_status ~= todo_link.status then
			-- 检查流转是否允许
			if core_status.is_allowed(todo_link.status, file_check.file_status) then
				result.consistent = false
				result.needs_repair = true
				result.repair_action = {
					type = "sync_status",
					from = todo_link.status,
					to = file_check.file_status,
					reason = string.format(
						"复选框与存储状态不一致: 文件=%s, 存储=%s",
						file_check.file_status,
						todo_link.status
					),
				}
			else
				-- 如果不允许，只报告不修复
				result.consistent = false
				result.needs_repair = false
				result.note = string.format("非法状态流转: %s → %s", todo_link.status, file_check.file_status)
			end
		end

		-- 主区域中的 [>] 应转为 [x]
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

---------------------------------------------------------------------
-- ⭐ 执行状态修复（对外接口）
---------------------------------------------------------------------
--- 执行状态修复
--- @param id string 链接ID
--- @param action table 修复动作（来自 validate_todo_status 返回的 repair_action）
--- @return boolean 是否成功
function M.repair_todo_status(id, action)
	return execute_repair(id, action)
end

---------------------------------------------------------------------
-- ⭐ 批量检查和修复状态不一致
---------------------------------------------------------------------
--- 批量检查和修复状态不一致
--- @param opts table|nil { dry_run: boolean, verbose: boolean }
--- @return table 修复报告
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

		-- 校验状态
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
				report.fixed = report.fixed + 1 -- 试运行也算作将修复
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
