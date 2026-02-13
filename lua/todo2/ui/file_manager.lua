-- lua/todo2/ui/file_manager.lua
--- @module todo2.ui.file_manager

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local nvim_store = require("todo2.store.nvim_store")
local link_mod = require("todo2.store.link")

---------------------------------------------------------------------
-- 智能文件缓存
---------------------------------------------------------------------
local _file_cache = {
	data = {},
	timestamps = {},
	max_age = 300,
}

local function cleanup_cache()
	local current_time = os.time()
	local to_remove = {}

	for project, timestamp in pairs(_file_cache.timestamps) do
		if current_time - timestamp > _file_cache.max_age then
			table.insert(to_remove, project)
		end
	end

	for _, project in ipairs(to_remove) do
		_file_cache.data[project] = nil
		_file_cache.timestamps[project] = nil
	end
end

local function get_project()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

local function get_project_dir(project)
	return vim.fn.expand("~/.todo-files/" .. project)
end

function M.get_todo_files(project, force_refresh)
	if not project then
		project = get_project()
	end

	cleanup_cache()

	local current_time = os.time()
	local cache_entry = _file_cache.data[project]
	local cache_time = _file_cache.timestamps[project]

	if not force_refresh and cache_entry and cache_time then
		if current_time - cache_time < _file_cache.max_age then
			return cache_entry
		end
	end

	local dir = get_project_dir(project)
	if vim.fn.isdirectory(dir) == 0 then
		_file_cache.data[project] = {}
		_file_cache.timestamps[project] = current_time
		return {}
	end

	local files = vim.fn.globpath(dir, "*.todo.md", false, true)
	_file_cache.data[project] = files
	_file_cache.timestamps[project] = current_time

	return files
end

function M.select_todo_file(scope, callback)
	local choices = {}
	local projects = {}

	if scope == "current" then
		local project = get_project()
		projects = { project }
	elseif scope == "all" then
		local root = vim.fn.expand("~/.todo-files")
		local handle = vim.loop.fs_scandir(root)
		if handle then
			while true do
				local name = vim.loop.fs_scandir_next(handle)
				if not name then
					break
				end
				table.insert(projects, name)
			end
		end
	end

	for _, project in ipairs(projects) do
		local files = M.get_todo_files(project)
		for _, f in ipairs(files) do
			table.insert(choices, { project = project, path = f })
		end
	end

	if #choices == 0 then
		vim.notify("未找到 TODO 文件", vim.log.levels.WARN)
		return
	end

	vim.ui.select(choices, {
		prompt = "🗂️ 选择 TODO 文件：",
		format_item = function(item)
			return string.format("%-20s • %s", item.project, vim.fn.fnamemodify(item.path, ":t"))
		end,
	}, callback)
end

---------------------------------------------------------------------
-- ⭐ 只改这一处：创建文件时写入 ## Active 而不是文件名
---------------------------------------------------------------------
function M.create_todo_file(default_name)
	local project = get_project()
	local dir = get_project_dir(project)
	vim.fn.mkdir(dir, "p")

	local filename = default_name or vim.fn.input("📝 请输入 TODO 文件名: ")
	if filename == "" then
		return nil
	end

	if not filename:match("%.todo%.md$") then
		filename = filename .. ".todo.md"
	end

	local path = dir .. "/" .. filename
	if vim.fn.filereadable(path) == 1 then
		vim.notify("文件已存在: " .. filename, vim.log.levels.WARN)
		return path
	end

	local fd = io.open(path, "w")
	if fd then
		-- ⭐ 只改这一行：原来的 "# TODO - " .. filename 换成 "## Active"
		fd:write("## Active\n\n")

		fd:close()
		vim.notify("创建成功: " .. path, vim.log.levels.INFO)

		-- 清除缓存
		_file_cache.data[project] = nil
		_file_cache.timestamps[project] = nil

		return path
	else
		vim.notify("无法创建文件: " .. path, vim.log.levels.ERROR)
		return nil
	end
end

function M.delete_todo_file(path)
	-- 修复：使用 vim.fn.fnamemodify 而不是直接调用 fnamodify
	local norm = vim.fn.fnamemodify(path, ":p")

	if vim.fn.filereadable(norm) == 0 then
		vim.notify("文件不存在: " .. norm, vim.log.levels.ERROR)
		return false
	end

	local filename = vim.fn.fnamemodify(norm, ":t")
	local confirm = vim.fn.input("🗑️ 确定删除 " .. filename .. " 吗? (y/n): "):lower()
	if confirm ~= "y" then
		return false
	end

	local ok = os.remove(norm)
	if not ok then
		vim.notify("删除失败: " .. norm, vim.log.levels.ERROR)
		return false
	end

	local count = 0
	local TODO_PREFIX = "todo.links.todo."
	local CODE_PREFIX = "todo.links.code."

	local todo_ids = nvim_store.get_namespace_keys(TODO_PREFIX:sub(1, -2)) or {}
	for _, id in ipairs(todo_ids) do
		local link = nvim_store.get_key(TODO_PREFIX .. id)
		-- 修复：这里也需要使用 vim.fn.fnamemodify
		if link and vim.fn.fnamemodify(link.path, ":p") == norm then
			link_mod.delete_todo(id)
			count = count + 1
		end
	end

	local code_ids = nvim_store.get_namespace_keys(CODE_PREFIX:sub(1, -2)) or {}
	for _, id in ipairs(code_ids) do
		local link = nvim_store.get_key(CODE_PREFIX .. id)
		-- 修复：这里也需要使用 vim.fn.fnamemodify
		if link and vim.fn.fnamemodify(link.path, ":p") == norm then
			link_mod.delete_code(id)
			count = count + 1
		end
	end

	_file_cache.data = {}
	_file_cache.timestamps = {}

	vim.notify("删除成功，并清理了 " .. count .. " 个相关标签", vim.log.levels.INFO)
	return true
end

function M.clear_cache()
	_file_cache.data = {}
	_file_cache.timestamps = {}
	vim.notify("已清除文件缓存", vim.log.levels.INFO)
end

return M
