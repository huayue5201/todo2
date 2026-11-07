-- lua/todo2/handlers/tags.lua
-- 标签命令处理：
--   :TodoTag 给光标处任务加 / 删 / 设置标签
--
-- 无参数时打开多选菜单：菜单是「草稿编辑器」，只有 Apply 才写回一次。

local M = {}

local core = require("todo2.store.task.core")
local picker = require("todo2.task.picker")
local guard = require("todo2.handlers.guard")
local commit = require("todo2.handlers.commit")
local format = require("todo2.utils.format")
local tags_utils = require("todo2.utils.tags")
local text = require("todo2.utils.text")

--- 菜单最小显示宽度（cells）：与 :TodoSet / 文件选择等菜单保持一致，避免弹窗随最长项抖动。
local MENU_WIDTH = 34

---------------------------------------------------------------------
-- 内部工具
---------------------------------------------------------------------

--- 应用标签改动：写 store → 重写文件行 → 刷新渲染。
--- 唯一写入口：命令、菜单、MCP 都走这里。
---@param id string
---@param mode "set"|"add"|"remove"
---@param tags string[]
---@return string[]|nil tags, string|nil err
local function apply(id, mode, tags)
	local allowed, deny = guard.check(id, "change tags")
	if not allowed then
		return nil, deny
	end

	tags = tags_utils.normalize(tags)
	if mode == "add" then
		core.add_tags(id, tags)
	elseif mode == "remove" then
		core.remove_tags(id, tags)
	else
		core.set_tags(id, tags)
	end

	local ok, err = commit.after_write(id, "todo_tags")
	if not ok then
		return nil, err
	end

	local task = core.get_task(id)
	return task and task.core.tags or {}
end

--- 把用户输入拆成合法 / 非法两组（空格分隔，`#` 可省）。
---@param input string
---@return string[] valid
---@return string[] invalid
local function parse_tokens(input)
	local valid, invalid = {}, {}
	for tok in input:gmatch("%S+") do
		local norm = tags_utils.normalize({ tok })
		if norm[1] then
			valid[#valid + 1] = norm[1]
		else
			invalid[#invalid + 1] = tok
		end
	end
	return valid, invalid
end

--- 非法 token 不静默丢弃，否则用户会以为按键没生效。
---@param invalid string[]
local function warn_invalid(invalid)
	if #invalid > 0 then
		vim.notify("[todo2] Ignored invalid tags: " .. table.concat(invalid, " "), vim.log.levels.WARN)
	end
end

---@param set table<string, boolean>
---@return string[]
local function sorted_keys(set)
	local out = vim.tbl_keys(set)
	table.sort(out)
	return out
end

--- 收集候选标签：任务当前标签 + 当前 TODO 文件里出现过的标签。
--- 只取文件级词表：标签是就近复用，全项目汇总会让菜单无限变长（筛选补全才用项目级）。
---@param id string
---@param current table<string, boolean>
---@return string[]
local function collect_candidates(id, current)
	local known = {}
	for tag in pairs(current) do
		known[tag] = true
	end

	local loc = core.get_todo_location(id)
	if loc and loc.path then
		local bufnr = vim.fn.bufnr(loc.path)
		local lines = (bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr))
				and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			or vim.fn.readfile(loc.path)
		for _, line in ipairs(lines) do
			if format.is_task_line(line) then
				for _, tag in ipairs(format.parse_task_line(line).tags or {}) do
					known[tag] = true
				end
			end
		end
	end

	return sorted_keys(known)
end

---------------------------------------------------------------------
-- 多选菜单
---------------------------------------------------------------------

--- 菜单会话：候选词表与原始值只算一次，切换/新增只改 pending。
---@class Todo2TagSession
---@field id string
---@field original table<string, boolean>
---@field names string[]
---@field pending table<string, boolean>

---@param set table<string, boolean>
---@return table<string, boolean>
local function copy_set(set)
	local out = {}
	for key in pairs(set) do
		out[key] = true
	end
	return out
end

---@param session Todo2TagSession
---@return boolean
local function is_dirty(session)
	return not vim.deep_equal(sorted_keys(session.pending), sorted_keys(session.original))
end

--- 菜单项 = 会话词表 ∪ 待选集合（新增的标签不在会话词表里）。
---@param session Todo2TagSession
---@return string[]
local function menu_names(session)
	local known = {}
	for _, tag in ipairs(session.names) do
		known[tag] = true
	end
	for tag in pairs(session.pending) do
		known[tag] = true
	end
	return sorted_keys(known)
end

---@param session Todo2TagSession
---@return string[] items
---@return table[] actions
local function build_items(session)
	local items, actions = {}, {}

	for _, tag in ipairs(menu_names(session)) do
		items[#items + 1] = (session.pending[tag] and "[x] #" or "[ ] #") .. tag
		actions[#actions + 1] = { kind = "toggle", tag = tag }
	end

	items[#items + 1] = "+ Add new tag…"
	actions[#actions + 1] = { kind = "add" }

	if next(session.pending) then
		items[#items + 1] = "✕ Clear selection"
		actions[#actions + 1] = { kind = "clear" }
	end

	local count = vim.tbl_count(session.pending)
	items[#items + 1] = string.format("✔ Apply (%d tags)%s", count, is_dirty(session) and " *" or "")
	actions[#actions + 1] = { kind = "commit" }

	return items, actions
end

local open_menu

--- 重开菜单：只替换 pending，不再重扫文件。
---@param session Todo2TagSession
---@param pending table<string, boolean>
local function reopen(session, pending)
	session.pending = pending
	open_menu(session)
end

---@param session Todo2TagSession
open_menu = function(session)
	local task = core.get_task(session.id)
	if not task then
		vim.notify("[todo2] Task does not exist: " .. tostring(session.id), vim.log.levels.ERROR)
		return
	end

	local items, actions = build_items(session)
	vim.ui.select(items, {
		prompt = "Tag multi-select (Enter to toggle, Esc to cancel):",
		kind = "todo2_tags",
		format_item = function(item)
			return text.pad_end(item, MENU_WIDTH)
		end,
	}, function(_, idx)
		local action = idx and actions[idx]
		if not action then
			return
		end

		-- vim.ui.select 没有原地刷新 API，切换类操作都重建一次菜单。
		if action.kind == "toggle" then
			local pending = copy_set(session.pending)
			pending[action.tag] = (pending[action.tag] ~= true) or nil
			reopen(session, pending)
			return
		end

		if action.kind == "add" then
			vim.ui.input({ prompt = "New tags (space-separated, # optional): " }, function(input)
				if input == nil then
					open_menu(session)
					return
				end
				local valid, invalid = parse_tokens(input)
				warn_invalid(invalid)
				local pending = copy_set(session.pending)
				for _, tag in ipairs(valid) do
					pending[tag] = true
				end
				reopen(session, pending)
			end)
			return
		end

		if action.kind == "clear" then
			reopen(session, {})
			return
		end

		-- commit：没有改动就只关菜单，不产生空写入。
		if not is_dirty(session) then
			return
		end
		local result, err = apply(session.id, "set", vim.tbl_keys(session.pending))
		if err then
			vim.notify("[todo2] " .. err, vim.log.levels.ERROR)
			return
		end
		local label = #result > 0 and table.concat(result, " ") or "(none)"
		vim.notify("[todo2] Tags: " .. label, vim.log.levels.INFO)
	end)
end

---@param id string
---@return Todo2TagSession
local function new_session(id)
	local current = {}
	for _, tag in ipairs(tags_utils.normalize(core.get_task(id).core.tags)) do
		current[tag] = true
	end
	return {
		id = id,
		original = copy_set(current),
		pending = copy_set(current),
		names = collect_candidates(id, current),
	}
end

---------------------------------------------------------------------
-- 命令入口
---------------------------------------------------------------------

---@param id string
---@param fargs string[]
local function run_tag(id, fargs)
	-- UI 入口先检查一次（存在性 + 可写性）：否则用户选完菜单才在写回时被拒。
	-- apply 是唯一写入口，MCP 等非 UI 调用方由它自己再校验。
	local allowed, deny = guard.check(id, "change tags")
	if not allowed then
		vim.notify("[todo2] " .. deny, vim.log.levels.WARN)
		return
	end

	if #fargs == 0 then
		open_menu(new_session(id))
		return
	end

	-- 参数模式：首参以 + 开头 → 追加；以 - 开头 → 删除；否则整体设置。
	-- 前缀必须统一，混用会变成静默错误（`+a -b` 不等于「加 a 删 b」）。
	local prefix = fargs[1]:sub(1, 1)
	local mode = "set"
	if prefix == "+" then
		mode = "add"
	elseif prefix == "-" then
		mode = "remove"
	else
		prefix = ""
	end

	local tokens = {}
	for _, arg in ipairs(fargs) do
		local lead = arg:sub(1, 1)
		if lead == "+" or lead == "-" then
			if lead ~= prefix then
				vim.notify("[todo2] Do not mix +tag and -tag in one command", vim.log.levels.ERROR)
				return
			end
			arg = arg:sub(2)
		end
		if arg ~= "" then
			tokens[#tokens + 1] = arg
		end
	end
	if #tokens == 0 then
		vim.notify("[todo2] No tags given", vim.log.levels.WARN)
		return
	end

	local valid, invalid = parse_tokens(table.concat(tokens, " "))
	warn_invalid(invalid)
	if #valid == 0 then
		return
	end

	local result, err = apply(id, mode, valid)
	if err then
		vim.notify("[todo2] " .. err, vim.log.levels.ERROR)
		return
	end
	local label = #result > 0 and table.concat(result, " ") or "(none)"
	vim.notify("[todo2] Tags: " .. label, vim.log.levels.INFO)
end

--- :TodoTag —— 给光标处任务加 / 删 / 设置标签。
---@param cmd_args table
function M.tag_cmd(cmd_args)
	picker.pick({ none_msg = "[todo2] No task at cursor" }, function(task)
		run_tag(task.id, cmd_args.fargs or {})
	end)
end

--- 给指定任务打开标签选择菜单（供抽屉、属性面板等按 id 复用）。
---@param id string|nil
function M.tag_for_id(id)
	if id then
		run_tag(id, {})
	end
end

--- 按 id 直接改标签，不弹输入（供 MCP / 外部动作复用；与 :TodoTag 同一条写回链）。
---@param id string
---@param mode "set"|"add"|"remove"
---@param tags string[]
---@return string[]|nil tags, string|nil err
function M.tags_for_id(id, mode, tags)
	return apply(id, mode, tags)
end

return M
