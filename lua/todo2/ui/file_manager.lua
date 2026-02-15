-- lua/todo2/ui/file_manager.lua
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

-- ⭐ 完全重写：删除 TODO 文件时，同步删除所有对应的代码标记
function M.delete_todo_file(path)
	local deleter = require("todo2.link.deleter") -- ⭐ 新增：引入删除器
	-- 修复：使用 vim.fn.fnamemodify 而不是直接调用 fnamodify
	local norm = vim.fn.fnamemodify(path, ":p")

	if vim.fn.filereadable(norm) == 0 then
		vim.notify("文件不存在: " .. norm, vim.log.levels.ERROR)
		return false
	end

	local filename = vim.fn.fnamemodify(norm, ":t")
	local confirm = vim.fn
		.input("🗑️ 确定删除 " .. filename .. " 吗?\n这将会删除所有对应的代码标记! (y/n): ")
		:lower()
	if confirm ~= "y" then
		return false
	end

	-- 收集所有属于这个文件的 ID
	local ids_to_delete = {}
	local TODO_PREFIX = "todo.links.todo."
	local CODE_PREFIX = "todo.links.code."

	-- 获取所有 TODO 链接
	local todo_ids = nvim_store.get_namespace_keys(TODO_PREFIX:sub(1, -2)) or {}
	for _, id in ipairs(todo_ids) do
		local link = nvim_store.get_key(TODO_PREFIX .. id)
		-- 修复：这里也需要使用 vim.fn.fnamemodify
		if link and vim.fn.fnamemodify(link.path, ":p") == norm then
			table.insert(ids_to_delete, id)
		end
	end

	-- 显示正在删除的提示
	if #ids_to_delete > 0 then
		vim.notify(string.format("正在删除 %d 个任务的代码标记...", #ids_to_delete), vim.log.levels.INFO)
	end

	-- 第一步：删除所有对应的代码标记
	local deleted_count = 0
	local failed_count = 0

	-- 收集所有代码链接，按文件分组以便批量处理
	local code_links_by_file = {}

	for _, id in ipairs(ids_to_delete) do
		local code_link = nvim_store.get_key(CODE_PREFIX .. id)
		if code_link and code_link.path and code_link.line then
			local file = code_link.path
			if not code_links_by_file[file] then
				code_links_by_file[file] = {}
			end
			table.insert(code_links_by_file[file], {
				id = id,
				line = code_link.line,
			})
		end
	end

	-- 按文件分组删除代码标记
	for file, links in pairs(code_links_by_file) do
		-- 按行号降序排序，确保删除时行号不会变化
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		-- 批量删除行
		for _, link in ipairs(links) do
			local ok = pcall(function()
				-- 使用 deleter 的专用函数来删除代码标记
				deleter.delete_code_link_by_id(link.id)
				deleted_count = deleted_count + 1
			end)

			if not ok then
				failed_count = failed_count + 1
				vim.notify(string.format("删除标记 %s 失败", link.id:sub(1, 6)), vim.log.levels.WARN)
			end
		end
	end

	-- 第二步：从存储中删除所有相关的 TODO 和 CODE 记录
	local store_deleted = 0
	for _, id in ipairs(ids_to_delete) do
		if link_mod.delete_todo(id) then
			store_deleted = store_deleted + 1
		end
		if link_mod.delete_code(id) then
			-- 已经计数过了，这里只是为了确保清理
		end
	end

	-- 第三步：删除物理文件
	local ok = os.remove(norm)
	if not ok then
		vim.notify("删除失败: " .. norm, vim.log.levels.ERROR)
		return false
	end

	-- 清除缓存
	_file_cache.data = {}
	_file_cache.timestamps = {}

	-- 显示结果
	if deleted_count > 0 then
		vim.notify(
			string.format("✅ 成功删除 TODO 文件\n📝 已删除 %d 个代码标记", deleted_count),
			vim.log.levels.INFO
		)
	else
		vim.notify("✅ 成功删除 TODO 文件（无相关代码标记）", vim.log.levels.INFO)
	end

	if failed_count > 0 then
		vim.notify(
			string.format("⚠️ 有 %d 个标记删除失败，请手动检查", failed_count),
			vim.log.levels.WARN
		)
	end

	return true
end

function M.clear_cache()
	_file_cache.data = {}
	_file_cache.timestamps = {}
	vim.notify("已清除文件缓存", vim.log.levels.INFO)
end

return M
