-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 合并 toggle + sync 的状态管理器

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------
local function replace_status(bufnr, lnum, from, to)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	local start_col, end_col = line:find(from)
	if not start_col then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { to })
	return true
end

--- 获取任务在store中的链接
--- @param task table 任务对象
--- @param link_type string 链接类型（"todo"或"code"）
--- @return table|nil
local function get_task_store_link(task, link_type)
	if not task or not task.id then
		return nil
	end

	local store = module.get("store")
	if link_type == "todo" then
		return store.get_todo_link(task.id)
	else
		return store.get_code_link(task.id)
	end
end

---------------------------------------------------------------------
-- ⭐ 修改1：切换任务状态（含向下传播，并更新状态） - 修复版本
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	local success
	local store = module.get("store")

	if task.is_done then
		-- 从完成状态变为未完成
		success = replace_status(bufnr, task.line_num, "%[[xX]%]", "[ ]")
		if success then
			task.is_done = false
			task.status = "[ ]"

			if task.id then
				-- ⭐ 关键修复：从完成状态恢复时，同时恢复两种链接类型
				store.restore_previous_status(task.id) -- 移除 ", "todo""
			end
		end
	else
		-- 从未完成状态变为完成
		success = replace_status(bufnr, task.line_num, "%[ %]", "[x]")
		if success then
			task.is_done = true
			task.status = "[x]"
			-- 标记为完成状态
			if task.id then
				-- ⭐ 关键修复：标记为完成时，同时更新两种链接类型
				store.mark_completed(task.id) -- 移除 ", "todo""
			end
		end
	end

	if not success then
		return false
	end

	-- 向下传播：递归切换所有子任务状态和状态标记
	local function toggle_children(child_task)
		for _, child in ipairs(child_task.children) do
			if task.is_done then
				replace_status(bufnr, child.line_num, "%[ %]", "[x]")
				child.is_done = true
				child.status = "[x]"
				-- ⭐ 关键修复：子任务也设置为完成状态，同时更新两种链接类型
				if child.id then
					store.mark_completed(child.id) -- 移除 ", "todo""
				end
			else
				replace_status(bufnr, child.line_num, "%[[xX]%]", "[ ]")
				child.is_done = false
				child.status = "[ ]"
				-- ⭐ 关键修复：子任务从完成状态恢复，同时更新两种链接类型
				if child.id then
					store.restore_previous_status(child.id) -- 移除 ", "todo""
				end
			end
			toggle_children(child)
		end
	end

	toggle_children(task)
	return true
end

---------------------------------------------------------------------
-- ⭐ 修改2：确保父子状态一致性（向上同步） - 修复版本
---------------------------------------------------------------------
local function ensure_parent_child_consistency(tasks, bufnr)
	local changed = false
	local task_by_line = {}
	local store = module.get("store")

	for _, task in ipairs(tasks) do
		task_by_line[task.line_num] = task
	end

	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	for _, task in ipairs(tasks) do
		local parent = task.parent
		if parent and #parent.children > 0 then
			local all_children_done = true
			for _, child in ipairs(parent.children) do
				if not child.is_done then
					all_children_done = false
					break
				end
			end

			if all_children_done and not parent.is_done then
				replace_status(bufnr, parent.line_num, "%[ %]", "[x]")
				parent.is_done = true
				parent.status = "[x]"
				-- ⭐ 关键修复：父任务自动设置为完成状态，同时更新两种链接类型
				if parent.id then
					store.update_status(parent.id, "completed") -- 移除 ", "todo""
				end
				changed = true
			elseif not all_children_done and parent.is_done then
				replace_status(bufnr, parent.line_num, "%[[xX]%]", "[ ]")
				parent.is_done = false
				parent.status = "[ ]"
				-- ⭐ 关键修复：父任务恢复到上一次状态或设为正常，同时更新两种链接类型
				if parent.id then
					local parent_link = get_task_store_link(parent, "todo")
					local new_status = "normal"
					if parent_link and parent_link.previous_status and parent_link.previous_status ~= "completed" then
						-- 恢复到上一次状态
						new_status = parent_link.previous_status
					end
					store.update_status(parent.id, new_status) -- 移除 ", "todo""
				end
				changed = true
			end
		end
	end

	if changed then
		local stats = module.get("core.stats")
		stats.calculate_all_stats(tasks)
		ensure_parent_child_consistency(tasks, bufnr)
	end

	return changed
end

---------------------------------------------------------------------
-- 核心API：切换任务状态（需要修改ID收集逻辑）
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	local parser = module.get("core.parser")
	local tasks, roots = parser.parse_file(path)

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

	local success = toggle_task_and_children(current_task, bufnr)
	if not success then
		return false, "切换失败"
	end

	local stats = module.get("core.stats")
	stats.calculate_all_stats(tasks)

	-- ⭐ 在确保父子一致性之前，先创建一个ID集合来收集所有受影响的ID
	local id_set = {}

	-- 收集当前任务及其所有子任务的ID
	local function collect_ids(task)
		if task.id then
			id_set[task.id] = true
		end
		for _, child in ipairs(task.children) do
			collect_ids(child)
		end
	end

	collect_ids(current_task)

	-- ⭐ 修改：传递ID集合给 ensure_parent_child_consistency，以便收集父任务的ID
	-- 由于 ensure_parent_child_consistency 内部也会调用 store.update_status，我们需要收集这些ID
	-- 这里我们修改 ensure_parent_child_consistency 来接受第三个参数
	local function ensure_parent_child_consistency_with_collection(tasks, bufnr, id_collection)
		local changed = false
		local task_by_line = {}
		local store = module.get("store")

		for _, task in ipairs(tasks) do
			task_by_line[task.line_num] = task
		end

		table.sort(tasks, function(a, b)
			return a.line_num > b.line_num
		end)

		for _, task in ipairs(tasks) do
			local parent = task.parent
			if parent and #parent.children > 0 then
				local all_children_done = true
				for _, child in ipairs(parent.children) do
					if not child.is_done then
						all_children_done = false
						break
					end
				end

				if all_children_done and not parent.is_done then
					replace_status(bufnr, parent.line_num, "%[ %]", "[x]")
					parent.is_done = true
					parent.status = "[x]"
					if parent.id then
						store.update_status(parent.id, "completed")
						-- 收集父任务ID
						if id_collection then
							id_collection[parent.id] = true
						end
					end
					changed = true
				elseif not all_children_done and parent.is_done then
					replace_status(bufnr, parent.line_num, "%[[xX]%]", "[ ]")
					parent.is_done = false
					parent.status = "[ ]"
					if parent.id then
						local parent_link = get_task_store_link(parent, "todo")
						local new_status = "normal"
						if
							parent_link
							and parent_link.previous_status
							and parent_link.previous_status ~= "completed"
						then
							new_status = parent_link.previous_status
						end
						store.update_status(parent.id, new_status)
						-- 收集父任务ID
						if id_collection then
							id_collection[parent.id] = true
						end
					end
					changed = true
				end
			end
		end

		if changed then
			local stats = module.get("core.stats")
			stats.calculate_all_stats(tasks)
			ensure_parent_child_consistency_with_collection(tasks, bufnr, id_collection)
		end

		return changed
	end

	-- 使用带ID收集的版本
	ensure_parent_child_consistency_with_collection(tasks, bufnr, id_set)

	-- 将集合转换为列表
	local affected_ids = {}
	for id, _ in pairs(id_set) do
		table.insert(affected_ids, id)
	end

	-- ⭐ 智能触发事件：只在必要时触发
	local events = module.get("core.events")
	if #affected_ids > 0 then
		-- 检查是否已经有相同的事件在处理中
		local event_data = {
			source = "toggle_line",
			file = path,
			bufnr = bufnr,
			ids = affected_ids,
		}

		if not events.is_event_processing(event_data) then
			events.on_state_changed(event_data)
		end
	end

	-- ⭐ 智能保存：检查是否真的有修改
	if not opts.skip_write then
		local autosave = module.get("core.autosave")
		-- 确保buffer被标记为已修改
		if not vim.api.nvim_buf_get_option(bufnr, "modified") then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("silent write")
			end)
		else
			autosave.request_save(bufnr)
		end
	end

	return true, current_task.is_done
end

-- 导出内部函数用于测试
M._replace_status = replace_status
M._ensure_parent_child_consistency = ensure_parent_child_consistency

return M
