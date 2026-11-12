-- lua/todo2/integrations/ask_agent.lua
-- 可选桥接：把任务（含 AI 上下文层整理的树 + 代码）派给 ask-agent.nvim，
-- 并在 agent 完成 / 卡住时回写任务状态。
--
-- ask-agent 只是「消费者」：这里只调它的公开 API（send / on），
-- ask-agent 不在时装作没有这个集成，所有入口返回 nil/false，不报错。

local M = {}

-- 自动化行为（可在 require 之后、事件发生之前改）：
--   auto_complete：agent 完成后把任务置 completed（默认开）
--   complete_heuristic：ask-agent 只是"推断"完成（source == "heuristic"）时也回写；
--     默认关，避免一个空闲探测把任务误标完成
M.auto_complete = true
M.complete_heuristic = false

local file = require("todo2.utils.file")
local format = require("todo2.utils.format")
local index = require("todo2.store.index")
local query = require("todo2.store.task.query")

---@return table|nil ask-agent 模块（未安装时 nil）
local function ask()
	local ok, mod = pcall(require, "ask_agent")
	return ok and mod or nil
end

---@return boolean
function M.available()
	return ask() ~= nil
end

---当前指针下的任务：TODO 文件看行内 `@id`，代码文件看该行绑定的锚点。
---@return string|nil id
function M.task_at_cursor()
	local path = vim.api.nvim_buf_get_name(0)
	if path == "" then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	if file.is_todo_file(path) then
		local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
		local parsed = format.parse_task_line(line)
		return parsed and parsed.id or nil
	end
	local task = index.find_code_task_at_line(path, lnum)
	return task and task.id or nil
end

---任务在 ask-agent 里的跳转锚点（无锚点的纯清单任务返回 nil）。
---@param id string
---@return table|nil
local function anchor_for(id)
	local loc = query.resolve_code_location(id)
	if not loc or not loc.path or not loc.line then
		return nil
	end
	local buf = vim.fn.bufadd(loc.path)
	return {
		buf = buf,
		bufname = vim.api.nvim_buf_get_name(buf),
		path = loc.path,
		line = loc.line,
		col = (loc.col or 0) + 1,
	}
end

---把任务派给一个 agent（目标由 ask-agent 的 pinned / picker 决定，`opts.target`
---或 `opts.backend` 可显式指定）。
---@param id string|nil 省略 = 光标下的任务
---@param opts? { include_code?: boolean, include_children?: boolean|integer, backend?: string, target?: string }
---@return boolean ok, string|nil err
function M.ask(id, opts)
	opts = opts or {}
	local ask_mod = ask()
	if not ask_mod then
		vim.notify("todo2: ask-agent.nvim is not installed", vim.log.levels.WARN)
		return false, "ask-agent.nvim is not installed"
	end
	id = id or M.task_at_cursor()
	if not id then
		vim.notify("todo2: no task under the cursor", vim.log.levels.WARN)
		return false, "No task under the cursor"
	end

	local context = require("todo2.ai")
	local bundle = context.build(id, {
		include_code = opts.include_code,
		include_children = opts.include_children,
	})
	if not bundle then
		return false, "Cannot build the context of " .. tostring(id)
	end

	local ok, err = ask_mod.send(context.to_markdown(bundle), {
		-- key is what ask-agent shows next to the turn ([t42] in the dashboard,
		-- "todo2 t42" in :AskAgentHistory); title is there for tools that want more
		correlation = { plugin = "todo2", key = id, label = id, title = bundle.content },
		anchor = anchor_for(id),
		backend = opts.backend,
		target = opts.target,
	})
	if not ok then
		vim.notify("todo2: " .. tostring(err), vim.log.levels.WARN)
		return false, err
	end
	vim.notify(("Sent %s to an agent"):format(id), vim.log.levels.INFO)
	return true
end

---Title of a task, for notifications ("t42 wire the bridge").
---@param key string
---@return string
local function label(key)
	local t = require("todo2.store.task.core").get_task(key)
	local title = t and t.core and t.core.content
	return title and (key .. " " .. title) or key
end

---订阅 agent 的结果：完成 → 任务置 completed；卡住 → 提醒是哪个任务。
function M.setup()
	local ask_mod = ask()
	if not ask_mod or M._off then
		return
	end

	local actions = require("todo2.ai.actions")
	local function ours(task)
		local c = task.correlation
		return c and c.plugin == "todo2" and c.key
	end

	-- one notification per (task, turn): a done → working → done cycle must not
	-- report the same completed task twice
	local announced = {}
	M._off = ask_mod.on("done", function(rec)
		if not M.auto_complete then
			return
		end
		if rec.source == "heuristic" and not M.complete_heuristic then
			return
		end
		for _, task in ipairs(rec.tasks or {}) do
			local c = task.correlation
			local turn = tostring(task.ts or "")
			if task.status == "done" and ours(task) and not announced[c.key .. "@" .. turn] then
				announced[c.key .. "@" .. turn] = true
				local _, err = actions.set_status(c.key, "completed")
				if err then
					vim.notify("todo2: " .. err, vim.log.levels.WARN)
				else
					vim.notify(("Agent finished %s — marked completed"):format(label(c.key)), vim.log.levels.INFO)
				end
			end
		end
	end)

	local waiting = {}
	ask_mod.on("blocked", function(rec)
		for _, task in ipairs(rec.tasks or {}) do
			local c = task.correlation
			if ours(task) and task.status == "running" and not waiting[c.key] then
				waiting[c.key] = true
				vim.notify(
					("Agent is waiting on you for %s (%s)"):format(label(c.key), rec.msg or ""),
					vim.log.levels.WARN
				)
			end
		end
	end)
	-- a blocked turn that starts moving again can block again later
	ask_mod.on("state", function(rec)
		if rec.state == "blocked" then
			return
		end
		for _, task in ipairs(rec.tasks or {}) do
			if ours(task) then
				waiting[task.correlation.key] = nil
			end
		end
	end)
end

return M
