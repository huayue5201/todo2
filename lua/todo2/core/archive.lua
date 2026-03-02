-- lua/todo2/core/archive.lua (完整修复版 - 移除未使用函数)
--- @module todo2.core.archive
--- @brief 核心归档模块 - 修复区域检测边界问题

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
-- ⭐ 修复1：改进的区域检测函数
---------------------------------------------------------------------

--- 检测任务是否在归档区域
--- @param task table 任务对象
--- @param lines table|nil 文件行内容（可选）
--- @return boolean, number|nil 是否在归档区域，归档区域起始行号
function M._is_task_in_archive(task, lines)
	if not task or not task.line_num then
		return false, nil
	end

	-- 如果没有传入lines，尝试读取文件
	if not lines then
		if not task.path then
			return false, nil
		end
		local bufnr = vim.fn.bufnr(task.path)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		else
			local ok, file_lines = pcall(vim.fn.readfile, task.path)
			if ok then
				lines = file_lines
			end
		end
	end

	if not lines or #lines == 0 then
		return false, nil
	end

	-- 从任务行向上查找归档区域标题
	for i = task.line_num, 1, -1 do
		if lines[i] and config.is_archive_section_line(lines[i]) then
			return true, i -- 返回是否在归档区域和区域起始行
		end
	end

	return false, nil
end

--- 获取归档区域的范围
--- @param lines table 文件行内容
--- @param archive_start_line number 归档区域起始行
--- @return number, number 区域起始行，区域结束行
function M._get_archive_range(lines, archive_start_line)
	if not lines or #lines == 0 or not archive_start_line then
		return archive_start_line, archive_start_line
	end

	local end_line = #lines

	-- 从归档区域起始行的下一行开始查找结束位置
	for i = archive_start_line + 1, #lines do
		-- 遇到下一个标题（##）且不是归档标题，则结束
		if lines[i]:match("^## ") and not config.is_archive_section_line(lines[i]) then
			end_line = i - 1
			break
		end
	end

	return archive_start_line, end_line
end

---------------------------------------------------------------------
-- ⭐ 修复2：改进的层级构建函数
---------------------------------------------------------------------

--- 构建任务的层级树
--- @param tasks table[] 任务列表
--- @return table[] 层级树
function M._build_task_hierarchy(tasks)
	local task_map = {}
	local roots = {}

	-- 创建ID到任务的映射
	for _, task in ipairs(tasks) do
		task_map[task.id] = {
			task = task,
			children = {},
			level = task.level or 0,
			line_num = task.line_num,
		}
	end

	-- 构建层级关系
	for _, node in pairs(task_map) do
		if node.task.parent and task_map[node.task.parent.id] then
			table.insert(task_map[node.task.parent.id].children, node)
		else
			table.insert(roots, node)
		end
	end

	-- 按行号排序
	local function sort_by_line(a, b)
		return a.line_num < b.line_num
	end
	table.sort(roots, sort_by_line)
	for _, node in pairs(task_map) do
		table.sort(node.children, sort_by_line)
	end

	return roots
end

--- 将层级树转换为要移动的行列表
--- @param roots table[] 层级树根节点
--- @param lines table 原始行内容
--- @return table[] 要移动的行列表（保持层级顺序）
function M._collect_lines_to_move(roots, lines)
	local result = {}

	local function collect(node)
		-- 获取原始行
		local line = lines[node.task.line_num]
		if not line then
			return
		end

		-- 转换复选框
		local archived_line = line:gsub("%[x%]", CONFIG.archive_marker):gsub("%[ %]", CONFIG.archive_marker)

		table.insert(result, {
			line = archived_line,
			original_line = node.task.line_num,
			id = node.task.id,
			level = node.level,
			parent_id = node.task.parent and node.task.parent.id,
			line_num = node.task.line_num,
		})

		-- 递归处理子任务
		if #node.children > 0 then
			-- 子任务按行号排序后收集
			table.sort(node.children, function(a, b)
				return a.line_num < b.line_num
			end)
			for _, child in ipairs(node.children) do
				collect(child)
			end
		end
	end

	-- 按行号排序根节点
	table.sort(roots, function(a, b)
		return a.line_num < b.line_num
	end)

	for _, root in ipairs(roots) do
		collect(root)
	end

	return result
end

---------------------------------------------------------------------
-- ⭐ 修复3：改进的归档区域查找/创建函数
---------------------------------------------------------------------

--- 查找或创建归档区域
--- @param bufnr number 缓冲区
--- @param lines table 行内容
--- @return number, table 插入位置, 更新后的行内容
function M._find_or_create_archive_section(bufnr, lines)
	local archive_title = config.generate_archive_title()

	-- 查找现有的归档区域
	for i = 1, #lines do
		if config.is_archive_section_line(lines[i]) then
			-- 找到归档区域后，查找插入点（第一个空行或区域末尾）
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point] ~= "" do
				insert_point = insert_point + 1
			end
			return insert_point, lines
		end
	end

	-- 创建新的归档区域
	if not config.is_archive_auto_create() then
		return nil, lines
	end

	-- 在文件末尾创建新的归档区域
	local new_lines = {
		"",
		archive_title,
		"", -- 空行用于插入内容
	}

	-- 合并行
	for _, line in ipairs(new_lines) do
		table.insert(lines, line)
	end

	-- 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines - 1, lines -- 返回空行的位置
end

---------------------------------------------------------------------
-- ⭐ 修复4：改进的移动任务到归档区域函数
---------------------------------------------------------------------

--- 移动任务到归档区域
--- @param bufnr number 缓冲区
--- @param tasks_to_move table[] 要移动的任务
--- @param archive_start number 归档区域起始插入点
--- @param lines table 行内容
--- @return table[] 更新后的任务列表（包含新行号）
function M._move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	-- 按原始行号降序删除（从后往前删，避免行号变化）
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	-- 删除原行
	for _, item in ipairs(tasks_to_move) do
		table.remove(lines, item.original_line)
	end

	-- 重新排序为原始顺序（用于插入）
	table.sort(tasks_to_move, function(a, b)
		return a.original_line < b.original_line
	end)

	-- 计算新的插入点（考虑删除后的行号变化）
	local insert_pos = archive_start
	for _, item in ipairs(tasks_to_move) do
		if item.original_line < archive_start then
			insert_pos = insert_pos - 1
		end
	end

	-- 插入到归档区域
	for i, item in ipairs(tasks_to_move) do
		local current_pos = insert_pos + i - 1
		table.insert(lines, current_pos, item.line)
		item.new_line_num = current_pos
	end

	-- 更新缓冲区
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return tasks_to_move
end

--- 更新移动后的行号到存储
--- @param tasks_to_move table[] 已移动的任务
function M._update_task_lines(tasks_to_move)
	for _, item in ipairs(tasks_to_move) do
		if item.id then
			local link = store.link.get_todo(item.id, { verify_line = false })
			if link then
				link.line = item.new_line_num
				link.updated_at = os.time()
				store.link.update_todo(item.id, link)
			end
		end
	end
end

---------------------------------------------------------------------
-- 核心功能 1：归档任务组
---------------------------------------------------------------------

function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr then
		return false, "参数错误", nil
	end

	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	-- 获取文件内容
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- ⭐ 修复：检测根任务是否已在归档区域
	local in_archive, archive_start = M._is_task_in_archive(root_task, lines)
	if in_archive then
		return false, "任务已在归档区域", nil
	end

	local tasks = collect_tree_nodes(root_task)
	local all_ids = {}
	for _, task in ipairs(tasks) do
		if task.id then
			table.insert(all_ids, task.id)
		end
	end

	-- 构建任务层级树
	local roots = M._build_task_hierarchy(tasks)

	-- 收集要移动的行
	local tasks_to_move = M._collect_lines_to_move(roots, lines)
	if #tasks_to_move == 0 then
		return false, "没有可归档的任务", nil
	end

	-- 查找或创建归档区域
	local archive_pos, updated_lines = M._find_or_create_archive_section(bufnr, lines)
	if not archive_pos then
		return false, "无法创建归档区域", nil
	end

	-- 移动任务到归档区域
	tasks_to_move = M._move_tasks_to_archive(bufnr, tasks_to_move, archive_pos, updated_lines)

	-- 更新存储状态
	for _, id in ipairs(all_ids) do
		store.link.mark_archived(id, "archive_group")
	end

	-- 更新行号
	M._update_task_lines(tasks_to_move)

	-- 处理代码标记
	local code_deleted = 0
	if not CONFIG.preserve_code_markers then
		for _, id in ipairs(all_ids) do
			if deleter.archive_code_link(id) then
				code_deleted = code_deleted + 1
			end
		end
	end

	-- 触发事件
	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		ids = all_ids,
		file = vim.api.nvim_buf_get_name(bufnr),
		timestamp = os.time() * 1000,
	})

	-- 清除解析器缓存
	parser.invalidate_cache(vim.api.nvim_buf_get_name(bufnr))

	local group_result = {
		root_id = root_task.id,
		total_tasks = #tasks,
		archived_tasks = tasks,
		code_deleted_count = code_deleted,
		timestamp = os.time(),
	}

	return true, string.format("归档任务组: %d个任务", #tasks), group_result
end

---------------------------------------------------------------------
-- 上下文匹配（保持不变）
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
-- 恢复代码标记（保持不变）
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
-- 恢复TODO任务（保持不变）
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
-- ⭐ 修复6：从归档区域移回主区域（使用改进的区域检测）
---------------------------------------------------------------------
function M._restore_from_archive_section(bufnr, id, snapshot)
	if not snapshot.task or not snapshot.task.line_num then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- ⭐ 修复：使用改进的区域检测
	local in_archive, archive_start = M._is_task_in_archive({ id = id, line_num = snapshot.task.line_num }, lines)
	if not in_archive then
		return
	end

	-- 获取归档区域范围
	local archive_start_line, archive_end_line = M._get_archive_range(lines, archive_start)

	-- 在归档区域内查找任务行
	local task_line_in_archive = nil
	for i = archive_start_line + 1, archive_end_line do
		if id_utils.contains_todo_anchor(lines[i]) and id_utils.extract_id_from_todo_anchor(lines[i]) == id then
			task_line_in_archive = i
			break
		end
	end

	if not task_line_in_archive then
		return
	end

	local task_line = lines[task_line_in_archive]

	-- 移除行
	table.remove(lines, task_line_in_archive)

	-- 找到主区域的插入位置（第一个非归档标题的 ## 标题处）
	local insert_pos = 1
	for i = 1, #lines do
		if lines[i]:match("^## ") and not config.is_archive_section_line(lines[i]) then
			insert_pos = i
			break
		end
	end

	-- 将归档标记 [>] 恢复为未完成 [ ]
	task_line = task_line:gsub("%[>%]", "[ ]")

	table.insert(lines, insert_pos, task_line)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	snapshot.task.new_line_num = insert_pos
end

---------------------------------------------------------------------
-- 核心功能 3：恢复归档任务（使用改进的区域检测）
---------------------------------------------------------------------
function M.restore_task(id, bufnr, opts)
	opts = opts or {}

	local snapshot = store.link.get_archive_snapshot(id)
	if not snapshot then
		return false, "找不到归档快照"
	end

	-- 验证当前状态是否允许恢复
	local current_link = store.link.get_todo(id, { verify_line = false })
	if current_link and current_link.status ~= types.STATUS.ARCHIVED then
		return false, "任务当前不是归档状态，不能恢复"
	end

	-- ⭐ 修复：检测任务是否在归档区域
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local in_archive = M._is_task_in_archive({ id = id, line_num = snapshot.task.line_num }, lines)
	if not in_archive then
		return false, "任务不在归档区域"
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

	-- 更新存储状态
	local todo_link = store.link.get_todo(id, { verify_line = false })
	if todo_link then
		store.link.reopen_link(id)
	end

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

	parser.invalidate_cache(vim.api.nvim_buf_get_name(bufnr))

	return true, string.format("任务 %s 恢复成功", id:sub(1, 6))
end

return M
