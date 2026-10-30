-- lua/todo2/handlers/due.lua
-- 到期日命令处理：
--   :TodoDue [date]  给光标处任务设置到期日（无参数则弹输入框）
--   :TodoDue none    清除到期日
--
-- date 支持：YYYY-MM-DD / YYYY/MM/DD / YYYYMMDD / today / tomorrow / +Nd / -Nd

local M = {}

local core = require("todo2.store.task.core")
local picker = require("todo2.task.picker")
local due_utils = require("todo2.utils.due")
local task_line = require("todo2.utils.task_line")

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

--- 行渲染刷新统一走 render.line_refresh（:TodoDue / :TodoTag 原本各有一份）
local line_refresh = require("todo2.render.line_refresh")
local refresh_task_line = line_refresh.task_line

--- 应用到期日：写 store → 重写文件行 → 刷新渲染。
---@param id string
---@param due string|nil
---@return boolean ok
---@return string|nil err
local function apply(id, due)
	if not core.get_task(id) then
		return false, "Task does not exist: " .. tostring(id)
	end

	if due ~= nil and not due_utils.is_date(due) then
		return false, "Invalid due date: " .. tostring(due)
	end

	if not core.set_due(id, due) then
		return false, "Failed to save due date"
	end

	local ok, err = task_line.rewrite(id)
	if not ok then
		return false, err
	end

	refresh_task_line(id)
	pcall(function()
		require("todo2.core.events").emit("todo_due", { changed_ids = { id } })
	end)
	return true
end

--- 解析命令行首参数：none/clear/- 清空；其余按日期归一化。
---@param value string
---@return string|nil due (nil 表示清空)
---@return boolean clear 是否显式清空
---@return string|nil err
local function parse_value(value)
	local v = vim.trim(value or ""):lower()
	if v == "" then
		return nil, false, "empty due"
	end
	if v == "none" or v == "clear" or v == "-" then
		return nil, true, nil
	end
	local date, err = due_utils.normalize(v)
	return date, false, err
end

---------------------------------------------------------------------
-- 命令入口
---------------------------------------------------------------------

--- 写入并提示；供命令行与抽屉共用。
---@param id string
---@param due string|nil
local function commit(id, due)
	local ok, err = apply(id, due)
	if not ok then
		vim.notify("[todo2] " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify(due and ("Due: " .. due) or "Due cleared", vim.log.levels.INFO)
end

--- 弹输入框设置到期日（默认当前值 / 今天；留空即清除），:TodoDue 与抽屉共用
---@param id string
---@param current string|nil
local function prompt_due(id, current)
	vim.ui.input({
		prompt = "Due date (YYYY-MM-DD / today / +7d, empty clears): ",
		default = current or due_utils.today(),
	}, function(input)
		if input == nil then
			return
		end
		local date, clear, err = parse_value(input)
		if err then
			vim.notify("[todo2] " .. err, vim.log.levels.WARN)
			return
		end
		commit(id, clear and nil or date)
	end)
end

--- :TodoDue 命令实现。
---@param args table vim command args（{ args = "..." }）
function M.due_cmd(args)
	local text = vim.trim((args and args.args) or "")
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	picker.pick({ bufnr = bufnr, lnum = lnum }, function(task)
		local id = task.id

		if text ~= "" then
			local date, clear, err = parse_value(text)
			if err then
				vim.notify("[todo2] " .. err, vim.log.levels.WARN)
				return
			end
			commit(id, clear and nil or date)
			return
		end

		prompt_due(id, task.core.due)
	end)
end

--- 按任务 id 直接写到期日（供日历等视图一键顺延，不弹输入框）。
---@param id string
---@param value string 日期表达式（YYYY-MM-DD / today / +7d …）
---@return boolean ok
function M.set_due_for_id(id, value)
	if not id or not core.get_task(id) then
		return false
	end
	local date, clear, err = parse_value(value)
	if err then
		vim.notify("[todo2] " .. err, vim.log.levels.WARN)
		return false
	end
	local ok = apply(id, clear and nil or date)
	if not ok then
		vim.notify("[todo2] failed to set due date", vim.log.levels.ERROR)
	end
	return ok
end

--- 按任务 id 打开到期日输入框（供抽屉等按 id 复用）。
---@param id string|nil
---@param value? string 命令行传入的日期（省略则弹输入框）
function M.due_for_id(id, value)
	if not id or not core.get_task(id) then
		return
	end
	local task = core.get_task(id)

	if value and vim.trim(value) ~= "" then
		local date, clear, err = parse_value(value)
		if err then
			vim.notify("[todo2] " .. err, vim.log.levels.WARN)
			return
		end
		commit(id, clear and nil or date)
		return
	end

	prompt_due(id, task.core.due)
end

return M
