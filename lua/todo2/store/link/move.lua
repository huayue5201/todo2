-- lua/todo2/store/link/move.lua
-- 代码块移动处理模块：处理代码重构时的任务重新定位
---@module "todo2.store.link.move"

local M = {}

local core = require("todo2.store.link.core")
local index = require("todo2.store.index")
local locator = require("todo2.store.locator")

---------------------------------------------------------------------
-- 私有工具函数
---------------------------------------------------------------------

---收集指定行范围内的所有任务ID
---@param path string 文件路径
---@param start_line number 起始行
---@param end_line number 结束行
---@return string[] 任务ID列表
local function collect_task_ids_in_range(path, start_line, end_line)
	local tasks = index.find_code_links_by_file(path)
	local ids = {}

	for _, task in ipairs(tasks) do
		local line = task.locations.code.line
		if line >= start_line and line <= end_line then
			table.insert(ids, task.id)
		end
	end

	return ids
end

---计算任务的新行号
---@param old_line number 原行号
---@param old_start number 原起始行
---@param new_start number 新起始行
---@return number 新行号
local function calculate_new_line(old_line, old_start, new_start)
	local offset = old_line - old_start
	return new_start + offset
end

---验证任务是否在目标位置（使用 buffer，而不是磁盘）
---@param id string 任务ID
---@param path string 文件路径
---@param line number 行号
---@return boolean
local function verify_task_location(id, path, line)
	-- 找到对应 buffer
	local bufnr = vim.fn.bufnr(path, false)
	if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)
	local content = lines[1]

	return content and content:match("ref:" .. id) ~= nil
end

---------------------------------------------------------------------
-- 公开API
---------------------------------------------------------------------

---重新定位单个移动后的任务
---@param id string 任务ID
---@param bufnr number|nil 缓冲区号（可选）
---@return boolean 是否重新定位成功
function M.relocate_moved_task(id, bufnr)
	local task = core.get_task(id)
	if not task or not task.locations.code then
		return false
	end

	local path = task.locations.code.path

	-- 使用 locator 重新定位
	local link_obj = {
		id = id,
		path = path,
		content = task.core.content,
		tag = task.core.tags and task.core.tags[1],
		context = task.locations.code.context,
	}

	local located = locator.locate_task_sync(link_obj)
	if located and located.line then
		task.locations.code.line = located.line
		task.verified = false
		task.timestamps.updated = os.time()
		core.save_task(id, task)
		return true
	end

	return false
end

---处理代码块移动（同一文件内）
---@param path string 文件路径
---@param old_start number 原起始行
---@param old_end number 原结束行
---@param new_start number 新起始行
---@return { moved: string[], failed: string[] } 移动结果
function M.handle_block_move_within_file(path, old_start, old_end, new_start)
	local result = { moved = {}, failed = {} }

	local ids = collect_task_ids_in_range(path, old_start, old_end)
	if #ids == 0 then
		return result
	end

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task and task.locations.code then
			local old_line = task.locations.code.line
			local new_line = calculate_new_line(old_line, old_start, new_start)

			task.locations.code.line = new_line
			task.verified = false
			task.timestamps.updated = os.time()
			core.save_task(id, task)

			table.insert(result.moved, id)
		else
			table.insert(result.failed, id)
		end
	end

	return result
end

---处理代码块跨文件移动
---@param old_path string 原文件路径
---@param new_path string 新文件路径
---@param old_start number 原起始行
---@param old_end number 原结束行
---@param new_start number 新起始行
---@return { moved: string[], failed: string[] } 移动结果
function M.handle_block_move_cross_file(old_path, new_path, old_start, old_end, new_start)
	local result = { moved = {}, failed = {} }

	local ids = collect_task_ids_in_range(old_path, old_start, old_end)
	if #ids == 0 then
		return result
	end

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task and task.locations.code then
			local old_line = task.locations.code.line
			local new_line = calculate_new_line(old_line, old_start, new_start)

			index._internal.remove_code_id(old_path, id)

			task.locations.code.path = new_path
			task.locations.code.line = new_line
			task.verified = false
			task.timestamps.updated = os.time()
			core.save_task(id, task)

			index._internal.add_code_id(new_path, id)

			table.insert(result.moved, id)
		else
			table.insert(result.failed, id)
		end
	end

	return result
end

---批量重新定位文件中的所有任务
---@param filepath string 文件路径
---@return { relocated: number, failed: string[] } 重新定位结果
function M.relocate_file_tasks(filepath)
	local tasks = index.find_code_links_by_file(filepath)
	local result = { relocated = 0, failed = {} }

	for _, task in ipairs(tasks) do
		local success = M.relocate_moved_task(task.id, nil)
		if success then
			result.relocated = result.relocated + 1
		else
			table.insert(result.failed, task.id)
		end
	end

	return result
end

---验证移动后的任务位置
---@param path string 文件路径
---@param ids string[] 任务ID列表
---@return { valid: string[], invalid: string[] } 验证结果
function M.verify_moved_tasks(path, ids)
	local result = { valid = {}, invalid = {} }

	for _, id in ipairs(ids) do
		local task = core.get_task(id)
		if task and task.locations.code then
			local line = task.locations.code.line
			if verify_task_location(id, path, line) then
				table.insert(result.valid, id)
			else
				table.insert(result.invalid, id)
			end
		else
			table.insert(result.invalid, id)
		end
	end

	return result
end

return M
