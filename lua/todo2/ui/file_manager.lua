-- lua/todo2/ui/file_manager.lua
--- @module todo2.ui.file_manager
-- 应用最新的 store.link 和 store.nvim_store API

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
-- 删除 TODO 文件（更新为最新存储 API）
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

	-- 2. ⭐ 使用最新的 store.link 和 store.nvim_store API 清理相关链接
	local nvim_store = module.get("store.nvim_store")
	local link_mod = module.get("store.link")
	local count = 0

	if nvim_store and link_mod then
		-- 存储前缀常量（与 store.link 保持一致）
		local TODO_PREFIX = "todo.links.todo."
		local CODE_PREFIX = "todo.links.code."

		-- 清理所有与该文件关联的 TODO 链接（包括非活跃的）
		local todo_ids = nvim_store.get_namespace_keys(TODO_PREFIX:sub(1, -2)) or {}
		for _, id in ipairs(todo_ids) do
			local link = nvim_store.get_key(TODO_PREFIX .. id)
			if link and vim.fn.fnamemodify(link.path, ":p") == norm then
				link_mod.delete_todo(id) -- 内部处理索引移除
				count = count + 1
			end
		end

		-- 清理所有与该文件关联的代码链接（包括非活跃的）
		local code_ids = nvim_store.get_namespace_keys(CODE_PREFIX:sub(1, -2)) or {}
		for _, id in ipairs(code_ids) do
			local link = nvim_store.get_key(CODE_PREFIX .. id)
			if link and vim.fn.fnamemodify(link.path, ":p") == norm then
				link_mod.delete_code(id) -- 内部处理索引移除
				count = count + 1
			end
		end
	end

	-- 3. 清理文件缓存
	_file_cache.data = {}
	_file_cache.timestamps = {}

	-- 4. 清理当前 buffer 的孤立标记（manager 模块可能也已更新）
	-- FIX:ref:420cb0
	local manager = module.get("manager")
	if manager and manager.fix_orphan_links_in_buffer then
		manager.fix_orphan_links_in_buffer()
	end

	vim.notify("删除成功，并清理了 " .. count .. " 个相关标签", vim.log.levels.INFO)
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
