-- lua/todo2/render/filter.lua
-- 任务筛选：标签（AND，含 git 派生伪标签）+ 状态（OR）+ 路径（子串 / glob）+ 到期日。
--
-- TODO 文件里隐藏非命中行（保留祖先/后代作上下文）；抽屉复用同一套匹配语义剪枝。
--
-- 筛选规格（spec）：
--   { tags = string[], status = string[], path = string|nil, due = <due spec> }
-- 命令词法：`#tag` / `tag`、`status:<label|active>`（可重复，OR）、`path:<substr|glob>`、
--   `due:today|tomorrow|week|month|overdue|none|YYYY-MM[-DD]|<DATE|<=DATE|>DATE|>=DATE`。

local M = {}

local constants = require("todo2.constants")
local format = require("todo2.utils.format")
local tags_utils = require("todo2.utils.tags")
local due_utils = require("todo2.utils.due")
local core = require("todo2.store.task.core")
local git = require("todo2.integrations.git")
local types = require("todo2.store.types")
local config = require("todo2.config")

local NS = constants.ns("filter")

--- 每个缓冲区当前激活的筛选规格（nil 表示未筛选）。
---@type table<number, Todo2FilterSpec>
local state = {}

---@class Todo2FilterSpec
---@field tags string[]
---@field status string[]
---@field path string|nil
---@field due table|nil due_utils.parse_spec 结果

---------------------------------------------------------------------
-- 规格
---------------------------------------------------------------------

--- 规范化标签：普通标签小写去重排序，git 伪标签保留原样（保分支名大小写）。
---@param tags string[]
---@return string[]
local function normalize_tags(tags)
	local plain, pseudo = {}, {}
	for _, tag in ipairs(tags or {}) do
		local s = tostring(tag):gsub("^#", "")
		if s ~= "" then
			if s:sub(1, 4) == "git:" then
				pseudo[#pseudo + 1] = s
			else
				plain[#plain + 1] = s
			end
		end
	end
	local out = tags_utils.normalize(plain)
	vim.list_extend(out, pseudo)
	return out
end

--- 把 status 词解析成合法状态标签（大小写不敏感）；未知返回 nil。
---@param value string
---@return string|nil
local function resolve_status(value)
	value = value:lower()
	if value == "active" or value == types.STATUS.COMPLETED or value == types.STATUS.ARCHIVED then
		return value
	end
	for _, def in ipairs(config.get("status.cycle") or {}) do
		if def.label:lower() == value then
			return def.label
		end
	end
	return nil
end

--- 解析命令词为规格。返回 nil, err 表示词法/状态非法。
---@param tokens string[]
---@return Todo2FilterSpec|nil, string|nil
function M.parse(tokens)
	local spec = { tags = {}, status = {} }
	local seen = {}
	for _, raw in ipairs(tokens or {}) do
		local key, value = tostring(raw):match("^(%a+):(.+)$")
		if key == "status" then
			local resolved = resolve_status(value)
			if not resolved then
				return nil, "unknown status: " .. value
			end
			if not seen[resolved] then
				seen[resolved] = true
				spec.status[#spec.status + 1] = resolved
			end
		elseif key == "path" then
			spec.path = value:gsub("\\", "/")
		elseif key == "due" then
			local due_spec, err = due_utils.parse_spec(value)
			if not due_spec then
				return nil, err
			end
			spec.due = due_spec
		else
			spec.tags[#spec.tags + 1] = raw
		end
	end
	spec.tags = normalize_tags(spec.tags)
	return spec
end

--- 从配置里的表形式构造规格（供命名筛选使用）。
---@param tbl table|nil
---@return Todo2FilterSpec|nil, string|nil
function M.from_table(tbl)
	if type(tbl) ~= "table" then
		return nil, "invalid filter"
	end
	local tokens = {}
	for _, t in ipairs(tbl.tags or {}) do
		tokens[#tokens + 1] = "#" .. t
	end
	local statuses = type(tbl.status) == "string" and { tbl.status } or (tbl.status or {})
	for _, s in ipairs(statuses) do
		tokens[#tokens + 1] = "status:" .. s
	end
	if tbl.path then
		tokens[#tokens + 1] = "path:" .. tbl.path
	end
	if type(tbl.due) == "string" then
		tokens[#tokens + 1] = "due:" .. tbl.due
	end
	return M.parse(tokens)
end

--- 规格 → 可写入配置的表形式。
---@param spec Todo2FilterSpec
---@return table
function M.to_table(spec)
	local tbl = {}
	if #spec.tags > 0 then
		tbl.tags = vim.deepcopy(spec.tags)
	end
	if #spec.status > 0 then
		tbl.status = vim.deepcopy(spec.status)
	end
	if spec.path then
		tbl.path = spec.path
	end
	if spec.due then
		tbl.due = spec.due.raw
	end
	return tbl
end

--- 空规格（无条件）判定。
---@param spec Todo2FilterSpec|nil
---@return boolean
function M.is_empty(spec)
	return spec == nil or (#spec.tags == 0 and #spec.status == 0 and spec.path == nil and spec.due == nil)
end

--- 规格的可读描述，用于通知 / 空视图提示。
---@param spec Todo2FilterSpec|nil
---@return string
function M.describe(spec)
	local parts = {}
	for _, t in ipairs(spec and spec.tags or {}) do
		parts[#parts + 1] = "#" .. t
	end
	for _, s in ipairs(spec and spec.status or {}) do
		parts[#parts + 1] = "status:" .. s
	end
	if spec and spec.path then
		parts[#parts + 1] = "path:" .. spec.path
	end
	if spec and spec.due then
		parts[#parts + 1] = "due:" .. tostring(spec.due.raw)
	end
	return table.concat(parts, " ")
end

---------------------------------------------------------------------
-- 匹配
---------------------------------------------------------------------

--- git 派生伪标签前缀（如 #git:dirty / #git:branch:main）。
local GIT_PREFIX = "git:"

--- 单个筛选标签是否命中（普通 #tag 或 git 派生伪标签）。
---@param task table|nil 存储任务（git 伪标签需要）
---@param line_tags string[]|nil 行内标签（TODO 文件路径）
---@param tag string
---@param ctx table
---@return boolean
local function tag_hits(task, line_tags, tag, ctx)
	if tag == GIT_PREFIX .. "dirty" then
		local loc = task and task.locations and task.locations.code
		return loc ~= nil and ctx.dirty ~= nil and ctx.dirty[loc.path] == true
	end
	if tag:sub(1, #GIT_PREFIX + 7) == GIT_PREFIX .. "branch:" then
		return task ~= nil and task.git ~= nil and task.git.branch == tag:sub(#GIT_PREFIX + 8)
	end
	return tags_utils.contains(line_tags or {}, tag)
end

--- 状态是否命中（空条件恒真；active 匹配所有非终态）。
---@param status string|nil
---@param want string[]
---@return boolean
local function status_hits(status, want)
	if #want == 0 then
		return true
	end
	status = status or config.get_default_status()
	for _, w in ipairs(want) do
		if w == "active" then
			if types.is_active_status(status) then
				return true
			end
		elseif status == w then
			return true
		end
	end
	return false
end

--- 把 glob 转为 Lua 模式（* / ? 通配，其余字符转义）。
---@param glob string
---@return string
local function glob_pattern(glob)
	local out = {}
	for i = 1, #glob do
		local c = glob:sub(i, i)
		if c == "*" then
			out[#out + 1] = ".*"
		elseif c == "?" then
			out[#out + 1] = "."
		else
			out[#out + 1] = vim.pesc(c)
		end
	end
	return table.concat(out)
end

--- 任务路径是否命中（TODO 路径或代码锚点路径；无 glob 字符时按子串匹配）。
---@param task table|nil
---@param pattern string|nil
---@return boolean
local function path_hits(task, pattern)
	if not pattern then
		return true
	end
	local matcher = pattern:find("[*?]") and glob_pattern(pattern) or nil
	for _, kind in ipairs({ "todo", "code" }) do
		local loc = task and task.locations and task.locations[kind]
		local path = loc and loc.path
		if path then
			path = path:gsub("\\", "/")
			if matcher then
				if path:find(matcher) then
					return true
				end
			elseif path:find(pattern, 1, true) then
				return true
			end
		end
	end
	return false
end

--- 唯一的一条匹配链：四个条件（标签 AND / 状态 / 到期 / 路径）按固定顺序短路。
---
--- 匹配字段由调用方给出——TODO 文件走「行内解析优先、store 兜底」，抽屉/日历直接给
--- store 任务。之前这里有两份逐字重复的实现，任何一处改了条件顺序或语义，另一个
--- 入口就会悄悄漂掉；现在只有一个地方需要维护。
---@class Todo2FilterFields
---@field task table|nil 存储任务（git 伪标签与路径条件需要；可为 nil）
---@field tags string[]|nil 标签（行内优先）
---@field status string|nil 状态（store 优先，行内兜底）
---@field due string|nil 到期日（store 优先，行内兜底）
---@param fields Todo2FilterFields
---@param spec Todo2FilterSpec
---@param ctx table
---@return boolean
local function matches(fields, spec, ctx)
	for _, tag in ipairs(spec.tags) do
		if not tag_hits(fields.task, fields.tags, tag, ctx or {}) then
			return false
		end
	end
	if not status_hits(fields.status, spec.status) then
		return false
	end
	if not due_utils.hit(fields.due, spec.due, fields.status) then
		return false
	end
	return path_hits(fields.task, spec.path)
end

--- 存储任务是否命中规格（全部标签 AND，状态与路径各为一组条件）。
---@param task table 存储任务（core.get_task 结果）
---@param spec Todo2FilterSpec
---@param ctx table
---@return boolean
function M.task_matches(task, spec, ctx)
	if not task or not spec then
		return false
	end
	local core_data = task.core or {}
	return matches({
		task = task,
		tags = core_data.tags,
		status = core_data.status,
		due = core_data.due,
	}, spec, ctx or {})
end

--- 单行是否命中规格（TODO 文件路径：行内标签优先，其余条件查 store）。
---@param parsed table parse_task_line 结果
---@param spec Todo2FilterSpec
---@param ctx table
---@return boolean
local function line_matches(parsed, spec, ctx)
	local task = parsed.id and core.get_task(parsed.id) or nil
	local core_data = (task and task.core) or {}
	return matches({
		task = task,
		tags = parsed.tags,
		status = core_data.status or parsed.status,
		due = core_data.due or parsed.due,
	}, spec, ctx)
end

--- 预计算 git 伪标签所需的上下文（仅在用到时才调用 git）。
---@param spec Todo2FilterSpec|nil
---@return table
function M.build_git_context(spec)
	local ctx = {}
	for _, tag in ipairs(spec and spec.tags or {}) do
		if tag == GIT_PREFIX .. "dirty" then
			ctx.dirty = git.dirty_files()
		end
	end
	return ctx
end

---------------------------------------------------------------------
-- TODO 文件（隐藏非命中行）
---------------------------------------------------------------------

--- 返回缓冲区的筛选规格；未筛选返回 nil。
---@param bufnr number
---@return Todo2FilterSpec|nil
function M.active(bufnr)
	return state[bufnr]
end

--- 清除筛选（含已绘制的隐藏标记）。
---@param bufnr number
function M.clear(bufnr)
	state[bufnr] = nil
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	end
end

--- 计算每一行的可见性。
---@param lines string[]
---@param spec Todo2FilterSpec
---@return boolean[]
local function compute_visibility(lines, spec)
	local n = #lines
	local ctx = M.build_git_context(spec)
	---@type table<number, { level: number, match: boolean, vis: boolean }>
	local info = {}
	for i = 1, n do
		local parsed = format.parse_task_line(lines[i])
		if parsed then
			info[i] = { level = parsed.level, match = line_matches(parsed, spec, ctx), vis = false }
		end
	end

	-- 自顶向下：自身命中或任一祖先命中 → 可见
	local stack = {}
	for i = 1, n do
		local it = info[i]
		if it then
			while #stack > 0 and stack[#stack].level >= it.level do
				table.remove(stack)
			end
			local parent_vis = #stack > 0 and stack[#stack].vis or false
			it.vis = it.match or parent_vis
			stack[#stack + 1] = { level = it.level, vis = it.vis }
		end
	end

	-- 自底向上：任一后代命中 → 祖先可见
	local stack2 = {}
	for i = 1, n do
		local it = info[i]
		if it then
			while #stack2 > 0 and stack2[#stack2].level >= it.level do
				table.remove(stack2)
			end
			if it.match then
				for _, anc in ipairs(stack2) do
					anc.vis = true
				end
			end
			stack2[#stack2 + 1] = it
		end
	end

	-- 汇总：非任务行沿用上方最近任务行的可见性
	local visible = {}
	local current = true
	for i = 1, n do
		local it = info[i]
		if it then
			current = it.vis
		end
		visible[i] = current
	end
	return visible
end

--- 按当前筛选规格重新计算并隐藏不匹配的行。
---@param bufnr number
function M.refresh(bufnr)
	local spec = state[bufnr]
	if not spec then
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		state[bufnr] = nil
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local visible = compute_visibility(lines, spec)
	for i = 1, #lines do
		if not visible[i] then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, i - 1, 0, {
				end_row = i - 1,
				end_col = #lines[i],
				conceal_lines = "",
			})
		end
	end

	-- 确保窗口启用了 conceal：buffer 可能是在未显示时就被渲染的
	-- （此时 conceallevel 仍为 0），这样隐藏标记才会真正生效。
	pcall(function()
		require("todo2.render.conceal").setup_window_conceal(bufnr)
	end)
end

--- 设置并立即应用筛选；空规格等价于清除。
---@param bufnr number
---@param spec Todo2FilterSpec
function M.set(bufnr, spec)
	if M.is_empty(spec) then
		M.clear(bufnr)
		return
	end
	state[bufnr] = spec
	M.refresh(bufnr)
end

return M
