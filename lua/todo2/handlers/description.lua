-- lua/todo2/handlers/description.lua
-- 编辑当前任务的正文（描述）：复用多行浮窗输入，写回 TODO 文件。
--
-- 正文在文件里是任务行下方的一串缩进续行，因此这里只做两件事：
--   * 读：description.block_at 拿到现有正文（光标在正文行上也支持）
--   * 写：整块替换（或首次插入），空文本则删除整块

local M = {}

local description = require("todo2.core.description")
local input = require("todo2.ui.input")
local format = require("todo2.utils.format")
local buffer = require("todo2.utils.buffer")
local file_utils = require("todo2.utils.file")
local config = require("todo2.config")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local core = require("todo2.store.task.core")
local cursor = require("todo2.task.cursor")

--- 缩进宽度（与 parser 保持一致）
---@return number
local function indent_width()
	return config.get("parser.indent_width") or 2
end

--- 找到光标所在（或上方最近的）任务行
---@param lines string[]
---@param lnum number
---@return number|nil
local function resolve_task_lnum(lines, lnum)
	if format.is_task_line(lines[lnum] or "") then
		return lnum
	end
	for i = lnum - 1, 1, -1 do
		if lines[i] and format.is_task_line(lines[i]) then
			return i
		end
	end
	return nil
end

--- 把正文写回缓冲区（整块替换 / 插入 / 删除）
---@param bufnr number
---@param task_lnum number
---@param text string
function M.write(bufnr, task_lnum, text)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local task_line = lines[task_lnum]
	if not task_line then
		return
	end

	local indent = string.rep(" ", description.base_indent(task_line, indent_width()))
	local old = description.block_at(lines, task_lnum)
	local new_lines = description.to_lines(text, indent)

	-- 有旧块：替换 [start_line, end_line]；没有：插到任务行之后
	local first = old and old.start_line or (task_lnum + 1)
	local last = old and old.end_line or task_lnum
	vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, new_lines)

	events.emit("description_edit", {
		file = buffer.get_path(bufnr),
		bufnr = bufnr,
	})
end

--- 编辑当前任务的正文。
--- 上下文自适应：
---   * TODO 文件 → 光标所在（或上方最近的）任务行 / 该行下方的正文块
---   * 代码文件 → 当前行关联的任务，按 id 跳回它的 TODO 行
---@return boolean
function M.edit()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")
	local path = buffer.get_path(bufnr)

	-- 代码文件：取当前行关联的任务，交给按 id 的路径
	if not file_utils.is_todo_file(path) then
		local id = cursor.get_id(bufnr, lnum)
		if not id then
			vim.notify("当前行没有关联的任务", vim.log.levels.WARN)
			return false
		end
		return M.edit_by_id(id)
	end

	-- TODO 文件
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local task_lnum = resolve_task_lnum(lines, lnum)
	if not task_lnum then
		vim.notify("当前行不是任务（也没有上方任务）", vim.log.levels.WARN)
		return false
	end

	local block = description.block_at(lines, task_lnum)

	input.prompt_multiline({
		title = "任务正文",
		default = block and block.text or "",
	}, function(text)
		if text == nil then
			return -- 取消
		end
		M.write(bufnr, task_lnum, text)
	end)

	return true
end

--- 按任务 id 编辑正文（供抽屉 / 代码侧调用，不要求当前 buffer 是 TODO 文件）。
--- 走 buffer 路线：文件未打开时先 bufadd + bufload，避免绕过 buffer 直接写盘。
---@param id string|nil
---@return boolean
function M.edit_by_id(id)
	if not id then
		return false
	end

	local task = core.get_task(id)
	local loc = task and task.locations and task.locations.todo
	if not loc or not loc.path or not loc.line then
		vim.notify("未找到任务或 TODO 位置", vim.log.levels.WARN)
		return false
	end

	local bufnr = vim.fn.bufnr(file_utils.normalize_path(loc.path))
	if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
		bufnr = vim.fn.bufadd(loc.path)
		vim.fn.bufload(bufnr)
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local lnum = loc.line
	if lnum < 1 or lnum > #lines then
		vim.notify("任务的 TODO 行号无效: " .. tostring(lnum), vim.log.levels.WARN)
		return false
	end

	local block = description.block_at(lines, lnum)

	input.prompt_multiline({
		title = "任务正文",
		default = block and block.text or "",
	}, function(text)
		if text == nil then
			return -- 取消
		end
		M.write(bufnr, lnum, text)
		autosave.request_save(bufnr)
	end)

	return true
end

return M
