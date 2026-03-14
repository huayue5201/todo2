-- lua/todo2/task/deleter.lua
-- 三位一体删除器：TODO行、CODE行、存储，全部清理

local M = {}

local id_utils = require("todo2.utils.id")
local line_analyzer = require("todo2.utils.line_analyzer")
local link = require("todo2.store.link")
local index = require("todo2.store.index")
local locator = require("todo2.store.locator")
local scheduler = require("todo2.render.scheduler")
local autosave = require("todo2.core.autosave")

---------------------------------------------------------------------
-- 工具：读取行内容
---------------------------------------------------------------------
local function read_line(filepath, lnum)
	local lines = scheduler.get_file_lines(filepath)
	return lines and lines[lnum] or nil
end

---------------------------------------------------------------------
-- 工具：验证行是否包含指定ID
---------------------------------------------------------------------
local function line_contains_id(filepath, lnum, id)
	local line = read_line(filepath, lnum)
	return line and id_utils.extract_id(line) == id
end

---------------------------------------------------------------------
-- 工具：获取正确的行号（locator兜底）
---------------------------------------------------------------------
local function resolve_line(link_obj)
	if not link_obj then
		return nil
	end

	-- ⭐ 即使行号无效，也尝试用locator查找
	local located = locator.locate_task_sync(link_obj)
	if located and located.line then
		return located.line
	end

	-- ⭐ 如果locator找不到，但存储中有行号，仍然尝试删除（可能文件已变）
	if link_obj.line then
		return link_obj.line
	end

	return nil
end

---------------------------------------------------------------------
-- 工具：删除文件中的行
---------------------------------------------------------------------
local function delete_file_lines(filepath, lines_to_delete)
	if not filepath or not lines_to_delete or #lines_to_delete == 0 then
		return 0
	end

	-- 加载缓冲区
	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	-- 从大到小排序，避免行号变化
	table.sort(lines_to_delete, function(a, b)
		return a > b
	end)

	-- 删除行
	for _, lnum in ipairs(lines_to_delete) do
		pcall(vim.api.nvim_buf_set_lines, bufnr, lnum - 1, lnum, false, {})
	end

	-- 请求保存
	autosave.request_save(bufnr)

	return #lines_to_delete
end

---------------------------------------------------------------------
-- ⭐ 核心：根据ID彻底删除（三位一体）- 修复版
---------------------------------------------------------------------
function M.delete_by_id(id)
	-- 参数验证
	if not id or not id_utils.is_valid(id) then
		vim.notify("删除失败：ID格式无效", vim.log.levels.ERROR)
		return false, { id = id, error = "invalid_id" }
	end

	local result = {
		id = id,
		todo_line_deleted = false,
		code_line_deleted = false,
		store_deleted = false,
		lines_deleted = {},
	}

	-- 1. 获取链接数据
	local todo_link = link.get_todo(id)
	local code_link = link.get_code(id)

	-- 如果都不存在，直接返回成功（幂等）
	if not todo_link and not code_link then
		return true, result
	end

	-- 2. 尝试删除TODO行（如果存在）
	if todo_link then
		local todo_line = resolve_line(todo_link)
		if todo_line then
			local deleted = delete_file_lines(todo_link.path, { todo_line })
			if deleted > 0 then
				result.todo_line_deleted = true
				table.insert(result.lines_deleted, {
					path = todo_link.path,
					line = todo_line,
					type = "todo",
				})
			end
		end
	end

	-- 3. 尝试删除CODE行（如果存在）
	if code_link then
		local code_line = resolve_line(code_link)
		if code_line then
			local deleted = delete_file_lines(code_link.path, { code_line })
			if deleted > 0 then
				result.code_line_deleted = true
				table.insert(result.lines_deleted, {
					path = code_link.path,
					line = code_line,
					type = "code",
				})
			end
		end
	end

	-- 4. ⭐ 删除存储数据（无论行是否存在）
	-- 先删快照
	local archive = require("todo2.store.link.archive")
	if archive.get_archive_snapshot(id) then
		archive.delete_archive_snapshot(id)
	end

	-- ⭐ 强制删除存储（即使link对象不存在也尝试）
	pcall(link.delete_todo, id) -- 用pcall确保不报错
	pcall(link.delete_code, id)

	-- 清理索引
	pcall(index.remove_from_all_indices, id)

	result.store_deleted = true

	-- 5. 触发事件（events.lua 会处理所有渲染刷新）
	local events = require("todo2.core.events")
	events.on_state_changed({
		source = "delete_by_id",
		ids = { id },
	})

	-- 显示结果
	if result.todo_line_deleted or result.code_line_deleted or result.store_deleted then
		vim.notify(string.format("✅ 已删除ID %s", id:sub(1, 6)), vim.log.levels.INFO)
	end

	return true, result
end

---------------------------------------------------------------------
-- ⭐ 批量删除（复用delete_by_id）
---------------------------------------------------------------------
function M.delete_by_ids(ids)
	if not ids or #ids == 0 then
		return false, { error = "no_ids" }
	end

	local results = {
		total = #ids,
		succeeded = 0,
		failed = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local ok, res = M.delete_by_id(id)
		if ok then
			results.succeeded = results.succeeded + 1
			table.insert(results.details, { id = id, success = true, result = res })
		else
			results.failed = results.failed + 1
			table.insert(results.details, { id = id, success = false, error = res.error })
		end
	end

	vim.notify(
		string.format("删除完成：%d成功，%d失败", results.succeeded, results.failed),
		results.failed == 0 and vim.log.levels.INFO or vim.log.levels.WARN
	)

	return results.succeeded > 0, results
end

---------------------------------------------------------------------
-- ⭐ 删除当前行的代码标记（handlers.lua调用）
---------------------------------------------------------------------
function M.delete_current_code_mark()
	local analysis = line_analyzer.analyze_current_line()

	if not analysis.is_code_mark or not analysis.id then
		vim.notify("当前行不是代码标记", vim.log.levels.WARN)
		return false
	end

	return M.delete_by_id(analysis.id)
end

---------------------------------------------------------------------
-- ⭐ 兼容handlers.lua的接口（内部调用新函数）
---------------------------------------------------------------------
function M.delete_code_link()
	return M.delete_current_code_mark()
end

function M.delete_todo_task_line(id)
	return M.delete_by_id(id)
end

function M.batch_delete_todo_links(ids)
	return M.delete_by_ids(ids)
end

return M
