-- lua/todo2/core/status.lua
-- 纯功能平移：使用新接口获取任务状态

local M = {}

local types = require("todo2.store.types")
local store = require("todo2.store")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local parser = require("todo2.core.parser")
local hash = require("todo2.utils.hash")
local utils = require("todo2.core.utils")
local core = require("todo2.store.link.core") -- 新增：引入 core

---------------------------------------------------------------------
-- 状态流转规则
---------------------------------------------------------------------
local STATUS_FLOW = {
	[types.STATUS.NORMAL] = {
		next = { types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.COMPLETED },
	},
	[types.STATUS.URGENT] = {
		next = { types.STATUS.NORMAL, types.STATUS.WAITING, types.STATUS.COMPLETED },
	},
	[types.STATUS.WAITING] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.COMPLETED },
	},
	[types.STATUS.COMPLETED] = {
		next = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING, types.STATUS.ARCHIVED },
	},
	[types.STATUS.ARCHIVED] = {
		next = { types.STATUS.COMPLETED },
	},
}

---------------------------------------------------------------------
-- 从任务构建兼容的 link 对象（内部使用）
---------------------------------------------------------------------
local function task_to_todo_link(task)
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
		completed_at = task.timestamps.completed,
		archived_at = task.timestamps.archived,
		archived_reason = task.timestamps.archived_reason,
	}
end

---------------------------------------------------------------------
-- 区域检测函数
---------------------------------------------------------------------

--- 检测任务所在的区域
--- @param id string 任务ID
--- @return string "main"|"archive"|"unknown"
function M._detect_task_region(id)
	local task = core.get_task(id)
	if not task or not task.locations.todo then
		return "unknown"
	end

	local bufnr = vim.fn.bufnr(task.locations.todo.path)
	if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return "unknown"
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local line = task.locations.todo.line

	for i = line, 1, -1 do
		if lines[i] and utils.is_archive_section_line(lines[i]) then
			return "archive"
		end
	end

	return "main"
end

--- 验证状态流转的区域限制
--- @param current string 当前状态
--- @param target string 目标状态
--- @param region string 任务区域
--- @return boolean, string
function M._validate_region_transition(current, target, region)
	if region == "archive" then
		if current == types.STATUS.ARCHIVED then
			if target == types.STATUS.COMPLETED or target == types.STATUS.ARCHIVED then
				return true, "允许"
			end
			return false, "归档区域的任务只能恢复到完成状态"
		else
			return false, "归档区域只能有ARCHIVED状态的任务"
		end
	end

	if region == "main" and target == types.STATUS.ARCHIVED then
		return false, "主区域的任务不能直接归档，请使用归档功能"
	end

	return true, "允许"
end

---------------------------------------------------------------------
-- 状态查询API
---------------------------------------------------------------------

--- 判断状态流转是否允许
--- @param current string 当前状态
--- @param target string 目标状态
--- @return boolean
function M.is_allowed(current, target)
	local flow = STATUS_FLOW[current]
	if not flow then
		return false
	end

	for _, allowed in ipairs(flow.next) do
		if allowed == target then
			return true
		end
	end
	return false
end

--- 获取所有允许的下一个状态
--- @param current string 当前状态
--- @return table
function M.get_allowed(current)
	local flow = STATUS_FLOW[current]
	return (flow and flow.next) or {}
end

--- 获取下一个状态（用于循环切换）
--- @param current string 当前状态
--- @param include_completed boolean 是否包含完成状态
--- @return string
function M.get_next(current, include_completed)
	local order = { types.STATUS.NORMAL, types.STATUS.URGENT, types.STATUS.WAITING }
	if include_completed then
		table.insert(order, types.STATUS.COMPLETED)
	end

	for i, s in ipairs(order) do
		if current == s then
			return order[i % #order + 1]
		end
	end
	return types.STATUS.NORMAL
end

---------------------------------------------------------------------
-- 统一状态更新API
---------------------------------------------------------------------
--- 更新任务状态
--- @param id string 任务ID
--- @param target string 目标状态
--- @param source string|nil 事件来源
--- @param opts table|nil 选项
--- @return boolean, string|nil
function M.update(id, target, source, opts)
	opts = opts or {}

	if not store or not store.link then
		return false, "存储模块未加载"
	end

	local task = core.get_task(id)
	if not task or not task.locations.todo then
		return false, "找不到任务: " .. id
	end

	local region = M._detect_task_region(id)

	local region_ok, region_msg = M._validate_region_transition(task.core.status, target, region)
	if not region_ok then
		return false, region_msg
	end

	if not M.is_allowed(task.core.status, target) then
		return false, string.format("不允许的状态流转: %s → %s", task.core.status, target)
	end

	local bufnr = vim.fn.bufnr(task.locations.todo.path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, task.locations.todo.line - 1, task.locations.todo.line, false)
		if lines and #lines > 0 then
			local parsed = parser.parse_task_line(lines[1])
			if parsed and parsed.content and parsed.content ~= task.core.content then
				task.core.content = parsed.content
				task.core.content_hash = hash.hash(parsed.content)
			end
		end
	end

	local result
	local operation_source = source or "status_update"

	if target == types.STATUS.COMPLETED then
		-- 使用 status 模块的 mark_completed
		result = require("todo2.store.link.status").mark_completed(id)
	elseif target == types.STATUS.ARCHIVED then
		-- 使用 archive 模块的 archive_task
		result = require("todo2.store.link.archive").archive_task(id, operation_source)
	else
		if types.is_completed_status(task.core.status) then
			result = require("todo2.store.link.status").reopen_link(id)
		else
			-- 直接更新 task
			task.core.status = target
			task.timestamps.updated = os.time()
			result = core.save_task(id, task)
		end
	end

	local success = result ~= nil

	if success and events and not opts.skip_event then
		local affected_files = { task.locations.todo.path }

		if
			task.locations.code
			and task.locations.code.path
			and not vim.tbl_contains(affected_files, task.locations.code.path)
		then
			table.insert(affected_files, task.locations.code.path)
		end

		events.on_state_changed({
			source = operation_source,
			changed_ids = { id },
			ids = { id },
			file = task.locations.todo.path,
			files = affected_files,
			bufnr = bufnr,
			timestamp = os.time() * 1000,
		})
	end

	return success, success and "成功" or "操作失败"
end

--- 批量更新任务状态
--- @param ids string[] 任务ID列表
--- @param target string 目标状态
--- @param source string|nil 事件来源
--- @return table
function M.batch_update(ids, target, source)
	if not ids or #ids == 0 then
		return { success = 0, failed = 0 }
	end

	local result = { success = 0, failed = 0, details = {} }
	local all_ids = {}
	local affected_files = {}

	for _, id in ipairs(ids) do
		local ok, err = M.update(id, target, source or "batch_update", { skip_event = true })
		if ok then
			result.success = result.success + 1
			table.insert(result.details, { id = id, success = true })
			table.insert(all_ids, id)

			local task = core.get_task(id)
			if
				task
				and task.locations.todo
				and task.locations.todo.path
				and not vim.tbl_contains(affected_files, task.locations.todo.path)
			then
				table.insert(affected_files, task.locations.todo.path)
			end

			if
				task
				and task.locations.code
				and task.locations.code.path
				and not vim.tbl_contains(affected_files, task.locations.code.path)
			then
				table.insert(affected_files, task.locations.code.path)
			end
		else
			result.failed = result.failed + 1
			table.insert(result.details, { id = id, success = false, error = err })
		end
	end

	if result.success > 0 and events then
		events.on_state_changed({
			source = source or "batch_update",
			changed_ids = all_ids,
			ids = all_ids,
			files = affected_files,
			timestamp = os.time() * 1000,
		})
	end

	result.summary = string.format("批量更新完成: 成功 %d, 失败 %d", result.success, result.failed)

	return result
end

---------------------------------------------------------------------
-- 快捷操作API
---------------------------------------------------------------------

--- 循环切换状态（用于UI）
--- @param id string 任务ID
--- @param include_completed boolean 是否包含完成状态
--- @return boolean, string|nil
function M.cycle(id, include_completed)
	local task = core.get_task(id)
	if not task then
		return false, "找不到任务"
	end

	if types.is_completed_status(task.core.status) then
		return M.update(id, types.STATUS.NORMAL, "cycle")
	end

	local next_status = M.get_next(task.core.status, include_completed)
	return M.update(id, next_status, "cycle")
end

--- 标记任务为完成
--- @param id string 任务ID
--- @return boolean, string|nil
function M.mark_completed(id)
	return M.update(id, types.STATUS.COMPLETED, "mark_completed")
end

--- 重新打开任务
--- @param id string 任务ID
--- @return boolean, string|nil
function M.reopen(id)
	return M.update(id, types.STATUS.NORMAL, "reopen")
end

--- 归档任务
--- @param id string 任务ID
--- @param reason string|nil 归档原因
--- @return boolean, string|nil
function M.archive(id, reason)
	return M.update(id, types.STATUS.ARCHIVED, reason or "archive")
end

---------------------------------------------------------------------
-- 当前行信息查询
---------------------------------------------------------------------

--- 获取当前行的链接信息
--- @return table|nil { id, type, link, bufnr, path, tag }
function M.get_current_link_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.getline(".")
	local path = vim.api.nvim_buf_get_name(bufnr)

	local id, link_type
	local tag = nil

	if id_utils.contains_code_mark(line) then
		id = id_utils.extract_id_from_code_mark(line)
		tag = id_utils.extract_tag_from_code_mark(line)
		link_type = "code"
	elseif id_utils.contains_todo_anchor(line) then
		id = id_utils.extract_id_from_todo_anchor(line)
		link_type = "todo"
	end

	if not id or not store or not store.link then
		return nil
	end

	-- 从内部格式获取
	local task = core.get_task(id)
	if not task then
		return nil
	end

	if link_type == "todo" and task.locations.todo then
		return {
			id = id,
			type = link_type,
			link = task_to_todo_link(task),
			bufnr = bufnr,
			path = path,
			tag = tag,
		}
	elseif link_type == "code" and task.locations.code then
		-- 构造一个兼容的 code link
		return {
			id = id,
			type = link_type,
			link = {
				id = task.id,
				path = task.locations.code.path,
				line = task.locations.code.line,
				content = task.core.content,
				tag = task.core.tags[1],
				status = task.core.status,
				context = task.locations.code.context,
			},
			bufnr = bufnr,
			path = path,
			tag = tag,
		}
	end

	return nil
end

return M
