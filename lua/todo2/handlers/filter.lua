-- lua/todo2/handlers/filter.lua
-- :TodoFilter —— 按标签 / 状态 / 路径筛选，并管理命名筛选。
--
--   :TodoFilter [spec...]        应用临时筛选（空 / ! / * 清除）
--   :TodoFilter save NAME [spec] 保存当前或指定筛选
--   :TodoFilter @NAME            应用命名筛选
--   :TodoFilter list             列出命名筛选
--   :TodoFilter delete NAME      删除命名筛选

local M = {}

local config = require("todo2.config")
local filter = require("todo2.render.filter")
local buffer = require("todo2.utils.buffer")
local file = require("todo2.utils.file")
local drawer = require("todo2.ui.drawer")

local function notify(msg, level)
	vim.notify("[todo2] " .. msg, level or vim.log.levels.INFO)
end

--- 当前作用目标：抽屉（虚拟树）或 TODO 文件缓冲区。
---@return "drawer"|"buffer"|nil, number
local function target()
	local bufnr = vim.api.nvim_get_current_buf()
	if drawer.is_drawer(bufnr) then
		return "drawer", bufnr
	end
	if file.is_todo_file(buffer.get_path(bufnr)) then
		return "buffer", bufnr
	end
	return nil, bufnr
end

--- 当前已应用的筛选规格。
---@param where "drawer"|"buffer"
---@param bufnr number
---@return Todo2FilterSpec|nil
local function active_spec(where, bufnr)
	return where == "drawer" and drawer.active_filter() or filter.active(bufnr)
end

---@param where "drawer"|"buffer"
---@param bufnr number
---@param spec Todo2FilterSpec
local function apply(where, bufnr, spec)
	if where == "drawer" then
		drawer.set_filter(spec)
	else
		filter.set(bufnr, spec)
	end
	notify("Filter: " .. filter.describe(spec))
end

---@param name string|nil
---@return boolean
local function valid_name(name)
	if not name or not name:match("^[%w_-]+$") then
		notify("Filter name must be a single word ([A-Za-z0-9_-])", vim.log.levels.WARN)
		return false
	end
	return true
end

---@return table<string, table>
local function saved_filters()
	return vim.deepcopy(config.get("filters") or {})
end

---@param action "save"|"delete"|"list"
---@param fargs string[]
---@param where "drawer"|"buffer"|nil
---@param bufnr number
local function manage(action, fargs, where, bufnr)
	if action == "list" then
		local names = {}
		for name in pairs(config.get("filters") or {}) do
			names[#names + 1] = name
		end
		table.sort(names)
		if #names == 0 then
			notify("No saved filters (use :TodoFilter save NAME)")
		else
			notify("Saved filters: " .. table.concat(names, ", "))
		end
		return
	end

	local name = fargs[2]
	if not valid_name(name) then
		return
	end

	local all = saved_filters()
	if action == "delete" then
		if not all[name] then
			notify("No such filter: " .. name, vim.log.levels.WARN)
			return
		end
		all[name] = nil
		config.set("filters", all)
		notify("Deleted filter: " .. name)
		return
	end

	-- save：显式词优先，否则保存当前已应用的筛选
	local spec, err
	local rest = {}
	for i = 3, #fargs do
		rest[#rest + 1] = fargs[i]
	end
	if #rest > 0 then
		spec, err = filter.parse(rest)
		if err then
			notify(err, vim.log.levels.WARN)
			return
		end
	elseif where then
		spec = active_spec(where, bufnr)
	end
	if filter.is_empty(spec) then
		notify("Nothing to save (apply a filter first, or pass conditions)", vim.log.levels.WARN)
		return
	end
	all[name] = filter.to_table(spec)
	config.set("filters", all)
	notify("Saved filter '" .. name .. "': " .. filter.describe(spec))
end

--- :TodoFilter 入口。
---@param cmd_args table
function M.filter_cmd(cmd_args)
	local fargs = cmd_args.fargs or {}
	local first = fargs[1]
	local where, bufnr = target()

	local clear = cmd_args.bang or first == nil or first == "*" or first == "clear"
	if clear then
		if where == "drawer" then
			drawer.clear_filter()
		elseif where == "buffer" then
			filter.clear(bufnr)
		else
			notify("Filtering only works in TODO files or the drawer", vim.log.levels.WARN)
			return
		end
		notify("Filter cleared")
		return
	end

	if first == "save" or first == "delete" or first == "list" then
		manage(first, fargs, where, bufnr)
		return
	end

	if not where then
		notify("Filtering only works in TODO files or the drawer", vim.log.levels.WARN)
		return
	end

	if first:sub(1, 1) == "@" then
		local name = first:sub(2)
		local saved = (config.get("filters") or {})[name]
		if not saved then
			notify("No such filter: " .. name, vim.log.levels.WARN)
			return
		end
		local spec, err = filter.from_table(saved)
		if err then
			notify(err, vim.log.levels.WARN)
			return
		end
		apply(where, bufnr, spec)
		return
	end

	local spec, err = filter.parse(fargs)
	if err then
		notify(err, vim.log.levels.WARN)
		return
	end
	apply(where, bufnr, spec)
end

return M
