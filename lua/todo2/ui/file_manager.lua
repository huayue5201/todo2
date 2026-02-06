-- lua/todo2/ui/file_manager.lua
--- @module todo2.ui.file_manager

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 智能文件缓存（带过期时间）
---------------------------------------------------------------------
local _file_cache = {
	data = {},
	timestamps = {},
	max_age = 300, -- 5分钟过期
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

---------------------------------------------------------------------
-- 选择 TODO 文件
---------------------------------------------------------------------
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

	-- 批量获取文件（减少重复扫描）
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
-- 创建 TODO 文件
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
		fd:write("# TODO - " .. filename:gsub("%.todo%.md$", "") .. "\n\n")
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

---------------------------------------------------------------------
-- 删除 TODO 文件
---------------------------------------------------------------------
function M.delete_todo_file(path)
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

	-- 1. 删除文件
	local ok = os.remove(norm)
	if not ok then
		vim.notify("删除失败: " .. norm, vim.log.levels.ERROR)
		return false
	end

	-- 2. 清理 store 中与该文件相关的 todo_links
	local store = module.get("store")
	local todo_links = store.find_todo_links_by_file(norm)

	for _, link in ipairs(todo_links) do
		store.delete_todo_link(link.id)

		local code = store.get_code_link(link.id)
		if code then
			store.delete_code_link(link.id)
		end
	end

	-- 3. 清理缓存
	_file_cache.data = {}
	_file_cache.timestamps = {}

	-- 4. 删除文件后清理当前 buffer 的孤立标记
	local manager = module.get("manager")
	if manager and manager.fix_orphan_links_in_buffer then
		manager.fix_orphan_links_in_buffer()
	end

	vim.notify("删除成功，并清理了 " .. #todo_links .. " 个相关标签", vim.log.levels.INFO)
	return true
end

---------------------------------------------------------------------
-- 清理缓存
---------------------------------------------------------------------
function M.clear_cache()
	_file_cache.data = {}
	_file_cache.timestamps = {}
	vim.notify("已清除文件缓存", vim.log.levels.INFO)
end

-- 添加缓存统计
function M.get_cache_stats()
	return {
		cached_projects = vim.tbl_count(_file_cache.data),
		total_entries = 0, -- 可以添加更详细的统计
	}
end

return M
