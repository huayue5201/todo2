-- lua/todo2/task/deleter.lua
-- 任务删除模块：精确删除任务行，确保两端渲染同步
---@module "todo2.task.deleter"

local M = {}

local id_utils = require("todo2.utils.id")
local core = require("todo2.store.task.core")
local guard = require("todo2.handlers.guard")
local relation = require("todo2.store.task.relation")
local autosave = require("todo2.core.autosave")
local events = require("todo2.core.events")
local scheduler = require("todo2.render.scheduler")
local description = require("todo2.core.description")
local parser = require("todo2.core.parser")
local tree_mod = require("todo2.core.tree")

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

---@class DeleteResult
---@field id string 任务ID
---@field todo_line_deleted boolean TODO行是否删除
---@field store_deleted boolean 存储是否删除
---@field relations_cleaned boolean 关系是否清理
---@field lines_deleted DeleteLineInfo[] 删除的行信息
---@field deleted_locations DeletedLocation[] 删除的位置信息（用于渲染清理）

---@class DeleteLineInfo
---@field path string 文件路径
---@field lines number[] 删除的行号列表
---@field type "todo"|"code" 文件类型

---@class DeletedLocation
---@field path string 文件路径
---@field line number 行号
---@field type "todo"|"code" 文件类型
---@field id string 任务ID

---@class BatchDeleteResult
---@field total number 总任务数
---@field succeeded number 成功数
---@field failed number 失败数
---@field details table[] 详细信息

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---直接从存储获取权威行号
---@param task table 任务对象
---@param location_type "todo"|"code" 位置类型
---@return number? 行号
local function get_authoritative_line(task, location_type)
	if not task then
		return nil
	end

	if location_type == "todo" and task.locations.todo then
		return task.locations.todo.line
	elseif location_type == "code" and task.locations.code then
		return task.locations.code.line
	end

	return nil
end

---验证并获取准确行号（仅 TODO 文件）
---@param task table 任务对象
---@param bufnr number 缓冲区号
---@return number? 准确的行号
local function validate_and_get_todo_line(task, bufnr)
	local stored_line = get_authoritative_line(task, "todo")
	if stored_line then
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		if stored_line >= 1 and stored_line <= line_count then
			local line_content = vim.api.nvim_buf_get_lines(bufnr, stored_line - 1, stored_line, false)[1]
			if line_content and id_utils.extract_id_from_line(line_content) == task.id then
				return stored_line
			end
		end
	end

	-- 存储行号可能已过期（前序删除/外部编辑尚未同步）：回退为在缓冲区内按 id 重定位。
	-- 没有这层回退时，删除会因行号错位而漏删文件行、只删掉 store 记录。
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i, l in ipairs(lines) do
		if id_utils.extract_id_from_line(l) == task.id then
			return i
		end
	end

	return nil
end

---删除文件中的指定行
---@param filepath string 文件路径
---@param lines number[] 要删除的行号列表
---@param bufnr_cache table<string,number> 缓冲区缓存
---@return number[] 实际删除的行号
local function delete_file_lines(filepath, lines, bufnr_cache)
	if not filepath or not lines or #lines == 0 then
		return {}
	end

	local bufnr = vim.fn.bufadd(filepath)
	require("todo2.utils.buffer").ensure_loaded(bufnr)

	if bufnr_cache then
		bufnr_cache[filepath] = bufnr
	end

	-- 从大到小排序，避免行号变化影响
	table.sort(lines, function(a, b)
		return a > b
	end)

	local deleted_lines = {}
	for _, lnum in ipairs(lines) do
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		if lnum >= 1 and lnum <= line_count then
			local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, lnum - 1, lnum, false, {})
			if ok then
				table.insert(deleted_lines, lnum)
			end
		end
	end

	if #deleted_lines > 0 then
		autosave.request_save(bufnr)
	end

	return deleted_lines
end

---删除后立即刷新渲染
---@param ids string[] 任务ID列表
---@param files string[] 文件路径列表
---@param deleted_locations DeletedLocation[] 删除的位置信息
local function refresh_after_delete(ids, files, deleted_locations)
	-- 合并所有需要刷新的文件（TODO 文件 + 删除位置对应的代码文件）
	local all_files = {}
	for _, filepath in ipairs(files or {}) do
		if not vim.tbl_contains(all_files, filepath) then
			table.insert(all_files, filepath)
		end
	end
	for _, loc in ipairs(deleted_locations or {}) do
		if loc and loc.path and not vim.tbl_contains(all_files, loc.path) then
			table.insert(all_files, loc.path)
		end
	end

	-- 先触发事件，包含位置信息
	events.emit("delete_by_id", {
		changed_ids = ids,
		files = files,
		deleted_locations = deleted_locations,
	})

	-- 立即刷新每个文件
	for _, filepath in ipairs(all_files) do
		local bufnr = vim.fn.bufnr(filepath)
		if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
			scheduler.refresh(bufnr, {
				from_event = true,
				force_refresh = true,
				changed_ids = ids,
				deleted_locations = deleted_locations,
			})
		end
	end
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---根据ID删除单个任务
---@param id string 任务ID
---@return boolean success 是否成功
---@return DeleteResult result 删除结果
function M.delete_by_id(id)
	if not id or not id_utils.is_valid(id) then
		vim.notify("Delete failed: invalid ID format", vim.log.levels.ERROR)
		return false, { id = id, error = "invalid_id" }
	end

	local result = {
		id = id,
		todo_line_deleted = false,
		store_deleted = false,
		relations_cleaned = false,
		lines_deleted = {},
		deleted_locations = {},
	}

	-- 1. 获取任务
	local task = core.get_task(id)
	if not task then
		return true, result
	end

	-- 收集文件及行号
	local files = {}
	local lines_to_delete = {}
	local bufnr_cache = {}
	local deleted_locations = {}

	-- TODO 文件（需要删除任务行 + 该任务的正文块）
	if task.locations.todo and task.locations.todo.path then
		local bufnr = vim.fn.bufadd(task.locations.todo.path)
		require("todo2.utils.buffer").ensure_loaded(bufnr)
		local line = validate_and_get_todo_line(task, bufnr)
		if line then
			table.insert(files, task.locations.todo.path)
			local targets = lines_to_delete[task.locations.todo.path] or {}
			lines_to_delete[task.locations.todo.path] = targets
			table.insert(targets, line)

			-- 正文与任务强绑定：连同正文块一起删（delete_file_lines 会按行号倒序删）
			local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local block = description.block_at(buf_lines, line)
			if block then
				for i = block.start_line, block.end_line do
					table.insert(targets, i)
				end
			end

			table.insert(deleted_locations, {
				path = task.locations.todo.path,
				line = line,
				type = "todo",
				id = id,
			})
		end
	end

	-- 代码文件：只清理渲染，不删除代码行
	if task.locations.code and task.locations.code.path then
		local line = task.locations.code.line
		if line then
			table.insert(deleted_locations, {
				path = task.locations.code.path,
				line = line,
				type = "code",
				id = id,
			})
		end
	end

	-- 2. 删除 TODO 文件行
	for filepath, lines in pairs(lines_to_delete) do
		local deleted = delete_file_lines(filepath, lines, bufnr_cache)
		if #deleted > 0 then
			result.todo_line_deleted = true
			table.insert(result.lines_deleted, {
				path = filepath,
				lines = deleted,
				type = "todo",
			})
		end
	end

	-- 3. 删除存储。core.delete_task 内部已一并清理父子关系与索引并写入
	--    删除墓碑，这里不再重复清理。
	result.store_deleted = core.delete_task(id)
	result.relations_cleaned = result.store_deleted
	result.deleted_locations = deleted_locations

	-- 7. 刷新渲染
	if #files > 0 or #deleted_locations > 0 then
		refresh_after_delete({ id }, files, deleted_locations)
	end

	if result.todo_line_deleted then
		vim.notify(("✅ Deleted ID %s"):format(id:sub(1, 6)), vim.log.levels.INFO)
	end

	return true, result
end

---批量删除多个任务
---@param ids string[] 任务ID列表
---@return boolean success 是否至少有一个成功
---@return BatchDeleteResult result 批量删除结果
---@param ids string[]
---@param opts? { mode?: "forbid"|"cascade"|"promote" } 同 M.delete
function M.delete_by_ids(ids, opts)
	if not ids or #ids == 0 then
		return false, { error = "no_ids" }
	end

	local ok_cnt, fail_cnt = 0, 0
	local details = {}
	local all_files = {}
	local all_ids = {}
	local all_deleted_locations = {}

	for _, id in ipairs(ids) do
		local ok, res = M.delete(id, opts)
		if ok then
			ok_cnt = ok_cnt + 1
			table.insert(details, { id = id, success = true, result = res })
			table.insert(all_ids, id)

			for _, line_info in ipairs(res.lines_deleted or {}) do
				if not vim.tbl_contains(all_files, line_info.path) then
					table.insert(all_files, line_info.path)
				end
			end

			for _, loc in ipairs(res.deleted_locations or {}) do
				table.insert(all_deleted_locations, loc)
			end
		else
			fail_cnt = fail_cnt + 1
			table.insert(details, { id = id, success = false, error = res.error })
		end
	end

	if #all_ids > 0 and (#all_files > 0 or #all_deleted_locations > 0) then
		refresh_after_delete(all_ids, all_files, all_deleted_locations)
	end

	local level = (fail_cnt == 0) and vim.log.levels.INFO or vim.log.levels.WARN
	vim.notify(("Deletion complete: %d succeeded, %d failed"):format(ok_cnt, fail_cnt), level)

	return ok_cnt > 0, {
		total = #ids,
		succeeded = ok_cnt,
		failed = fail_cnt,
		details = details,
	}
end

---根据ID删除任务及其整棵子树。
---折叠态下光标只能落在一个父任务上，若只删父任务，子任务会变成无父的
---游离任务残留在文件与 store 中；因此抽屉的 <BS> 走这里。
---关键：必须在缓冲区未改动时一次性解析整棵子树的待删行（含正文块）。
---逐个删除会因「删父后子任务行号整体上移」而校验失败，导致漏删文件行、
---只删掉 store 记录，留下更隐蔽的文件/store 漂移。
---@param root_id string 子树根任务ID
---@return boolean success 是否删除了至少一个任务
---@return BatchDeleteResult result
---删除整棵子树。归档任务是冻结态，除 `opts.allow_archived` 外一律拒绝。
---@param root_id string
---@param opts? { allow_archived?: boolean }
function M.delete_subtree(root_id, opts)
	opts = opts or {}
	if not root_id or not id_utils.is_valid(root_id) then
		vim.notify("Delete failed: invalid ID format", vim.log.levels.ERROR)
		return false, { id = root_id, error = "invalid_id" }
	end

	if not opts.allow_archived and guard.is_frozen(core.get_task(root_id)) then
		return false, { id = root_id, error = "archived", message = "task is archived; unarchive it first (:TodoUnarchive)" }
	end

	local ids = relation.get_subtree_ids(root_id)

	-- 阶段一：缓冲区未改动时，解析整棵子树的待删行。
	local targets_by_file = {}
	local files = {}
	local bufnr_cache = {}
	local deleted_locations = {}
	local valid_ids = {}

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task then
			valid_ids[#valid_ids + 1] = id

			if task.locations.todo and task.locations.todo.path then
				local path = task.locations.todo.path
				local bufnr = vim.fn.bufadd(path)
				require("todo2.utils.buffer").ensure_loaded(bufnr)
				bufnr_cache[path] = bufnr
				local line = validate_and_get_todo_line(task, bufnr)
				if line then
					if not vim.tbl_contains(files, path) then
						files[#files + 1] = path
					end
					local set = targets_by_file[path] or {}
					targets_by_file[path] = set
					set[line] = true
					local block = description.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), line)
					if block then
						for i = block.start_line, block.end_line do
							set[i] = true
						end
					end
					deleted_locations[#deleted_locations + 1] = {
						path = path,
						line = line,
						type = "todo",
						id = id,
					}
				end
			end

			-- 代码文件：只清理渲染，不删除代码行
			if task.locations.code and task.locations.code.path and task.locations.code.line then
				deleted_locations[#deleted_locations + 1] = {
					path = task.locations.code.path,
					line = task.locations.code.line,
					type = "code",
					id = id,
				}
			end
		end
	end

	-- 阶段二：按文件倒序删行（delete_file_lines 内部已按行号倒序）。
	for path, set in pairs(targets_by_file) do
		local list = {}
		for lnum in pairs(set) do
			list[#list + 1] = lnum
		end
		delete_file_lines(path, list, bufnr_cache)
	end

	-- 阶段三：删除 store（core.delete_task 内部会清理父子关系 / 索引 / 写墓碑）。
	for _, id in ipairs(valid_ids) do
		core.delete_task(id)
	end

	-- 阶段四：刷新渲染。
	if #valid_ids > 0 and (#files > 0 or #deleted_locations > 0) then
		refresh_after_delete(valid_ids, files, deleted_locations)
	end

	if #valid_ids > 0 then
		vim.notify(("✅ Deleted %d task(s) [%s]"):format(#valid_ids, root_id:sub(1, 6)), vim.log.levels.INFO)
	end

	return #valid_ids > 0, { total = #ids, succeeded = #valid_ids, ids = valid_ids }
end

---------------------------------------------------------------------
-- 显式删除语义入口：forbid / cascade / promote
---------------------------------------------------------------------

---删除任务，子节点提升一级（各自的缩进各减一个 step）。
---@param id string 任务ID
---@return boolean success
---@return DeleteResult result
---删除自身、子任务提升一级。归档任务同 `delete_subtree` 一样受守卫。
---@param id string
---@param opts? { allow_archived?: boolean }
function M.delete_promote(id, opts)
	opts = opts or {}
	if not id or not id_utils.is_valid(id) then
		vim.notify("Delete failed: invalid ID format", vim.log.levels.ERROR)
		return false, { id = id, error = "invalid_id" }
	end

	if not opts.allow_archived and guard.is_frozen(core.get_task(id)) then
		return false, { id = id, error = "archived", message = "task is archived; unarchive it first (:TodoUnarchive)" }
	end

	local task = core.get_task(id)
	if not task then
		return true, { id = id }
	end

	local children = relation.get_child_ids(id)
	local parent = relation.get_parent_id(id)

	local loc = task.locations and task.locations.todo
	if not (loc and loc.path) then
		-- 无文件行：直接删 store 节点，并把子节点挂到祖父（parent 为 nil 即成根）
		core.delete_task(id)
		if parent then
			for _, cid in ipairs(children) do
				relation.set_parent_child(parent, cid)
			end
		end
		return true, { id = id, todo_line_deleted = false, store_deleted = true, promoted = children }
	end

	local path = loc.path
	local bufnr = vim.fn.bufadd(path)
	require("todo2.utils.buffer").ensure_loaded(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local forest = parser.parse(path, lines)
	local node = forest.by_id and forest.by_id[id]
	if not node then
		-- 解析不到节点（行已被手改等）：退化为单叶删除
		return M.delete_by_id(id)
	end

	local step = tree_mod.indent_step()
	local lnum = node.line_num
	local own_end = description.block_end(lines, lnum)
	local subtree_last = description.subtree_end(lines, node)

	local new_lines = {}
	for i = 1, #lines do
		-- 跳过任务行与其自身正文块
		if not (i == lnum or (i > lnum and i <= own_end)) then
			local l = lines[i]
			if i > own_end and i <= subtree_last and l:match("^%s") and l ~= "" then
				-- 子孙整体上提一级：去掉最多 step 个前导空格
				local removed = 0
				local j = 1
				while removed < step and j <= #l and l:sub(j, j) == " " do
					removed = removed + 1
					j = j + 1
				end
				l = l:sub(j)
			end
			new_lines[#new_lines + 1] = l
		end
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	autosave.request_save(bufnr)

	-- 写墓碑并清理 store 节点；随后按文件重建关系（子已上提，挂到祖父）
	core.delete_task(id)
	pcall(function()
		require("todo2.core.sync").sync_todo_file(path)
	end)

	refresh_after_delete({ id }, { path }, { { path = path, line = lnum, type = "todo", id = id } })

	return true, {
		id = id,
		todo_line_deleted = true,
		store_deleted = true,
		promoted = children,
		lines_deleted = { { path = path, lines = { lnum }, type = "todo" } },
	}
end

---统一删除入口：显式声明删父语义。
---@param id string 任务ID
---@param opts? { mode?: "forbid"|"cascade"|"promote" } 默认 "forbid"
---  forbid  = 有子节点则拒绝（最安全）
---  cascade = 连同整棵子树删除
---  promote = 只删自身，子节点提升一级
---@return boolean success
---@return table result
function M.delete(id, opts)
	opts = opts or {}
	local mode = opts.mode or "forbid"

	if not id or not id_utils.is_valid(id) then
		return false, { id = id, error = "invalid_id" }
	end
	if not core.get_task(id) then
		-- 已删除/不存在：幂等成功
		return true, { id = id, deleted = false, missing = true }
	end

	if not opts.allow_archived and guard.is_frozen(core.get_task(id)) then
		return false, {
			id = id,
			error = "archived",
			message = "task is archived; unarchive it first (:TodoUnarchive)",
		}
	end

	local children = relation.get_child_ids(id)

	if mode == "cascade" then
		return M.delete_subtree(id, opts)
	elseif mode == "promote" then
		return M.delete_promote(id, opts)
	elseif mode ~= "forbid" then
		return false, { id = id, error = "invalid_mode", mode = mode }
	end

	if #children > 0 then
		return false, {
			id = id,
			error = "has_children",
			children = children,
			message = ("task %s has %d child task(s); specify mode = \"cascade\" or \"promote\""):format(
				id:sub(1, 6),
				#children
			),
		}
	end

	return M.delete_by_id(id)
end

return M
