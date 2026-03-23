-- lua/todo2/task/deleter.lua
-- 任务删除模块：精确删除任务行，确保两端渲染同步
---@module "todo2.task.deleter"

local M = {}

local id_utils = require("todo2.utils.id")
local line_analyzer = require("todo2.utils.line_analyzer")
local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local relation = require("todo2.store.link.relation")
local autosave = require("todo2.core.autosave")
local events = require("todo2.core.events")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

---@class DeleteResult
---@field id string 任务ID
---@field todo_line_deleted boolean TODO行是否删除
---@field code_line_deleted boolean 代码行是否删除
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

---验证并获取准确行号
---@param task table 任务对象
---@param location_type "todo"|"code" 位置类型
---@param bufnr number 缓冲区号
---@return number? 准确的行号
local function validate_and_get_line(task, location_type, bufnr)
	local stored_line = get_authoritative_line(task, location_type)
	if not stored_line then
		return nil
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if stored_line < 1 or stored_line > line_count then
		return nil
	end

	local line_content = vim.api.nvim_buf_get_lines(bufnr, stored_line - 1, stored_line, false)[1]
	if line_content and id_utils.extract_id(line_content) == task.id then
		return stored_line
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
	vim.fn.bufload(bufnr)

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

---清理任务的所有关系
---@param task table 任务对象
local function cleanup_relations(task)
	if not task or not task.id then
		return
	end

	-- 1. 如果有父任务，从父任务的child_ids中移除
	local parent_id = relation.get_parent_id(task.id)
	if parent_id then
		relation.remove_child(parent_id, task.id)
	end

	-- 2. 如果有子任务，删除所有子任务的关系（递归清理）
	local child_ids = relation.get_child_ids(task.id)
	for _, child_id in ipairs(child_ids) do
		relation.remove_child(task.id, child_id)
	end
end

---删除后立即刷新两端渲染（增强版：传递删除的位置信息）
---@param ids string[] 任务ID列表
---@param files string[] 文件路径列表
---@param deleted_locations DeletedLocation[] 删除的位置信息
local function refresh_after_delete(ids, files, deleted_locations)
	-- 先触发事件，包含位置信息
	events.on_state_changed({
		source = "delete_by_id",
		changed_ids = ids, -- ✅ 修复：改为 changed_ids
		files = files,
		deleted_locations = deleted_locations,
	})

	-- 立即刷新每个文件
	for _, filepath in ipairs(files) do
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
		vim.notify("删除失败：ID格式无效", vim.log.levels.ERROR)
		return false, { id = id, error = "invalid_id" }
	end

	local result = {
		id = id,
		todo_line_deleted = false,
		code_line_deleted = false,
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

	-- ⭐ 在删除前记录位置信息（用于渲染清理）
	local deleted_locations = {}

	-- TODO文件
	if task.locations.todo and task.locations.todo.path then
		local bufnr = vim.fn.bufadd(task.locations.todo.path)
		vim.fn.bufload(bufnr)
		local line = validate_and_get_line(task, "todo", bufnr)
		if line then
			table.insert(files, task.locations.todo.path)
			lines_to_delete[task.locations.todo.path] = lines_to_delete[task.locations.todo.path] or {}
			table.insert(lines_to_delete[task.locations.todo.path], line)

			-- ⭐ 记录要删除的TODO位置
			table.insert(deleted_locations, {
				path = task.locations.todo.path,
				line = line,
				type = "todo",
				id = id,
			})
		end
	end

	-- 代码文件
	if task.locations.code and task.locations.code.path then
		local bufnr = vim.fn.bufadd(task.locations.code.path)
		vim.fn.bufload(bufnr)
		local line = validate_and_get_line(task, "code", bufnr)
		if line then
			table.insert(files, task.locations.code.path)
			lines_to_delete[task.locations.code.path] = lines_to_delete[task.locations.code.path] or {}
			table.insert(lines_to_delete[task.locations.code.path], line)

			-- ⭐ 记录要删除的CODE位置
			table.insert(deleted_locations, {
				path = task.locations.code.path,
				line = line,
				type = "code",
				id = id,
			})
		end
	end

	-- 2. 删除文件行
	for filepath, lines in pairs(lines_to_delete) do
		local deleted = delete_file_lines(filepath, lines, bufnr_cache)
		if #deleted > 0 then
			if task.locations.todo and filepath == task.locations.todo.path then
				result.todo_line_deleted = true
			end
			if task.locations.code and filepath == task.locations.code.path then
				result.code_line_deleted = true
			end
			table.insert(result.lines_deleted, {
				path = filepath,
				lines = deleted,
				type = (task.locations.todo and filepath == task.locations.todo.path) and "todo" or "code",
			})
		end
	end

	-- 3. 清理关系
	cleanup_relations(task)
	result.relations_cleaned = true

	-- 4. 删除归档快照
	local archive = require("todo2.store.link.archive")
	if archive.get_task_snapshot(id) then
		archive.delete_task_snapshot(id)
	end

	-- 5. 清理索引
	if task.locations.todo and task.locations.todo.path then
		pcall(index._internal.remove_todo_id, task.locations.todo.path, id)
	end
	if task.locations.code and task.locations.code.path then
		pcall(index._internal.remove_code_id, task.locations.code.path, id)
	end

	-- 6. 删除存储
	core.delete_task(id)
	result.store_deleted = true
	result.deleted_locations = deleted_locations

	-- 7. ⭐ 立即刷新渲染（传递删除的位置信息）
	if #files > 0 then
		refresh_after_delete({ id }, files, deleted_locations)
	end

	if result.todo_line_deleted or result.code_line_deleted then
		vim.notify(("✅ 已删除ID %s"):format(id:sub(1, 6)), vim.log.levels.INFO)
	end

	return true, result
end

---批量删除多个任务
---@param ids string[] 任务ID列表
---@return boolean success 是否至少有一个成功
---@return BatchDeleteResult result 批量删除结果
function M.delete_by_ids(ids)
	if not ids or #ids == 0 then
		return false, { error = "no_ids" }
	end

	local ok_cnt, fail_cnt = 0, 0
	local details = {}
	local all_files = {}
	local all_ids = {}
	local all_deleted_locations = {}

	for _, id in ipairs(ids) do
		local ok, res = M.delete_by_id(id)
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

	if #all_ids > 0 and #all_files > 0 then
		refresh_after_delete(all_ids, all_files, all_deleted_locations)
	end

	local level = (fail_cnt == 0) and vim.log.levels.INFO or vim.log.levels.WARN
	vim.notify(("删除完成：%d成功，%d失败"):format(ok_cnt, fail_cnt), level)

	return ok_cnt > 0, {
		total = #ids,
		succeeded = ok_cnt,
		failed = fail_cnt,
		details = details,
	}
end

---删除当前光标所在行的代码标记
---@return boolean success 是否成功
---@return DeleteResult? result 删除结果（可选）
function M.delete_current_code_mark()
	local a = line_analyzer.analyze_current_line()
	if not a.is_code_mark or not a.id then
		vim.notify("当前行不是代码标记", vim.log.levels.WARN)
		return false, nil
	end
	return M.delete_by_id(a.id)
end

---删除指定文件中的指定行（低级接口，谨慎使用）
---@param filepath string 文件路径
---@param lines number[] 行号列表
---@return number[] 实际删除的行号
function M.delete_raw_lines(filepath, lines)
	return delete_file_lines(filepath, lines, {})
end

return M

