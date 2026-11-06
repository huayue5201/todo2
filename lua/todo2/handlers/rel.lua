-- lua/todo2/handlers/rel.lua
-- 跨项目关系命令：
--   :TodoRel                       查看光标处任务的关系
--   :TodoRel +blocks:proj/id       追加关系（默认类型 relates；`+` 可省略）
--   :TodoRel -proj/id              删除指向该项目任务的关系（忽略类型）
--
-- 语法与校验都在 global/ref；这里只负责写入（store → 行 → 渲染），
-- 与 :TodoTag 走同一条写回链。

local M = {}

local core = require("todo2.store.task.core")
local picker = require("todo2.task.picker")
local guard = require("todo2.handlers.guard")
local task_line = require("todo2.utils.task_line")
local line_refresh = require("todo2.render.line_refresh")
local ref_utils = require("todo2.global.ref")
local project_utils = require("todo2.utils.project")

---项目名集合（校验与补全共用）
---@return table<string, boolean>
local function project_names()
	local names = {}
	for _, proj in ipairs(project_utils.list_projects()) do
		names[proj.name] = true
	end
	return names
end

---校验并规范化用户输入的引用。
---@param token string
---@param names table<string, boolean> 已存在的项目名
---@return string|nil rel, string|nil err
local function normalize_token(token, names)
	local parsed = ref_utils.parse(token)
	if not parsed then
		return nil, ("invalid reference: %s (expected [blocks:]project/id)"):format(token)
	end
	if not names[parsed.project] then
		return nil, ("unknown project: %s"):format(parsed.project)
	end
	return ref_utils.format(parsed.kind, parsed.project, parsed.id), nil
end

---@param tokens string[]|nil
---@return string[]|nil rels, string|nil err
local function normalize_tokens(tokens)
	local names = project_names()
	local out = {}
	for _, token in ipairs(tokens or {}) do
		local normalized, err = normalize_token(token, names)
		if not normalized then
			return nil, err
		end
		out[#out + 1] = normalized
	end
	return out
end

---把一组关系合并进现有列表。
---@param current string[]
---@param mode "add"|"remove"
---@param tokens string[]
---@return string[]
local function merge(current, mode, tokens)
	if mode == "add" then
		local list, seen = {}, {}
		for _, rel in ipairs(current) do
			seen[rel] = true
			list[#list + 1] = rel
		end
		for _, rel in ipairs(tokens) do
			if not seen[rel] then
				seen[rel] = true
				list[#list + 1] = rel
			end
		end
		return list
	end

	-- remove：按 qref 匹配，忽略类型，`-proj/id` 也能删掉 `blocks:proj/id`
	local drop = {}
	for _, rel in ipairs(tokens) do
		drop[rel:match("([^:]+)$")] = true
	end
	local kept = {}
	for _, rel in ipairs(current) do
		if not drop[rel:match("([^:]+)$")] then
			kept[#kept + 1] = rel
		end
	end
	return kept
end

---按 id 直接改关系（命令与测试共用，唯一写入口：store → 行 → 渲染）。
---@param id string
---@param mode "add"|"remove"
---@param rels string[]
---@return string[]|nil rels, string|nil err
function M.rels_for_id(id, mode, rels)
	local tokens, err = normalize_tokens(rels)
	if not tokens then
		return nil, err
	end

	local allowed, deny = guard.check(id, "change relations")
	if not allowed then
		return nil, deny
	end

	local task = core.get_task(id)
	if not task then
		return nil, "Task does not exist: " .. tostring(id)
	end

	-- 引用自己只会在全局视图里绕出一个没有意义的环
	local self_qref = ref_utils.qref(project_utils.current().name, id)
	for _, rel in ipairs(tokens) do
		if rel:match("([^:]+)$") == self_qref then
			return nil, "a task cannot relate to itself"
		end
	end

	if not core.set_rels(id, merge(ref_utils.normalize(task.core.rels), mode, tokens)) then
		return nil, "failed to update the task"
	end
	local written, write_err = task_line.rewrite(id)
	if not written then
		return nil, write_err
	end
	line_refresh.task_line(id)
	return core.get_task(id).core.rels
end

---@param fargs string[]
---@return "add"|"remove"
---@return string[] tokens
local function parse_args(fargs)
	local mode = fargs[1] and fargs[1]:sub(1, 1) == "-" and "remove" or "add"
	local tokens = {}
	for _, arg in ipairs(fargs) do
		local token = arg:gsub("^[+%-]", "")
		if token ~= "" then
			tokens[#tokens + 1] = token
		end
	end
	return mode, tokens
end

---------------------------------------------------------------------
-- 命令入口
---------------------------------------------------------------------

---打开关系选择器（抽屉 `L` 与 `:TodoRel` 无参数共用）
---@param id string
function M.pick_for_id(id)
	local task = id and core.get_task(id)
	if not task then
		vim.notify("[todo2] No task at cursor", vim.log.levels.WARN)
		return
	end
	require("todo2.ui.global").open_pick({
		id = task.id,
		content = task.core.content,
		rels = ref_utils.normalize(task.core.rels),
	})
end

--- :TodoRel —— 光标处任务的关系。
---@param cmd_args table
function M.rel_cmd(cmd_args)
	picker.pick({ none_msg = "[todo2] No task at cursor" }, function(task)
		local fargs = cmd_args.fargs or {}
		if #fargs == 0 then
			M.pick_for_id(task.id)
			return
		end

		local mode, raw = parse_args(fargs)
		local rels, err = M.rels_for_id(task.id, mode, raw)
		if not rels then
			vim.notify("[todo2] " .. err, vim.log.levels.ERROR)
			return
		end
		vim.notify("[todo2] Relations: " .. (#rels > 0 and table.concat(rels, "  ") or "(none)"))
	end)
end

---命令补全：只补到 `project/` 一层。
---@param arglead string
---@return string[]
function M.complete(arglead)
	local lead = (arglead or ""):gsub("^[+%-]", "")
	local items = {}
	if not lead:find("/", 1, true) then
		for name in pairs(project_names()) do
			local item = name .. "/"
			if item:sub(1, #lead) == lead then
				items[#items + 1] = item
			end
		end
	end
	table.sort(items)
	return items
end

return M
