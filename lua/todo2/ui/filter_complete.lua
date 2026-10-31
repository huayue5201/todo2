-- lua/todo2/ui/filter_complete.lua
--- @brief 过滤表达式的补全候选（命令行 Tab 与抽屉输入浮窗共用这一份）。
---
--- 一条规则：`字段:值`，裸词就是标签。所以候选只有四类：
---   1. 字段名        tag: status: path: due: start: axis: scope:
---   2. 标签值        #backend …
---   3. 枚举值        status:doing / due:week / axis:commit / scope:tree …
---   4. 已存筛选名    @本周  （以及 save / delete / list 三个动作词）

local M = {}

local config = require("todo2.config")
local file_manager = require("todo2.ui.file_manager")

M.FIELDS = { "tag:", "status:", "path:", "due:", "start:", "axis:", "scope:" }
M.ACTIONS = { "save", "delete", "list" }
M.DUE_WORDS = { "today", "tomorrow", "week", "month", "overdue", "none" }
M.AXES = { "commit", "activity", "all" }
M.SCOPES = { "self", "tree" }

local TAG_TTL = 2

local tag_cache = { at = 0, tags = {} }

--- 项目内出现过的所有标签（跨所有 TODO 文件），带 2 秒缓存。
---@return string[]
function M.tags()
	local now = os.time()
	if now - tag_cache.at < TAG_TTL then
		return tag_cache.tags
	end

	local seen, out = {}, {}
	local ok, files = pcall(file_manager.get_todo_files)
	if ok then
		for _, path in ipairs(files or {}) do
			local lines_ok, lines = pcall(vim.fn.readfile, path)
			if lines_ok then
				for _, line in ipairs(lines) do
					for tag in line:gmatch("#([%w%-_%.]+)") do
						if not seen[tag] then
							seen[tag] = true
							out[#out + 1] = tag
						end
					end
				end
			end
		end
	end
	table.sort(out)

	tag_cache = { at = now, tags = out }
	return out
end

--- 命名筛选的名字列表。
---@return string[]
function M.saved_names()
	local names = {}
	for name in pairs(config.get("filters") or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

--- 某个字段的合法取值。
---@param field string
---@return string[]
function M.field_values(field)
	if field == "tag" then
		return M.tags()
	elseif field == "status" then
		local labels = { "active" }
		for _, item in ipairs(require("todo2.core.status").get_cycle()) do
			if item.label then
				labels[#labels + 1] = item.label
			end
		end
		return labels
	elseif field == "due" or field == "start" then
		return M.DUE_WORDS
	elseif field == "axis" then
		return M.AXES
	elseif field == "scope" then
		return M.SCOPES
	end
	return {}
end

--- 补全「当前这个 token」。命令行传 arglead，浮窗传光标前最后一个 token。
---@param token string
---@return string[]
function M.complete_token(token)
	local items = {}
	if token == "" then
		return M.FIELDS
	end

	local field, partial = token:match("^([%a_]+):(.*)$")
	if field then
		for _, value in ipairs(M.field_values(field)) do
			if vim.startswith(value, partial) then
				items[#items + 1] = field .. ":" .. value
			end
		end
		return items
	end

	for _, cand in ipairs(M.FIELDS) do
		if vim.startswith(cand, token) then
			items[#items + 1] = cand
		end
	end
	for _, action in ipairs(M.ACTIONS) do
		if vim.startswith(action, token) then
			items[#items + 1] = action
		end
	end
	for _, name in ipairs(M.saved_names()) do
		local at = "@" .. name
		if vim.startswith(at, token) then
			items[#items + 1] = at
		elseif vim.startswith(name, token) then
			items[#items + 1] = name
		end
	end
	for _, tag in ipairs(M.tags()) do
		local hash = "#" .. tag
		if vim.startswith(hash, token) then
			items[#items + 1] = hash
		elseif vim.startswith(tag, token) then
			items[#items + 1] = tag
		end
	end
	return items
end

--- 补全整行文本里光标所在的 token。
---@param prefix string 光标之前的整行内容
---@return string[] items
---@return integer from 1 基字节列，替换起点
function M.complete(prefix)
	local start = (prefix:match("^.*()%s") or 0) + 1
	return M.complete_token(prefix:sub(start)), start
end

--- 命令行 `:TodoFilter` 的 complete 回调。
---@param arglead string
---@return string[]
function M.command_line(arglead)
	return M.complete_token(arglead or "")
end

--- 清空标签缓存（测试与切项目时用）。
function M.reset()
	tag_cache = { at = 0, tags = {} }
end

return M
