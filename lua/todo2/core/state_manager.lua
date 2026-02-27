-- lua/todo2/core/state_manager.lua
--- @module todo2.core.state_manager
--- @brief 负责活跃状态 ↔ 完成状态的双向切换
--- ⭐ 优化版：批量操作 + 延迟刷新

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
local renderer = require("todo2.render.code_render")

-- ⭐ 新增：批量操作缓存
local batch_operations = {} -- 存储批量操作的ID
local batch_timer = nil
local BATCH_DELAY = 50 -- 批量操作延迟（毫秒）

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
-- 从存储同步任务数据
---------------------------------------------------------------------
local function sync_task_from_store(task)
	if not task or not task.id then
		return task
	end

	local stored = link_mod.get_todo(task.id, { verify_line = false })
	if stored then
		task.status = stored.status
		task.previous_status = stored.previous_status
		task.archived_at = stored.archived_at
		task.completed_at = stored.completed_at
		task.pending_restore_status = stored.pending_restore_status
	end
	return task
end

---------------------------------------------------------------------
-- ⭐ 新增：批量收集所有子任务ID（不递归遍历存储）
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
-- ⭐ 新增：批量更新存储（一次完成，不触发事件）
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

			-- 直接更新存储（不触发事件）
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
-- ⭐ 新增：批量处理批量操作（延迟触发事件）
---------------------------------------------------------------------
local function process_batch_operations()
	if vim.tbl_isempty(batch_operations) then
		return
	end

	-- 收集所有受影响的文件和ID
	local affected_files = {}
	local all_ids = {}

	for bufnr, data in pairs(batch_operations) do
		for id, _ in pairs(data.ids) do
			all_ids[id] = true

			-- 获取文件路径
			local link = link_mod.get_todo(id, { verify_line = false })
			if link and link.path then
				affected_files[link.path] = true
			end
		end
	end

	-- 触发一个合并的事件
	events.on_state_changed({
		source = "batch_state_change",
		ids = vim.tbl_keys(all_ids),
		files = vim.tbl_keys(affected_files),
		timestamp = os.time() * 1000,
	})

	-- 清空批处理缓存
	batch_operations = {}
	batch_timer = nil
end

---------------------------------------------------------------------
-- ⭐ 新增：添加到批处理队列
---------------------------------------------------------------------
local function add_to_batch(bufnr, ids)
	if not batch_operations[bufnr] then
		batch_operations[bufnr] = { ids = {} }
	end

	for id, _ in pairs(ids) do
		batch_operations[bufnr].ids[id] = true
	end

	-- 启动或重置定时器
	if batch_timer then
		batch_timer:stop()
		batch_timer:close()
	end

	batch_timer = vim.loop.new_timer()
	batch_timer:start(BATCH_DELAY, 0, vim.schedule_wrap(process_batch_operations))
end

---------------------------------------------------------------------
-- 普通任务的简化切换（无ID任务）- 保持不变
---------------------------------------------------------------------
local function simple_toggle_task(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	-- 只在 [ ] 和 [x] 之间切换
	local new_line
	if line:match("%[ %]") then
		-- [ ] 变为 [x]
		new_line = line:gsub("%[ %]", "[x]", 1)
	elseif line:match("%[x%]") then
		-- [x] 变为 [ ]
		new_line = line:gsub("%[x%]", "[ ]", 1)
	else
		return false -- 不是可切换的任务行
	end

	-- 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
	return true
end

---------------------------------------------------------------------
-- ⭐ 优化版：批量切换任务状态（不递归调用存储）
---------------------------------------------------------------------
local function batch_toggle_tasks(root_task, bufnr, target_status)
	if not root_task then
		return { updated = 0, ids = {} }
	end

	-- 1. 一次性收集所有子任务ID（从解析树，不访问存储）
	local all_ids = collect_all_child_ids(root_task, {})

	-- 2. 批量更新存储
	local update_result = batch_update_storage(all_ids, target_status, root_task)

	-- 3. 更新根任务行（只更新文件中的一行）
	local current_checkbox = types.status_to_checkbox(root_task.status)
	local target_checkbox = types.status_to_checkbox(target_status)
	local success = replace_status(bufnr, root_task.line_num, current_checkbox, target_checkbox)

	if success then
		-- 更新根任务状态
		root_task.status = target_status

		-- 4. 添加到批处理队列（延迟触发事件）
		add_to_batch(bufnr, all_ids)
	end

	return {
		updated = update_result.success,
		ids = vim.tbl_keys(all_ids),
		success = success,
	}
end

---------------------------------------------------------------------
-- ⭐ 修复：找到更新后的任务对象
---------------------------------------------------------------------
local function find_updated_task(tasks, task_id)
	for _, task in ipairs(tasks) do
		if task.id == task_id then
			return task
		end
		if task.children and #task.children > 0 then
			local found = find_updated_task(task.children, task_id)
			if found then
				return found
			end
		end
	end
	return nil
end

---------------------------------------------------------------------
-- ⭐ 优化版：主切换函数（使用批处理）
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	-- 解析任务树（使用缓存，不强制刷新）
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

	-- 普通任务（无ID）：简单切换
	if not current_task.id then
		local success = simple_toggle_task(bufnr, lnum)
		if success then
			if not opts.skip_write then
				autosave.request_save(bufnr)
			end
			return true, "normal_toggled"
		else
			return false, "切换失败"
		end
	end

	-- 双链任务：从存储同步状态
	current_task = sync_task_from_store(current_task)

	-- 确定目标状态
	local target_status
	if types.is_active_status(current_task.status) then
		target_status = types.STATUS.COMPLETED
	else
		target_status = current_task.previous_status or types.STATUS.NORMAL
	end

	-- 批量切换整个任务树
	local result = batch_toggle_tasks(current_task, bufnr, target_status)

	if not result.success then
		return false, "切换失败"
	end

	-- ⭐ 只重新解析一次，获取更新后的任务树
	local new_tasks, new_roots = parser.parse_file(path, true)
	local updated_task = find_updated_task(new_tasks, current_task.id) or current_task

	-- ⭐ 只渲染受影响的线路（根任务及其父任务）
	local function render_task_and_parents(task)
		if task and task.line_num then
			renderer.render_line(bufnr, task.line_num - 1)
			if task.parent then
				render_task_and_parents(task.parent)
			end
		end
	end
	render_task_and_parents(updated_task)

	-- 自动保存
	if not opts.skip_write then
		autosave.request_save(bufnr)
	end

	return true, target_status
end

return M
