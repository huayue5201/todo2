-- lua/todo2/core/archive.lua
-- lua/todo2/core/archive.lua
--- @module todo2.core.archive
--- @brief 可逆归档：移动整棵任务组到归档区域，并支持恢复到原位置

local M = {}

local types = require("todo2.store.types")
local link = require("todo2.store.link")
local scheduler = require("todo2.render.scheduler")
local parser = require("todo2.core.parser")
local events = require("todo2.core.events")
local id_utils = require("todo2.utils.id")
local comment = require("todo2.utils.comment") -- 新增
local config = require("todo2.config")

---------------------------------------------------------------------
-- 文件读写工具（避免反复调用 vim.fn）
---------------------------------------------------------------------
local function read_file_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	return ok and lines or {}
end

local function write_file_lines(path, lines)
	pcall(vim.fn.writefile, lines, path)
end

---------------------------------------------------------------------
-- 禁止多 ID 行：检测一行是否包含多个 {#id}
---------------------------------------------------------------------
local function line_has_multiple_ids(line)
	local ids = {}
	-- 使用 id_utils 的 TODO 锚点模式
	for id in line:gmatch(id_utils.TODO_ANCHOR_PATTERN) do
		table.insert(ids, id)
	end
	return #ids > 1, ids
end

---------------------------------------------------------------------
-- 删除整行代码标记（你的选择 C）
---------------------------------------------------------------------
local function delete_entire_code_line(id)
	local code_link = link.get_code(id, { verify_line = false })
	if not code_link or not code_link.path or not code_link.line then
		return
	end

	local path = code_link.path
	local line_num = code_link.line
	local lines = read_file_lines(path)

	if line_num <= #lines then
		table.remove(lines, line_num)
		write_file_lines(path, lines)
		link.shift_lines(path, line_num, -1, { skip_archived = false })
	end
end

---------------------------------------------------------------------
-- 恢复整行代码标记（撤销归档时）
---------------------------------------------------------------------
local function restore_code_line_from_snapshot(snapshot)
	if not snapshot or not snapshot.code then
		return
	end

	local path = snapshot.code.path
	local line = snapshot.code.line
	local tag = snapshot.code.tag or "TODO"
	local id = snapshot.id

	-- 使用 comment 模块获取注释前缀
	local prefix = comment.get_prefix_by_path(path)
	-- 只恢复代码标记：// FIX:ref:9d1930
	local code_mark = id_utils.format_code_mark(tag, id)
	local code_line = string.format("%s %s", prefix, code_mark)

	local lines = read_file_lines(path)
	line = math.max(1, math.min(line, #lines + 1))
	table.insert(lines, line, code_line)
	write_file_lines(path, lines)

	link.shift_lines(path, line, 1, { skip_archived = false })
end

---------------------------------------------------------------------
-- 工具：收集整棵子树（DFS）
-- 返回一个扁平数组，包含 root 及所有子任务
---------------------------------------------------------------------
local function collect_tree_nodes(root, result)
	result = result or {}
	table.insert(result, root)
	for _, child in ipairs(root.children or {}) do
		collect_tree_nodes(child, result)
	end
	return result
end

---------------------------------------------------------------------
-- 工具：获取任务的权威状态（优先使用存储层）
---------------------------------------------------------------------
local function get_authoritative_status(task)
	if not task or not task.id then
		return task and task.status
	end
	local todo_link = link.get_todo(task.id, { verify_line = false })
	return todo_link and todo_link.status or task.status
end

---------------------------------------------------------------------
-- 任务组是否全部完成（必须整棵子树全部完成）
---------------------------------------------------------------------
local function is_tree_completed(root)
	local function check(node)
		if not types.is_completed_status(get_authoritative_status(node)) then
			return false
		end
		for _, c in ipairs(node.children or {}) do
			if not check(c) then
				return false
			end
		end
		return true
	end
	return check(root)
end

---------------------------------------------------------------------
-- 查找/创建归档区域插入点
-- 归档区域格式：
--   <空行>
--   ## Archived (2026-03)
--   <空行>
--   <归档内容...>
--
-- ⭐ 关键约定：返回值 insert_pos 表示「归档内容的起始位置」，
--             即标题和其后的空行之后的第一个位置（可能是 #lines + 1）
---------------------------------------------------------------------
local function find_or_create_archive_section(bufnr, lines)
	local archive_title = config.generate_archive_title()

	-- 1. 查找已有归档区域
	for i, line in ipairs(lines) do
		if config.is_archive_section_line(line) then
			-- i 是归档标题行
			-- 从标题下一行开始，跳过所有空行，找到真正内容起点
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point]:match("^%s*$") do
				insert_point = insert_point + 1
			end
			-- 允许 insert_point == #lines + 1（表示当前还没有内容）
			return insert_point, lines
		end
	end

	-- 2. 没有归档区域 → 自动创建
	if not config.is_archive_auto_create() then
		return nil, lines
	end

	-- 在文件末尾追加：
	--   <空行>
	--   ## Archived (xxxx-xx)
	--   <空行>
	local new_lines = {
		"",
		archive_title,
		"",
	}

	for _, l in ipairs(new_lines) do
		table.insert(lines, l)
	end

	-- 写回 buffer
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 此时布局为：
	--   ...原内容...
	--   <空行>        (#lines-2)
	--   ## Archived   (#lines-1)
	--   <空行>        (#lines)
	--
	-- 归档内容应该插在最后一个空行之后，即 #lines + 1
	return #lines + 1, lines
end

---------------------------------------------------------------------
-- 构建任务组的层级节点（按行号排序）
---------------------------------------------------------------------
local function build_task_hierarchy(tasks)
	local node_map = {}
	local roots = {}

	-- 1. 构建节点表
	for _, task in ipairs(tasks) do
		node_map[task.id] = {
			task = task,
			children = {},
			level = task.level or 0,
			line_num = task.line_num,
		}
	end

	-- 2. 建立父子关系
	for _, node in pairs(node_map) do
		local parent = node.task.parent and node_map[node.task.parent.id] or nil
		if parent then
			table.insert(parent.children, node)
		else
			table.insert(roots, node)
		end
	end

	-- 3. 按行号排序
	local function sort_by_line(a, b)
		return a.line_num < b.line_num
	end

	table.sort(roots, sort_by_line)
	for _, node in pairs(node_map) do
		table.sort(node.children, sort_by_line)
	end

	return roots
end

---------------------------------------------------------------------
-- 收集要移动的行（保持父子顺序 + 替换为归档标记 [>]）
---------------------------------------------------------------------
local function collect_lines_to_move(roots, lines)
	local result = {}

	local function collect(node)
		local line = lines[node.task.line_num]
		if not line then
			return
		end

		-- 替换 checkbox 为归档标记
		local archived_line = line
		archived_line = archived_line:gsub("%[x%]", "[>]")
		archived_line = archived_line:gsub("%[%s%]", "[>]")

		table.insert(result, {
			line = archived_line,
			original_line = node.task.line_num,
			id = node.task.id,
			level = node.level,
			parent_id = node.task.parent and node.task.parent.id or nil,
			line_num = node.task.line_num,
		})

		for _, child in ipairs(node.children) do
			collect(child)
		end
	end

	-- 按行号排序根节点
	table.sort(roots, function(a, b)
		return a.line_num < b.line_num
	end)

	-- DFS 收集整棵树
	for _, root in ipairs(roots) do
		collect(root)
	end

	return result
end

---------------------------------------------------------------------
-- 从主区域删除行，并插入到归档区域
-- 关键要求：
--   1. 删除必须从大到小，否则行号会错乱
--   2. 插入必须从小到大，保持父子顺序
--   3. 插入点必须根据归档区域位置动态调整
--
-- ⭐ 约定：archive_start 可以是 1..#lines+1，
--         表示「归档内容的起始位置」（标题和空行之后）
---------------------------------------------------------------------
local function move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	-- 1. 按原行号从大到小删除（避免偏移）
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	for _, item in ipairs(tasks_to_move) do
		if lines[item.original_line] then
			table.remove(lines, item.original_line)
		end
	end

	-- 2. 按原行号从小到大插入（保持父子顺序）
	table.sort(tasks_to_move, function(a, b)
		return a.original_line < b.original_line
	end)

	-- 计算插入点偏移（删除前后行号变化）
	local insert_pos = archive_start
	for _, item in ipairs(tasks_to_move) do
		if item.original_line < archive_start then
			insert_pos = insert_pos - 1
		end
	end

	-- 3. 插入归档行
	for i, item in ipairs(tasks_to_move) do
		local pos = insert_pos + i - 1
		-- 允许 pos == #lines + 1（在文件末尾追加）
		table.insert(lines, pos, item.line)
		item.new_line_num = pos
	end

	-- 写回 buffer
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return tasks_to_move
end

---------------------------------------------------------------------
-- 更新链接中的行号（归档后）
---------------------------------------------------------------------
local function update_task_lines_after_archive(tasks_to_move)
	for _, item in ipairs(tasks_to_move) do
		if item.id then
			local todo_link = link.get_todo(item.id, { verify_line = false })
			if todo_link then
				todo_link.line = item.new_line_num
				todo_link.updated_at = os.time()
				todo_link.archived_at = todo_link.archived_at or os.time()
				link.update_todo(item.id, todo_link)
			end
		end
	end
end

---------------------------------------------------------------------
-- 归档任务组（整棵子树 + 删除代码标记 + 保存快照）
---------------------------------------------------------------------
function M.archive_task_group(root_task, bufnr, opts)
	opts = opts or {}

	if not root_task or not bufnr or bufnr == 0 then
		return false, "参数错误", nil
	end

	-- 1. 业务规则：任务组必须全部完成（除非 force）
	if not opts.force and not is_tree_completed(root_task) then
		return false, "任务组中存在未完成的任务", nil
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return false, "无法获取文件路径", nil
	end

	-- 2. 获取最新文件内容（通过 scheduler，保持与渲染一致）
	local lines = scheduler.get_file_lines(path, true)
	if not lines or #lines == 0 then
		return false, "文件内容为空", nil
	end

	-- 3. 收集整棵子树
	local tasks = collect_tree_nodes(root_task)
	if #tasks == 0 then
		return false, "没有可归档的任务", nil
	end

	-- 4. 收集所有 ID
	local all_ids = {}
	for _, t in ipairs(tasks) do
		if t.id then
			table.insert(all_ids, t.id)
		end
	end

	-- 5. 禁止多 ID 行
	for _, id in ipairs(all_ids) do
		local code_link = link.get_code(id, { verify_line = false })
		if code_link and code_link.path and code_link.line then
			local code_lines = read_file_lines(code_link.path)
			local line = code_lines[code_link.line]
			if line then
				local has_multiple, ids = line_has_multiple_ids(line)
				if has_multiple then
					return false,
						string.format(
							"代码行包含多个 ID（%s），无法归档。请拆分成多行。",
							table.concat(ids, ", ")
						),
						nil
				end
			end
		end
	end

	-- 6. 删除代码侧标记
	for _, id in ipairs(all_ids) do
		delete_entire_code_line(id)
	end

	-- 7. 保存快照
	for _, id in ipairs(all_ids) do
		link.save_archive_snapshot(id)
	end

	-- 8. 构建层级树并收集要移动的行
	local roots = build_task_hierarchy(tasks)
	local tasks_to_move = collect_lines_to_move(roots, lines)
	if #tasks_to_move == 0 then
		return false, "没有可归档的任务行", nil
	end

	-- 9. 查找或创建归档区域
	local archive_pos, updated_lines = find_or_create_archive_section(bufnr, lines)
	if not archive_pos then
		return false, "无法创建归档区域", nil
	end

	-- 10. 移动文本到归档区域
	tasks_to_move = move_tasks_to_archive(bufnr, tasks_to_move, archive_pos, updated_lines)

	-- 11. 标记所有任务为 ARCHIVED
	for _, id in ipairs(all_ids) do
		link.mark_archived(id, "archive_group")
	end

	-- 12. 更新链接中的行号
	update_task_lines_after_archive(tasks_to_move)

	-- ⭐ 13. 保存文件（必须）
	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	-- ⭐ 14. 触发事件系统（必须包含 files 字段）
	events.on_state_changed({
		source = "archive_group",
		bufnr = bufnr,
		file = path,
		files = { path }, -- ⭐ 必须显式传入
		ids = all_ids,
		timestamp = os.time() * 1000,
	})

	-- ⭐ 15. scheduler 缓存失效（必须在保存之后）
	scheduler.invalidate_cache(path)

	return true,
		string.format("归档任务组: %d 个任务", #tasks),
		{
			root_id = root_task.id,
			total_tasks = #tasks,
			archived_ids = all_ids,
		}
end

---------------------------------------------------------------------
-- 工具：在当前文件中查找某个 ID 对应的 TODO 行号
---------------------------------------------------------------------
local function find_todo_line_for_id(lines, id)
	for i, line in ipairs(lines) do
		-- 使用 id_utils 检测 TODO 锚点
		if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
			return i
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 撤销归档任务组：从归档区域恢复整棵子树到原位置
---------------------------------------------------------------------
function M.unarchive_task_group(root_id, bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return false, "无法获取文件路径"
	end

	local group = link.get_task_group(root_id, { include_archived = true })
	if not group or #group == 0 then
		return false, "找不到任务组"
	end

	local lines = scheduler.get_file_lines(path, true)
	local moves = {}

	for _, todo_link in ipairs(group) do
		local id = todo_link.id
		local snapshot = link.get_archive_snapshot(id)
		if snapshot and snapshot.todo and snapshot.todo.path == path then
			local current_line = nil
			for i, line in ipairs(lines) do
				if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
					current_line = i
					break
				end
			end

			local target_line = snapshot.todo.line_num or todo_link.line or 1
			target_line = math.max(1, math.min(target_line, #lines + 1))

			local level = snapshot.todo.level or 0
			local indent = snapshot.todo.indent or string.rep("  ", level)
			local status = snapshot.todo.status or types.STATUS.NORMAL
			local checkbox = (status == types.STATUS.COMPLETED) and "[x]" or "[ ]"
			local tag = snapshot.todo.tag or "TODO"
			local content = snapshot.todo.content or ""

			local text = string.format(
				"%s- %s %s%s %s",
				indent,
				checkbox,
				tag ~= "" and (tag .. ": ") or "",
				content,
				id_utils.format_todo_anchor(id)
			)

			table.insert(moves, {
				id = id,
				current_line = current_line,
				target_line = target_line,
				text = text,
				snapshot = snapshot,
			})
		end
	end

	-- 删除旧行
	table.sort(moves, function(a, b)
		return (a.current_line or 0) > (b.current_line or 0)
	end)
	for _, m in ipairs(moves) do
		if m.current_line and lines[m.current_line] then
			table.remove(lines, m.current_line)
		end
	end

	-- 插入新行
	table.sort(moves, function(a, b)
		return a.target_line < b.target_line
	end)
	for i, m in ipairs(moves) do
		local pos = math.min(m.target_line + i - 1, #lines + 1)
		table.insert(lines, pos, m.text)
		m.new_line = pos
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- 更新链接
	local restored_ids = {}
	for _, m in ipairs(moves) do
		link.unarchive_link(m.id, { delete_snapshot = false })
		local todo_link = link.get_todo(m.id, { verify_line = false })
		if todo_link then
			todo_link.line = m.new_line
			todo_link.updated_at = os.time()
			link.update_todo(m.id, todo_link)
		end
		table.insert(restored_ids, m.id)
	end

	-- 恢复代码标记
	for _, m in ipairs(moves) do
		restore_code_line_from_snapshot(m.snapshot)
	end

	-- ⭐ 保存文件
	local autosave = require("todo2.core.autosave")
	autosave.request_save(bufnr)

	-- ⭐ 触发事件
	events.on_state_changed({
		source = "unarchive_group",
		file = path,
		files = { path },
		bufnr = bufnr,
		ids = restored_ids,
		timestamp = os.time() * 1000,
	})

	-- ⭐ 缓存失效
	scheduler.invalidate_cache(path)

	return true, "恢复归档任务组: " .. tostring(#restored_ids) .. " 个任务"
end

return M
