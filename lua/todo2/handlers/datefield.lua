-- lua/todo2/handlers/datefield.lua
-- 时间维度字段（`~start` 开始日 / `@due` 到期日）的唯一写回实现。
--
-- 两层语义：
--   * 两个字段都为空 = 这只是代码地图里的一个标记（marker）
--   * 只要有一个 = 承诺（commitment）的一种形态
--       - 只有 due      期限 deadline
--       - start + due   排期 interval
--       - 只有 start    计划 planned
--
-- 语义约束：`start <= due`。写 due 时若会让区间倒置，把 start 一起夹到 due；
-- 写 start 时若晚于 due，直接拒绝并提示。

local M = {}

local core = require("todo2.store.task.core")
local picker = require("todo2.task.picker")
local due_utils = require("todo2.utils.due")
local config = require("todo2.config")
local task_line = require("todo2.utils.task_line")
local line_refresh = require("todo2.render.line_refresh")

---@class Todo2DateFieldSpec
---@field key string 存储字段名（core.<key>）
---@field label string 展示名
---@field prompt string 表达式输入框的提示语
---@field event string 写回后 emit 的事件名
---@field setter string core 模块里的写入函数名

---@type table<string, Todo2DateFieldSpec>
local SPEC = {
	due = {
		key = "due",
		label = "Due",
		prompt = "Due date (YYYY-MM-DD / today / +7d, empty clears): ",
		event = "todo_due",
		setter = "set_due",
	},
	start = {
		key = "start",
		label = "Start",
		prompt = "Start date (YYYY-MM-DD / today / +7d, empty clears): ",
		event = "todo_start",
		setter = "set_start",
	},
}

---@param field string
---@return Todo2DateFieldSpec
function M.spec(field)
	return SPEC[field] or SPEC.due
end

--- 解析日期表达式：空 / none / clear / - 一律清空；其余按日期归一化。
---@param value string
---@return string|nil date (nil 表示清空)
---@return boolean clear 是否显式清空
---@return string|nil err
function M.parse_value(value)
	local v = vim.trim(value or ""):lower()
	if v == "" or v == "none" or v == "clear" or v == "-" then
		return nil, true, nil
	end
	local date, err = due_utils.normalize(v)
	if not date then
		return nil, false, err or "invalid date"
	end
	return date, false, nil
end

--- 应用字段值：校验 → 写 store → 重写文件行 → 刷新渲染。
---@param field string
---@param id string
---@param date string|nil
---@return boolean ok
---@return string|nil err
local function apply(field, id, date)
	local spec = M.spec(field)
	local task = core.get_task(id)
	if not task then
		return false, "Task does not exist: " .. tostring(id)
	end
	if date ~= nil and not due_utils.is_date(date) then
		return false, "Invalid date: " .. tostring(date)
	end

	-- 维持 start <= due
	if field == "due" and date ~= nil then
		local start = task.core.start
		if start ~= nil and start > date then
			core.set_start(id, date)
			task.core.start = date
		end
	elseif field == "start" and date ~= nil then
		local due = task.core.due
		if due ~= nil and date > due then
			return false, "Start date is after the due date (" .. due .. ")"
		end
	end

	if not core[spec.setter](id, date) then
		return false, "Failed to save " .. spec.key .. " date"
	end

	local ok, err = task_line.rewrite(id)
	if not ok then
		return false, err
	end

	line_refresh.task_line(id)
	pcall(function()
		require("todo2.core.events").emit(spec.event, { changed_ids = { id } })
	end)
	return true
end

--- 写入并提示。属性面板/抽屉/命令共用这一条路径。
---@param field string
---@param id string
---@param date string|nil
---@param on_done? fun()
local function commit(field, id, date, on_done)
	local spec = M.spec(field)
	local ok, err = apply(field, id, date)
	if not ok then
		vim.notify("[todo2] " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify(date and (spec.label .. ": " .. date) or (spec.label .. " cleared"), vim.log.levels.INFO)
	if on_done then
		on_done()
	end
end

--- 表达式输入（一行输入框）：today / +7d / 2026-11-02，留空即清除。
---@param field string
---@param id string
---@param current string|nil
---@param on_done? fun()
function M.prompt_expression(field, id, current, on_done)
	if not id then
		return
	end
	vim.ui.input({ prompt = M.spec(field).prompt, default = current or due_utils.today() }, function(input)
		if input == nil then
			return
		end
		local date, clear, err = M.parse_value(input)
		if err then
			vim.notify("[todo2] " .. err, vim.log.levels.WARN)
			return
		end
		commit(field, id, clear and nil or date, on_done)
	end)
end

--- 交互式设置：默认打开三格日期面板（config.due.panel = false 时退回表达式输入）。
---@param field string
---@param id string
---@param current string|nil
---@param on_done? fun()
function M.prompt(field, id, current, on_done)
	if config.get("due.panel") ~= false then
		require("todo2.ui.date_panel").open({ id = id, field = field, date = current, on_done = on_done })
		return
	end
	M.prompt_expression(field, id, current, on_done)
end

--- Ex 命令实现（`:TodoDue` / `:TodoStart`）。
---@param field string
---@param args? table
function M.cmd(field, args)
	local text = vim.trim((args and args.args) or "")
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	picker.pick({ bufnr = bufnr, lnum = lnum }, function(task)
		local id = task.id
		if text ~= "" then
			local date, clear, err = M.parse_value(text)
			if err then
				vim.notify("[todo2] " .. err, vim.log.levels.WARN)
				return
			end
			commit(field, id, clear and nil or date)
			return
		end
		M.prompt(field, id, task.core[M.spec(field).key])
	end)
end

--- 按任务 id 直接写（供日历顺延、AI/MCP 调用，不弹输入框）。
---@param field string
---@param id string
---@param value string
---@return boolean ok
function M.set_by_id(field, id, value)
	if not id or not core.get_task(id) then
		return false
	end
	local date, clear, err = M.parse_value(value)
	if err then
		vim.notify("[todo2] " .. err, vim.log.levels.WARN)
		return false
	end
	local ok = apply(field, id, clear and nil or date)
	if not ok then
		vim.notify("[todo2] failed to set " .. M.spec(field).key .. " date", vim.log.levels.ERROR)
	end
	return ok
end

--- 按任务 id 打开输入入口（供抽屉/属性面板复用）。
---@param field string
---@param id string|nil
---@param value? string 命令行传入的日期（省略则弹面板）
---@param on_done? fun()
function M.for_id(field, id, value, on_done)
	if not id or not core.get_task(id) then
		return
	end
	local task = core.get_task(id)

	if value and vim.trim(value) ~= "" then
		local date, clear, err = M.parse_value(value)
		if err then
			vim.notify("[todo2] " .. err, vim.log.levels.WARN)
			return
		end
		commit(field, id, clear and nil or date, on_done)
		return
	end

	M.prompt(field, id, task.core[M.spec(field).key], on_done)
end

return M
