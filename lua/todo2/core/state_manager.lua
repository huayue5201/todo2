-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 负责活跃状态 ↔ 完成状态的双向切换
--- ⭐ 优化版：移除手动渲染，通过事件系统统一管理

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local link_mod = require("todo2.store.link")
local events = require("todo2.core.events")
local parser = require("todo2.core.parser")
local autosave = require("todo2.core.autosave")

local batch_operations = {} -- 存储批量操作的ID
local batch_timer = nil

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function replace_status(bufnr, lnum, from, to)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	local start_col, end_col = format.get_checkbox_position(line)
	if not start_col then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { to })
	return true
end

---------------------------------------------------------------------
-- ⭐ 修复1：普通任务切换函数
---------------------------------------------------------------------
--- 切换普通任务（无ID）
--- @param bufnr number 缓冲区
--- @param lnum number 行号
--- @param task table 任务对象
--- @return boolean 是否成功
local function toggle_normal_task(bufnr, lnum, task)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	-- 获取当前复选框
	local current_checkbox = task.checkbox or "[ ]"
	local new_checkbox

	-- 在 [ ] 和 [x] 之间切换
	if current_checkbox == "[ ]" then
		new_checkbox = "[x]"
	elseif current_checkbox == "[x]" then
		new_checkbox = "[ ]"
	else
		return false -- 不是可切换的任务行
	end

	-- 更新缓冲区
	local success = replace_status(bufnr, lnum, current_checkbox, new_checkbox)

	if success then
		-- 更新任务对象的状态
		task.status = (new_checkbox == "[x]") and "completed" or "normal"
		task.checkbox = new_checkbox
	end

	return success
end

---------------------------------------------------------------------
-- ⭐ 修复2：收集所有子任务（包括普通任务）
---------------------------------------------------------------------
--- 收集所有子任务节点
--- @param task table 任务对象
--- @param result table 结果表
--- @return table
local function collect_all_child_nodes(task, result)
	result = result or {}

	-- 添加当前任务
	table.insert(result, task)

	-- 递归子任务
	if task.children and #task.children > 0 then
		for _, child in ipairs(task.children) do
			collect_all_child_nodes(child, result)
		end
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 修复3：批量切换普通任务（不涉及存储）
---------------------------------------------------------------------
--- 批量切换普通任务树
--- @param root_task table 根任务
--- @param bufnr number 缓冲区
--- @param target_status string 目标状态
--- @return table 结果
local function batch_toggle_normal_tasks(root_task, bufnr, target_status)
	-- 收集所有子任务节点
	local all_nodes = collect_all_child_nodes(root_task, {})

	-- 按行号降序排序（从后往前处理，避免行号变化）
	table.sort(all_nodes, function(a, b)
		return a.line_num > b.line_num
	end)

	local updated_count = 0
	local target_checkbox = (target_status == "completed") and "[x]" or "[ ]"

	-- 逐个切换
	for _, node in ipairs(all_nodes) do
		local line = vim.api.nvim_buf_get_lines(bufnr, node.line_num - 1, node.line_num, false)[1]
		if line then
			local current_checkbox = node.checkbox or "[ ]"
			local success = replace_status(bufnr, node.line_num, current_checkbox, target_checkbox)
			if success then
				node.status = target_status
				node.checkbox = target_checkbox
				updated_count = updated_count + 1
			end
		end
	end

	return {
		updated = updated_count,
		ids = {}, -- 普通任务没有ID
		success = updated_count > 0,
	}
end

---------------------------------------------------------------------
-- ⭐ 修复4：收集所有子任务ID（双链任务）
---------------------------------------------------------------------
local function collect_all_child_ids(task, result)
	result = result or {}

	if not task then
		return result
	end

	-- 添加当前任务ID
	if task.id then
		result[task.id] = true
	end

	-- 递归子任务
	if task.children then
		for _, child in ipairs(task.children) do
			collect_all_child_ids(child, result)
		end
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 修复5：批量更新存储（双链任务）
---------------------------------------------------------------------
local function batch_update_storage(ids, target_status, source_task)
	if not ids or vim.tbl_isempty(ids) then
		return { success = 0, failed = 0 }
	end

	local id_list = vim.tbl_keys(ids)
	local result = { success = 0, failed = 0 }

	-- 批量获取所有链接（减少存储访问）
	local links = {}
	for _, id in ipairs(id_list) do
		links[id] = link_mod.get_todo(id, { verify_line = false })
	end

	-- 批量更新
	for id, link in pairs(links) do
		if link then
			-- 保存之前的状态（用于后续恢复）
			if target_status == types.STATUS.COMPLETED then
				link.previous_status = link.status
				link.status = types.STATUS.COMPLETED
				link.completed_at = os.time()
			else
				-- 从完成状态恢复
				if types.is_completed_status(link.status) then
					link.status = link.previous_status or types.STATUS.NORMAL
					link.previous_status = nil
					link.completed_at = nil
				else
					link.status = target_status
				end
			end
			link.updated_at = os.time()

			-- 直接更新存储
			local store = require("todo2.store.nvim_store")
			store.set_key("todo.links.todo." .. id, link)
			result.success = result.success + 1
		else
			result.failed = result.failed + 1
		end
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 修复6：批量处理操作（触发事件）
---------------------------------------------------------------------
local function process_batch_operations()
	if vim.tbl_isempty(batch_operations) then
		return
	end

	local operations_to_process = vim.deepcopy(batch_operations)
	batch_operations = {}

	local affected_files = {}
	local all_ids = {}

	for bufnr, data in pairs(operations_to_process) do
		for id, _ in pairs(data.ids) do
			all_ids[id] = true

			local link = link_mod.get_todo(id, { verify_line = false })
			if link and link.path then
				affected_files[link.path] = true
			end

			-- ⭐ 同时收集关联的代码文件
			local code_link = link_mod.get_code(id, { verify_line = false })
			if code_link and code_link.path then
				affected_files[code_link.path] = true
			end
		end
	end

	if not vim.tbl_isempty(all_ids) then
		events.on_state_changed({
			source = "batch_state_change",
			ids = vim.tbl_keys(all_ids),
			files = vim.tbl_keys(affected_files),
			timestamp = os.time() * 1000,
		})
	end

	if batch_timer then
		batch_timer:stop()
		batch_timer:close()
		batch_timer = nil
	end
end

---------------------------------------------------------------------
-- ⭐ 修复7：添加到批处理队列
---------------------------------------------------------------------
local function add_to_batch(bufnr, ids)
	if not ids or #ids == 0 then
		return
	end

	if not batch_operations[bufnr] then
		batch_operations[bufnr] = { ids = {} }
	end

	for _, id in ipairs(ids) do
		batch_operations[bufnr].ids[id] = true
	end

	-- 立即处理
	process_batch_operations()
end

---------------------------------------------------------------------
-- ⭐ 修复8：批量切换双链任务
---------------------------------------------------------------------
local function batch_toggle_linked_tasks(root_task, bufnr, target_status)
	-- 1. 一次性收集所有子任务ID
	local all_ids = collect_all_child_ids(root_task, {})

	-- 2. 批量更新存储
	local update_result = batch_update_storage(all_ids, target_status, root_task)

	-- 3. 更新根任务行
	local current_checkbox = types.status_to_checkbox(root_task.status)
	local target_checkbox = types.status_to_checkbox(target_status)
	local success = replace_status(bufnr, root_task.line_num, current_checkbox, target_checkbox)

	if success then
		-- 更新根任务状态
		root_task.status = target_status

		-- 4. 添加到批处理队列
		add_to_batch(bufnr, vim.tbl_keys(all_ids))
	end

	return {
		updated = update_result.success,
		ids = vim.tbl_keys(all_ids),
		success = success,
	}
end

---------------------------------------------------------------------
-- ⭐ 主切换函数（同时支持普通任务和双链任务）
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	-- 解析任务树
	local tasks, roots, id_to_task = parser.parse_file(path, false)
	if not tasks then
		return false, "解析任务失败"
	end

	local current_task = nil
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		return false, "不是任务行"
	end

	-- ⭐ 区分普通任务和双链任务
	local is_linked = current_task.id ~= nil
	local all_ids = {}

	if not is_linked then
		-- 普通任务：简单切换当前行
		local success = toggle_normal_task(bufnr, lnum, current_task)
		if success then
			-- 自动保存
			if not opts.skip_write then
				autosave.request_save(bufnr)
			end

			-- ⭐ 触发事件刷新渲染
			events.on_state_changed({
				source = "state_manager",
				ids = {},
				files = { path },
				file = path,
				bufnr = bufnr,
				timestamp = os.time() * 1000,
			})

			return true, "normal_toggled"
		else
			return false, "切换失败"
		end
	end

	-- 双链任务：从存储获取最新状态
	local stored = link_mod.get_todo(current_task.id, { verify_line = false })
	if stored then
		current_task.status = stored.status
		current_task.previous_status = stored.previous_status
		current_task.archived_at = stored.archived_at
		current_task.completed_at = stored.completed_at
	end

	-- 检查是否为归档状态
	if current_task.status == types.STATUS.ARCHIVED then
		return false, "归档任务不能切换状态"
	end

	-- 确定目标状态
	local target_status
	if types.is_active_status(current_task.status) then
		target_status = types.STATUS.COMPLETED
	else
		target_status = current_task.previous_status or types.STATUS.NORMAL
	end

	-- 批量切换整个任务树
	local result = batch_toggle_linked_tasks(current_task, bufnr, target_status)

	if not result.success then
		return false, "切换失败"
	end

	-- ⭐ 收集所有受影响的文件
	local affected_files = { path }

	-- 添加关联的代码文件
	for _, id in ipairs(result.ids or {}) do
		local code_link = link_mod.get_code(id, { verify_line = false })
		if code_link and code_link.path and not vim.tbl_contains(affected_files, code_link.path) then
			table.insert(affected_files, code_link.path)
		end
	end

	-- ⭐ 触发事件，让事件系统统一处理渲染
	events.on_state_changed({
		source = "state_manager",
		ids = result.ids,
		files = affected_files,
		file = path,
		bufnr = bufnr,
		timestamp = os.time() * 1000,
	})

	-- 自动保存
	if not opts.skip_write then
		autosave.request_save(bufnr)
	end

	return true, target_status
end

return M
