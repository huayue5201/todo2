-- lua/todo2/ui/file_manager.lua
--- @module todo2.ui.file_manager

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local link = require("todo2.store.link")
local nvim_store = require("todo2.store.nvim_store")

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

---------------------------------------------------------------------
-- 获取 TODO 文件列表
---------------------------------------------------------------------
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
		projects = { get_project() }
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
-- 创建 TODO 文件（使用最新模板逻辑）
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
	if not fd then
		vim.notify("无法创建文件: " .. path, vim.log.levels.ERROR)
		return nil
	end

	-- ⭐ 使用最新的纯展示模板（Active 区域固定存在）
	local lines = config.generate_new_file_content()
	for _, line in ipairs(lines) do
		fd:write(line .. "\n")
	end
	fd:close()

	vim.notify("创建成功: " .. path, vim.log.levels.INFO)

	-- 清除缓存
	_file_cache.data[project] = nil

	return path
end

---------------------------------------------------------------------
-- 重命名 TODO 文件
---------------------------------------------------------------------
function M.rename_todo_file(path)
	local norm = vim.fn.fnamemodify(path, ":p")

	if vim.fn.filereadable(norm) == 0 then
		vim.notify("文件不存在: " .. norm, vim.log.levels.ERROR)
		return false
	end

	local old_dir = vim.fn.fnamemodify(norm, ":h")
	local old_name = vim.fn.fnamemodify(norm, ":t")
	local old_name_without_ext = old_name:gsub("%.todo%.md$", "")

	local new_name = vim.fn.input("📝 请输入新文件名 [" .. old_name_without_ext .. "]: ", old_name_without_ext)
	if new_name == "" then
		return false
	end

	if not new_name:match("%.todo%.md$") then
		new_name = new_name .. ".todo.md"
	end

	local new_path = old_dir .. "/" .. new_name

	if vim.fn.filereadable(new_path) == 1 then
		vim.notify("文件已存在: " .. new_name, vim.log.levels.ERROR)
		return false
	end

	local confirm = vim.fn.input("🔄 确认将 " .. old_name .. " 重命名为 " .. new_name .. "? (y/n): "):lower()
	if confirm ~= "y" then
		return false
	end

	local ok, err = os.rename(norm, new_path)
	if not ok then
		vim.notify("重命名失败: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end

	-- 更新存储中的路径引用
	local TODO_PREFIX = "todo.links.todo."
	local ids_updated = {}

	local todo_ids = nvim_store.get_namespace_keys(TODO_PREFIX:sub(1, -2)) or {}
	for _, id in ipairs(todo_ids) do
		local link = nvim_store.get_key(TODO_PREFIX .. id)
		if link and vim.fn.fnamemodify(link.path, ":p") == norm then
			link.path = new_path
			link.updated_at = os.time()
			nvim_store.set_key(TODO_PREFIX .. id, link)
			table.insert(ids_updated, id)
		end
	end

	_file_cache.data = {}
	_file_cache.timestamps = {}

	if #ids_updated > 0 then
		vim.notify(
			string.format("✅ 成功重命名文件并更新 %d 个任务引用", #ids_updated),
			vim.log.levels.INFO
		)
	else
		vim.notify("✅ 成功重命名文件", vim.log.levels.INFO)
	end

	local bufnr = vim.fn.bufnr(norm)
	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_set_name(bufnr, new_path)
	end

	return true
end

---------------------------------------------------------------------
-- 删除 TODO 文件
---------------------------------------------------------------------
function M.delete_todo_file(path)
	local deleter = require("todo2.task.deleter")
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

	local ids_to_delete = {}
	local TODO_PREFIX = "todo.links.todo."
	local CODE_PREFIX = "todo.links.code."

	local todo_ids = nvim_store.get_namespace_keys(TODO_PREFIX:sub(1, -2)) or {}
	for _, id in ipairs(todo_ids) do
		local link = nvim_store.get_key(TODO_PREFIX .. id)
		if link and vim.fn.fnamemodify(link.path, ":p") == norm then
			table.insert(ids_to_delete, id)
		end
	end

	if #ids_to_delete > 0 then
		vim.notify(string.format("正在删除 %d 个任务的代码标记...", #ids_to_delete), vim.log.levels.INFO)
	end

	local deleted_count = 0
	local failed_count = 0
	local code_links_by_file = {}

	for _, id in ipairs(ids_to_delete) do
		local code_link = nvim_store.get_key(CODE_PREFIX .. id)
		if code_link and code_link.path and code_link.line then
			if code_link.context then
				code_link.context_valid = false
				code_link.context_deleted_at = os.time()
				nvim_store.set_key(CODE_PREFIX .. id, code_link)
			end

			local file = code_link.path
			code_links_by_file[file] = code_links_by_file[file] or {}
			table.insert(code_links_by_file[file], { id = id, line = code_link.line })
		end
	end

	for file, links in pairs(code_links_by_file) do
		table.sort(links, function(a, b)
			return a.line > b.line
		end)

		local bufnr = vim.fn.bufadd(file)
		vim.fn.bufload(bufnr)

		for _, link in ipairs(links) do
			local ok = pcall(function()
				deleter.delete_code_link_by_id(link.id)
				deleted_count = deleted_count + 1
			end)
			if not ok then
				failed_count = failed_count + 1
				vim.notify(string.format("删除标记 %s 失败", link.id:sub(1, 6)), vim.log.levels.WARN)
			end
		end
	end

	for _, id in ipairs(ids_to_delete) do
		link.delete_todo(id)
		link.delete_code(id)
	end

	local ok = os.remove(norm)
	if not ok then
		vim.notify("删除失败: " .. norm, vim.log.levels.ERROR)
		return false
	end

	_file_cache.data = {}
	_file_cache.timestamps = {}

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

---------------------------------------------------------------------
-- 清除缓存
---------------------------------------------------------------------
function M.clear_cache()
	_file_cache.data = {}
	_file_cache.timestamps = {}
	vim.notify("已清除文件缓存", vim.log.levels.INFO)
end

return M
