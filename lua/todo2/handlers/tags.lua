-- lua/todo2/handlers/tags.lua
-- 标签命令处理：
--   :TodoTag    给光标处任务加 / 删 / 设置标签
--   :TodoFilter 按标签筛选当前 TODO 文件视图（无参数 / ! 清除）

local M = {}

local core = require("todo2.store.task.core")
local cursor = require("todo2.task.cursor")
local tags_utils = require("todo2.utils.tags")
local task_line = require("todo2.utils.task_line")
local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")
local format = require("todo2.utils.format")

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

--- 刷新某任务在 TODO 文件中的行渲染（标签高亮 + conceal），并重绘筛选。
---@param id string
local function refresh_task_line(id)
	local loc = core.get_todo_location(id)
	if not loc or not loc.path then
		return
	end
	local bufnr = vim.fn.bufnr(loc.path)
	if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local ok, line = pcall(function()
		return vim.api.nvim_buf_get_lines(bufnr, loc.line - 1, loc.line, false)[1]
	end)
	if not ok or not line then
		return
	end
	pcall(function()
		require("todo2.render.todo_render").render_task_by_line(bufnr, loc.line, line)
		require("todo2.render.conceal").apply_line_conceal(bufnr, loc.line)
		require("todo2.render.filter").refresh(bufnr)
	end)
end

--- 应用标签改动：写 store → 重写文件行 → 刷新渲染。
---@param id string
---@param mode "set"|"add"|"remove"
---@param tags string[]
---@return string[]|nil tags, string|nil err
local function apply(id, mode, tags)
	if not core.get_task(id) then
		return nil, "任务不存在: " .. tostring(id)
	end

	tags = tags_utils.normalize(tags)
	if mode == "add" then
		core.add_tags(id, tags)
	elseif mode == "remove" then
		core.remove_tags(id, tags)
	else
		core.set_tags(id, tags)
	end

	local ok, err = task_line.rewrite(id)
	if not ok then
		return nil, err
	end

	refresh_task_line(id)
	pcall(function()
		require("todo2.core.events").emit("todo_tags", { changed_ids = { id } })
	end)

	local task = core.get_task(id)
	return task and task.core.tags or {}
end

--- 收集某个 TODO 文件中出现过的所有标签。
---@param path string
---@return table<string, boolean>
local function collect_file_tags(path)
	local found = {}
	local lines
	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		lines = vim.fn.readfile(path)
	end
	for _, line in ipairs(lines) do
		if format.is_task_line(line) then
			local parsed = format.parse_task_line(line)
			for _, t in ipairs(parsed.tags or {}) do
				found[t] = true
			end
		end
	end
	return found
end

--- `:TodoTag` 无参数时的交互菜单：多选标签，点「应用」才写回（Esc 放弃）。
---@param id string
---@param pending? table<string, boolean> 已选标签集合；省略则从 store 当前标签初始化
local function open_select_menu(id, pending)
	local task = core.get_task(id)
	if not task then
		vim.notify("[todo2] 任务不存在: " .. tostring(id), vim.log.levels.ERROR)
		return
	end
	local original = tags_utils.normalize(task.core.tags)

	-- 首次进入：pending = 当前标签
	if not pending then
		pending = {}
		for _, t in ipairs(original) do
			pending[t] = true
		end
	end

	-- 候选标签 = 当前标签 + pending + 当前 TODO 文件里出现过的
	local known = {}
	for _, t in ipairs(original) do
		known[t] = true
	end
	for t in pairs(pending) do
		known[t] = true
	end
	local loc = core.get_todo_location(id)
	if loc and loc.path then
		for t in pairs(collect_file_tags(loc.path)) do
			known[t] = true
		end
	end

	local names = {}
	for t in pairs(known) do
		names[#names + 1] = t
	end
	table.sort(names)

	local pending_list = {}
	for t in pairs(pending) do
		pending_list[#pending_list + 1] = t
	end
	table.sort(pending_list)
	local dirty = not vim.deep_equal(pending_list, original)

	local items, actions = {}, {}
	for _, t in ipairs(names) do
		local on = pending[t] == true
		items[#items + 1] = (on and "[x] #" or "[ ] #") .. t
		actions[#actions + 1] = { kind = "toggle", tag = t }
	end
	items[#items + 1] = "＋ 添加新标签…"
	actions[#actions + 1] = { kind = "add" }
	if #pending_list > 0 then
		items[#items + 1] = "✕ 清空选择"
		actions[#actions + 1] = { kind = "clear" }
	end
	items[#items + 1] = string.format("✔ 应用（%d 个标签）%s", #pending_list, dirty and " *" or "")
	actions[#actions + 1] = { kind = "commit" }
	if dirty then
		items[#items + 1] = "↩ 放弃修改"
		actions[#actions + 1] = { kind = "reset" }
	end

	vim.ui.select(items, { prompt = "标签多选（回车切换；选「应用」保存，Esc 取消）:", kind = "todo2_tags" }, function(_, idx)
		if not idx then
			return
		end
		local action = actions[idx]
		if not action then
			return
		end

		if action.kind == "toggle" then
			pending[action.tag] = (pending[action.tag] ~= true) or nil
			open_select_menu(id, pending)
			return
		end

		if action.kind == "add" then
			vim.ui.input({ prompt = "新增标签（空格分隔，# 可省略）: " }, function(input)
				if input == nil then
					open_select_menu(id, pending)
					return
				end
				for tok in input:gmatch("%S+") do
					local norm = tags_utils.normalize({ tok })
					if norm[1] then
						pending[norm[1]] = true
					end
				end
				open_select_menu(id, pending)
			end)
			return
		end

		if action.kind == "clear" then
			open_select_menu(id, {})
			return
		end

		if action.kind == "reset" then
			open_select_menu(id, nil)
			return
		end

		-- commit：一次性把 pending 写回 store
		local list = {}
		for t in pairs(pending) do
			list[#list + 1] = t
		end
		local result, err = apply(id, "set", list)
		if err then
			vim.notify("[todo2] " .. err, vim.log.levels.ERROR)
		else
			local label = #result > 0 and table.concat(result, " ") or "(无)"
			vim.notify("[todo2] 标签: " .. label, vim.log.levels.INFO)
		end
	end)
end

--- 处理 `:TodoTag` 的参数并执行。
---@param id string
---@param fargs string[]
local function run_tag(id, fargs)
	local task = core.get_task(id)
	if not task then
		vim.notify("[todo2] 任务不存在: " .. tostring(id), vim.log.levels.ERROR)
		return
	end

	-- 无参数：打开多选菜单（回车切换，选「应用」保存）
	if #fargs == 0 then
		open_select_menu(id)
		return
	end

	-- 参数模式：首参数以 + 开头 → 追加；以 - 开头 → 删除；否则整体设置
	local mode = "set"
	local first = fargs[1]
	if first:sub(1, 1) == "+" then
		mode = "add"
	elseif first:sub(1, 1) == "-" then
		mode = "remove"
	end

	local tags = {}
	for _, a in ipairs(fargs) do
		a = a:gsub("^[+%-]", "")
		if a ~= "" then
			tags[#tags + 1] = a
		end
	end

	local result, err = apply(id, mode, tags)
	if err then
		vim.notify("[todo2] " .. err, vim.log.levels.ERROR)
		return
	end
	local label = #result > 0 and table.concat(result, " ") or "(无)"
	vim.notify("[todo2] 标签: " .. label, vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 命令入口
---------------------------------------------------------------------

--- :TodoTag —— 给光标处任务加 / 删 / 设置标签。
---@param cmd_args table
function M.tag_cmd(cmd_args)
	local id = cursor.get_id()
	if not id then
		vim.notify("[todo2] 光标处没有任务", vim.log.levels.WARN)
		return
	end
	run_tag(id, cmd_args.fargs or {})
end

--- 给指定任务打开标签选择菜单（供抽屉、代码端等按 id 复用）。
---@param id string|nil
function M.tag_for_id(id)
	if not id then
		return
	end
	run_tag(id, {})
end

--- :TodoFilter —— 按标签筛选当前 TODO 文件视图。
---@param cmd_args table
function M.filter_cmd(cmd_args)
	local bufnr = vim.api.nvim_get_current_buf()
	local path = buffer.get_path(bufnr)
	if not file.is_todo_file(path) then
		vim.notify("[todo2] 只能在 TODO 文件中使用标签筛选", vim.log.levels.WARN)
		return
	end

	local filter = require("todo2.render.filter")
	local fargs = cmd_args.fargs or {}

	local clear = cmd_args.bang or #fargs == 0
	if not clear and #fargs == 1 and (fargs[1] == "*" or fargs[1] == "clear") then
		clear = true
	end

	if clear then
		filter.clear(bufnr)
		vim.notify("[todo2] 已清除标签筛选", vim.log.levels.INFO)
		return
	end

	filter.set(bufnr, fargs)
	vim.notify("[todo2] 只显示标签: " .. table.concat(tags_utils.normalize(fargs), " "), vim.log.levels.INFO)
end

return M
