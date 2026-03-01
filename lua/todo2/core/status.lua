-- lua/todo2/core/status.lua
--- @module todo2.core.status
--- @brief 核心状态管理模块（统一API）- 修复版：简化内容同步逻辑

local M = {}

local types = require("todo2.store.types")
local store = require("todo2.store")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local parser = require("todo2.core.parser")
local hash = require("todo2.utils.hash")

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
-- ⭐ 修改版：状态更新API（增加区域验证）
---------------------------------------------------------------------
--- 更新任务状态
--- @param id string 任务ID
--- @param target string 目标状态
--- @param source string|nil 事件来源
--- @return boolean 是否成功
function M.update(id, target, source)
	if not store or not store.link then
		vim.notify("存储模块未加载", vim.log.levels.ERROR)
		return false
	end

	-- 获取当前任务链接
	local link = store.link.get_todo(id, { verify_line = true })
	if not link then
		vim.notify("找不到任务: " .. id, vim.log.levels.ERROR)
		return false
	end

	-- ⭐ 验证任务是否在活跃区域（归档区域的任务只能归档或恢复）
	local path = link.path
	local bufnr = vim.fn.bufnr(path)
	local is_in_archive = false

	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		local line = link.line
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

		-- 从当前行向上查找归档区域标题
		for i = line, 1, -1 do
			if lines[i] and require("todo2.config").is_archive_section_line(lines[i]) then
				is_in_archive = true
				break
			end
		end
	end

	-- 归档区域的任务只能切换到归档状态或从归档恢复
	if is_in_archive and target ~= types.STATUS.ARCHIVED and link.status ~= types.STATUS.ARCHIVED then
		vim.notify("归档区域的任务必须先恢复", vim.log.levels.WARN)
		return false
	end

	-- 检查状态流转是否允许
	if not M.is_allowed(link.status, target) then
		vim.notify(string.format("不允许的状态流转: %s → %s", link.status, target), vim.log.levels.WARN)
		return false
	end

	-- 从文件中读取最新内容并更新link对象
	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, link.line - 1, link.line, false)
		if lines and #lines > 0 then
			local task = parser.parse_task_line(lines[1])
			if task and task.content and task.content ~= link.content then
				-- 更新link对象的内容
				link.content = task.content
				link.content_hash = hash.hash(task.content)
			end
		end
	end

	local result
	local operation_source = source or "status_update"

	-- 根据目标状态选择正确的存储操作
	if target == types.STATUS.COMPLETED then
		-- 标记为完成：记录 previous_status
		result = store.link.mark_completed(id)
		if result then
			vim.notify(string.format("✅ 任务已完成 (原状态: %s)", link.status), vim.log.levels.INFO)
		end
	elseif target == types.STATUS.ARCHIVED then
		-- 归档任务
		result = store.link.mark_archived(id, operation_source)
		if result then
			vim.notify(string.format("📦 任务已归档 (原状态: %s)", link.status), vim.log.levels.INFO)
		end
	else
		-- 从已完成状态恢复时使用 reopen_link
		if types.is_completed_status(link.status) then
			-- 从完成状态恢复到之前的状态
			result = store.link.reopen_link(id)
			if result then
				local restored_status = link.previous_status or types.STATUS.NORMAL
				vim.notify(string.format("🔄 任务已恢复为: %s", restored_status), vim.log.levels.INFO)
			end
		else
			-- 活跃状态之间直接切换
			result = store.link.update_active_status(id, target)
		end
	end

	local success = result ~= nil

	-- 触发事件通知UI更新
	if success and events then
		events.on_state_changed({
			source = operation_source,
			ids = { id },
			file = link.path,
			bufnr = bufnr,
			timestamp = os.time() * 1000,
		})
	end

	return success
end

--- 循环切换状态（用于UI）
--- @param id string 任务ID
--- @param include_completed boolean 是否包含完成状态
--- @return boolean
function M.cycle(id, include_completed)
	local link = store.link.get_todo(id, { verify_line = true })
	if not link then
		return false
	end

	-- 如果当前是完成状态，直接恢复到之前的状态
	if types.is_completed_status(link.status) then
		return M.update(id, types.STATUS.NORMAL, "cycle") -- 会触发 reopen_link
	end

	-- 活跃状态之间循环
	local next_status = M.get_next(link.status, include_completed)
	return M.update(id, next_status, "cycle")
end

---------------------------------------------------------------------
-- 快捷操作API
---------------------------------------------------------------------

--- 标记任务为完成
--- @param id string 任务ID
--- @return boolean
function M.mark_completed(id)
	return M.update(id, types.STATUS.COMPLETED, "mark_completed")
end

--- 重新打开任务（恢复到之前的状态）
--- @param id string 任务ID
--- @return boolean
function M.reopen_link(id)
	return M.update(id, types.STATUS.NORMAL, "reopen") -- 会触发 reopen_link
end

--- 归档任务
--- @param id string 任务ID
--- @param reason string|nil 归档原因
--- @return boolean
function M.archive(id, reason)
	return M.update(id, types.STATUS.ARCHIVED, reason or "archive")
end

---------------------------------------------------------------------
-- 当前行信息查询（使用 id_utils）
---------------------------------------------------------------------
--- 获取当前行的链接信息
--- @return table|nil { id, type, link, bufnr, path, tag }
function M.get_current_link_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.getline(".")
	local path = vim.api.nvim_buf_get_name(bufnr)

	local id, link_type
	local tag = nil

	-- 使用 id_utils 检查代码标记
	if id_utils.contains_code_mark(line) then
		id = id_utils.extract_id_from_code_mark(line)
		tag = id_utils.extract_tag_from_code_mark(line)
		link_type = "code"
	-- 使用 id_utils 检查TODO锚点
	elseif id_utils.contains_todo_anchor(line) then
		id = id_utils.extract_id_from_todo_anchor(line)
		link_type = "todo"
	end

	if not id or not store or not store.link then
		return nil
	end

	local link = (link_type == "todo") and store.link.get_todo(id, { verify_line = true })
		or store.link.get_code(id, { verify_line = true })

	return link and {
		id = id,
		type = link_type,
		link = link,
		bufnr = bufnr,
		path = path,
		tag = tag,
	} or nil
end

---------------------------------------------------------------------
-- 批量操作API
---------------------------------------------------------------------

--- 批量更新任务状态
--- @param ids string[] 任务ID列表
--- @param target string 目标状态
--- @param source string|nil 事件来源
--- @return table 操作结果
function M.batch_update(ids, target, source)
	if not ids or #ids == 0 then
		return { success = 0, failed = 0 }
	end

	local result = { success = 0, failed = 0, details = {} }

	for _, id in ipairs(ids) do
		local ok = pcall(function()
			return M.update(id, target, source or "batch_update")
		end)

		if ok then
			result.success = result.success + 1
			table.insert(result.details, { id = id, success = true })
		else
			result.failed = result.failed + 1
			table.insert(result.details, { id = id, success = false })
		end
	end

	result.summary = string.format("批量更新完成: 成功 %d, 失败 %d", result.success, result.failed)

	return result
end

return M
