-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 核心归档模块

local M = {}

local store = require("todo2.store")
local types = require("todo2.store.types")
local events = require("todo2.core.events")
local parser = require("todo2.core.parser")
local deleter = require("todo2.task.deleter")
local comment = require("todo2.utils.comment")
local id_utils = require("todo2.utils.id")
local config = require("todo2.config")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	archive_marker = "[>]",
	auto_archive_days = 7,
	preserve_code_markers = false,
}

function M.set_config(user_config)
	CONFIG = vim.tbl_extend("force", CONFIG, user_config or {})
end

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------

local function collect_tree_nodes(root, result)
	result = result or {}
	table.insert(result, root)
	if root.children then
		for _, child in ipairs(root.children) do
			collect_tree_nodes(child, result)
		end
	end
	return result
end

local function is_tree_completed(root)
	local function check(task)
		local todo_link = task.id and store.link.get_todo(task.id, { verify_line = false })
		local status = todo_link and todo_link.status or task.status

		if not types.is_completed_status(status) then
			return false
		end
		if task.children then
			for _, child in ipairs(task.children) do
				if not check(child) then
					return false
				end
			end
		end
		return true
	end
	return check(root)
end

---------------------------------------------------------------------
-- 核心功能 1：归档单个任务
---------------------------------------------------------------------

function M.archive_task(task, opts)
	opts = opts or {}

	if not task then
		return false, "任务不存在", nil
	end

	if not opts.force and not types.is_completed_status(task.status) then
		return false, "任务未完成，不能归档", { reason = "not_completed" }
	end

	local result = {
		id = task.id,
		content = task.content,
		code_deleted = false,
	}

	if task.id and not CONFIG.preserve_code_markers then
		local ok = deleter.archive_code_link(task.id)
		result.code_deleted = ok
	end

	if task.id then
		store.link.mark_archived(task.id, opts.reason or "core_archive")
	end

	return true, "归档成功", result
end

---------------------------------------------------------------------
-- 核心功能 2：归档任务组（修改版）
---------------------------------------------------------------------

function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr then
		return false, "参数错误", nil
	end

	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	local tasks = collect_tree_nodes(root_task)
	local all_ids = {}
	for _, task in ipairs(tasks) do
		if task.id then
			table.insert(all_ids, task.id)
		end
	end

	-- 修改：使用 core.status 进行状态更新
	local status = require("todo2.core.status")
	for _, id in ipairs(all_ids) do
		-- 先验证是否允许归档
		local link = store.link.get_todo(id, { verify_line = false })
		if link and not status.is_allowed(link.status, types.STATUS.ARCHIVED) then
			return false, string.format("任务 %s 状态不允许归档", id:sub(1, 6)), nil
		end

		-- 通过 status.update 统一处理
		local success = status.update(id, types.STATUS.ARCHIVED, "archive_group")
		if not success then
			return false, string.format("任务 %s 归档失败", id:sub(1, 6)), nil
		end
	end

	local code_deleted = 0
	if not CONFIG.preserve_code_markers then
		for _, id in ipairs(all_ids) do
			if deleter.archive_code_link(id) then
				code_deleted = code_deleted + 1
			end
		end
	end

	-- 修改：移动前验证所有任务都已归档
	for _, task in ipairs(tasks) do
		if task.id then
			local link = store.link.get_todo(task.id, { verify_line = false })
			if link and link.status ~= types.STATUS.ARCHIVED then
				return false, "任务状态与归档区域不一致", nil
			end
		end
	end

	M._move_to_archive_section(bufnr, tasks)

	-- 新增：移动后更新行号
	M._update_task_lines_after_move(bufnr, tasks)

	local group_result = {
		root_id = root_task.id,
		total_tasks = #tasks,
		archived_tasks = tasks,
		code_deleted_count = code_deleted,
		timestamp = os.time(),
	}

	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		ids = all_ids,
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	return true, string.format("归档任务组: %d个任务", #tasks), group_result
end

-- 修改：移动任务到归档区域（处理空归档区域）
function M._move_to_archive_section(bufnr, tasks)
	local path = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local archive_start = M._find_or_create_archive_section(bufnr, lines)

	-- 如果没有归档区域且不允许创建，追加到文件末尾
	if not archive_start then
		archive_start = #lines + 1
	end

	table.sort(tasks, function(a, b)
		return a.line_num > b.line_num
	end)

	local lines_to_move = {}
	for _, task in ipairs(tasks) do
		local line = lines[task.line_num]
		if line then
			local archived_line = line:gsub("%[x%]", CONFIG.archive_marker)
			table.insert(lines_to_move, {
				line = archived_line,
				original_line = task.line_num,
				id = task.id,
			})
		end
	end

	-- 删除原行
	for _, item in ipairs(lines_to_move) do
		vim.api.nvim_buf_set_lines(bufnr, item.original_line - 1, item.original_line, false, {})
	end

	-- 插入到归档区域
	for i, item in ipairs(lines_to_move) do
		vim.api.nvim_buf_set_lines(bufnr, archive_start + i - 1, archive_start + i - 1, false, { item.line })
		-- 记录新行号
		item.new_line_num = archive_start + i - 1
	end

	parser.invalidate_cache(path)
end

-- 新增：更新移动后的行号
function M._update_task_lines_after_move(bufnr, tasks)
	-- 重新解析文件获取新的行号
	local path = vim.api.nvim_buf_get_name(bufnr)
	local all_tasks = parser.parse_file(path, false)

	-- 创建ID到新任务的映射
	local id_to_new_task = {}
	for _, task in ipairs(all_tasks) do
		if task.id then
			id_to_new_task[task.id] = task
		end
	end

	-- 更新每个任务的存储行号
	for _, task in ipairs(tasks) do
		if task.id and id_to_new_task[task.id] then
			local link = store.link.get_todo(task.id, { verify_line = false })
			if link then
				link.line = id_to_new_task[task.id].line_num
				link.updated_at = os.time()
				store.link.update_todo(task.id, link)
			end
		end
	end
end

-- 查找或创建归档区域（处理边界情况）
function M._find_or_create_archive_section(bufnr, lines)
	local archive_title = config.generate_archive_title()

	-- 查找现有的归档区域
	for i, line in ipairs(lines) do
		if config.is_archive_section_line(line) then
			-- 找到归档区域，检查是否为空
			local next_line = lines[i + 1]
			if next_line and next_line ~= "" then
				-- 非空归档区域，返回内容开始的行号
				return i + 1
			else
				-- 空归档区域，返回标题行+1（可以插入内容）
				return i + 1
			end
		end
	end

	-- 检查是否允许自动创建
	if not config.is_archive_auto_create() then
		return nil
	end

	-- 创建新的归档区域
	local new_lines = {
		"",
		archive_title,
		"",
	}

	local position = config.get_archive_position()
	if position == "top" then
		-- 插入到文件开头
		vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, new_lines)
		return 2 -- 返回标题后的行号（标题在第1行，内容从第2行开始）
	else
		-- 插入到文件末尾
		vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)
		return #lines + 2
	end
end

---------------------------------------------------------------------
-- 上下文匹配
---------------------------------------------------------------------
local function find_context_match(lines, context)
	if not lines or #lines == 0 or not context or #context == 0 then
		return nil
	end

	local best_match = nil
	local best_score = 0

	local target_idx = nil
	for i, ctx_line in ipairs(context) do
		if ctx_line.is_target then
			target_idx = i
			break
		end
	end

	if not target_idx then
		return nil
	end

	for i = 1, #lines do
		local match_count = 0
		local total_count = 0

		for j, ctx_line in ipairs(context) do
			local line_idx = i + (j - target_idx)
			if line_idx >= 1 and line_idx <= #lines then
				total_count = total_count + 1
				local line_content = lines[line_idx]:gsub("^%s+", ""):gsub("%s+$", "")
				local ctx_content = ctx_line.content:gsub("^%s+", ""):gsub("%s+$", "")
				if line_content == ctx_content then
					match_count = match_count + 1
				end
			end
		end

		if total_count > 0 then
			local score = match_count / total_count
			if score > best_score and score >= 0.6 then
				best_score = score
				best_match = i + (target_idx - 1)
			end
		end
	end

	return best_match
end

---------------------------------------------------------------------
-- 恢复代码标记
---------------------------------------------------------------------
function M._restore_code_from_snapshot(id, snapshot)
	if not snapshot.code or not snapshot.code.path then
		return false
	end

	local filepath = snapshot.code.path
	local tag = snapshot.code.tag or "TODO"
	local content = snapshot.code.content or ""
	local context = snapshot.code.context

	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i, line in ipairs(lines) do
		if
			(id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id)
			or (id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id)
		then
			vim.notify(
				string.format("代码标记 %s 已存在于行 %d，跳过恢复", id:sub(1, 6), i),
				vim.log.levels.INFO
			)
			return true
		end
	end

	local insert_line = nil

	if context and #context > 0 then
		insert_line = find_context_match(lines, context)
	end

	if not insert_line then
		insert_line = math.min(snapshot.code.line or 1, #lines + 1)
	end

	local prefix = comment.get_prefix(bufnr)
	local code_line = string.format("%s %s", prefix, id_utils.format_code_mark(tag, id))
	if content and content ~= "" then
		code_line = code_line .. " " .. content
	end

	table.insert(lines, insert_line, code_line)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	local link_service = require("todo2.creation.service")
	link_service.create_code_link(bufnr, insert_line, id, content, tag)

	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	vim.notify(
		string.format("已恢复代码标记 %s 到行 %d（%s）", id:sub(1, 6), insert_line, prefix),
		vim.log.levels.INFO
	)

	return true
end

---------------------------------------------------------------------
-- 恢复TODO任务
---------------------------------------------------------------------
function M._restore_todo_from_snapshot(id, snapshot, bufnr)
	if not snapshot.task or not snapshot.task.path then
		return false
	end

	local filepath = snapshot.task.path
	local line_num = snapshot.task.line_num
	local status = snapshot.task.status
	local content = snapshot.task.content
	local tag = snapshot.task.tag or "TODO"
	local level = snapshot.task.level or 0
	local indent = string.rep("  ", level)

	local todo_bufnr = bufnr
	if not todo_bufnr or todo_bufnr == 0 then
		todo_bufnr = vim.fn.bufadd(filepath)
		vim.fn.bufload(todo_bufnr)
	end

	local lines = vim.api.nvim_buf_get_lines(todo_bufnr, 0, -1, false)

	for i, line in ipairs(lines) do
		if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
			vim.notify(
				string.format("TODO任务 %s 已存在于行 %d，跳过恢复", id:sub(1, 6), i),
				vim.log.levels.INFO
			)
			return true
		end
	end

	local insert_line = math.min(line_num, #lines + 1)

	local checkbox
	if status == types.STATUS.COMPLETED then
		checkbox = "[x]"
	elseif status == types.STATUS.ARCHIVED then
		checkbox = "[>]"
	else
		checkbox = "[ ]"
	end

	local task_line_parts = {}
	table.insert(task_line_parts, indent)
	table.insert(task_line_parts, "- ")
	table.insert(task_line_parts, checkbox)
	table.insert(task_line_parts, " ")
	if tag and tag ~= "" then
		table.insert(task_line_parts, tag)
		table.insert(task_line_parts, ": ")
	end
	table.insert(task_line_parts, content)
	table.insert(task_line_parts, " " .. id_utils.format_todo_anchor(id))

	local task_line = table.concat(task_line_parts, "")

	table.insert(lines, insert_line, task_line)
	vim.api.nvim_buf_set_lines(todo_bufnr, 0, -1, false, lines)

	local todo_link = store.link.get_todo(id, { verify_line = false })
	if todo_link then
		if status == types.STATUS.ARCHIVED then
			todo_link.status = types.STATUS.COMPLETED
			todo_link.completed_at = snapshot.task.completed_at or os.time()
		else
			todo_link.status = status
			if status == types.STATUS.COMPLETED then
				todo_link.completed_at = snapshot.task.completed_at or os.time()
			end
		end
		todo_link.line = insert_line
		todo_link.updated_at = os.time()
		store.link.update_todo(id, todo_link)
	end

	local autosave = require("todo2.core.autosave")
	autosave.request_save(todo_bufnr)

	parser.invalidate_cache(filepath)

	vim.notify(
		string.format("已恢复TODO任务 %s 到行 %d（状态: %s）", id:sub(1, 6), insert_line, checkbox),
		vim.log.levels.INFO
	)

	return true
end

---------------------------------------------------------------------
-- 修改：从归档区域移回主区域（添加边界检测）
---------------------------------------------------------------------
function M._restore_from_archive_section(bufnr, id, snapshot)
	if not snapshot.task or not snapshot.task.line_num then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local archive_start = nil
	local archive_end = nil

	-- 找到归档区域的准确范围
	for i, line in ipairs(lines) do
		if config.is_archive_section_line(line) then
			archive_start = i
			-- 查找归档区域的结束位置（下一个标题或文件结尾）
			for j = i + 1, #lines do
				if lines[j]:match("^## ") and not config.is_archive_section_line(lines[j]) then
					archive_end = j - 1
					break
				end
			end
			if not archive_end then
				archive_end = #lines
			end
			break
		end
	end

	if not archive_start then
		return
	end

	-- 在归档区域内查找任务
	local task_line_in_archive = nil
	for i = archive_start + 1, archive_end do
		if id_utils.contains_todo_anchor(lines[i]) and id_utils.extract_id_from_todo_anchor(lines[i]) == id then
			task_line_in_archive = i
			break
		end
	end

	if not task_line_in_archive then
		return
	end

	local task_line = lines[task_line_in_archive]

	-- 移除行前先记录，用于后续验证
	local line_content = task_line
	table.remove(lines, task_line_in_archive)

	-- 找到主区域的插入位置（第一个非归档标题的 ## 标题处）
	local insert_pos = 1
	for i = 1, #lines do
		if lines[i]:match("^## ") and not config.is_archive_section_line(lines[i]) then
			insert_pos = i
			break
		end
	end

	-- 新增：验证要插入的行是否真的是恢复状态
	local restored_checkbox = line_content:match("%[(.)%]")
	if restored_checkbox == ">" then
		-- 将归档标记 [>] 恢复为未完成 [ ]
		line_content = line_content:gsub("%[>%]", "[ ]")
	end

	table.insert(lines, insert_pos, line_content)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 新增：记录新行号供后续更新
	snapshot.task.new_line_num = insert_pos
end

---------------------------------------------------------------------
-- 核心功能 3：恢复归档任务（修改版）
---------------------------------------------------------------------
function M.restore_task(id, bufnr, opts)
	opts = opts or {}

	local snapshot = store.link.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照"
	end

	-- 新增：验证当前状态是否允许恢复
	local current_link = store.link.get_todo(id, { verify_line = false })
	if current_link and current_link.status ~= types.STATUS.ARCHIVED then
		return false, "任务当前不是归档状态，不能恢复"
	end

	local success, err = pcall(function()
		M._restore_from_archive_section(bufnr, id, snapshot)
		M._restore_todo_from_snapshot(id, snapshot, bufnr)
		if snapshot.code then
			M._restore_code_from_snapshot(id, snapshot)
		end
	end)

	if not success then
		vim.notify(string.format("恢复失败: %s", tostring(err)), vim.log.levels.ERROR)
		return false, "恢复过程中出错"
	end

	-- 新增：更新存储状态（通过 status.update 确保一致性）
	local status = require("todo2.core.status")
	status.update(id, types.STATUS.NORMAL, "restore_task") -- 会触发 reopen_link

	if not opts.keep_snapshot then
		store.link.delete_archive_snapshot(id)
	end

	events.on_state_changed({
		source = "restore_task",
		bufnr = bufnr,
		ids = { id },
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	return true, string.format("任务 %s 恢复成功", id:sub(1, 6))
end

---------------------------------------------------------------------
-- 核心功能 4：自动归档
---------------------------------------------------------------------
function M.auto_archive(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return { archived = 0 }
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path:match("%.todo%.md$") then
		return { archived = 0 }
	end

	local tasks, roots = parser.parse_file(path, false)

	local now = os.time()
	local cutoff = now - CONFIG.auto_archive_days * 86400
	local to_archive = {}

	for _, root in ipairs(roots) do
		local function collect_old_completed(node)
			local todo_link = node.id and store.link.get_todo(node.id, { verify_line = false })
			local status = todo_link and todo_link.status or node.status

			if status == types.STATUS.COMPLETED then
				local completed_at = todo_link and todo_link.completed_at or node.completed_at or 0
				if completed_at <= cutoff then
					table.insert(to_archive, node)
				end
			end

			if node.children then
				for _, child in ipairs(node.children) do
					collect_old_completed(child)
				end
			end
		end
		collect_old_completed(root)
	end

	if #to_archive == 0 then
		return { archived = 0 }
	end

	for _, task in ipairs(to_archive) do
		M.archive_task(task, { force = true, reason = "auto_archive" })
	end

	return { archived = #to_archive }
end

return M
