-- lua/todo2/ui/file_manager.lua
--- @module todo2.ui.file_manager
-- ⭐ 修复版：使用新的 link 模块接口

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local config = require("todo2.config")
local core = require("todo2.store.link.core") -- ⭐ 改为使用 core
local events = require("todo2.core.events") -- ⭐ 添加 events
local index = require("todo2.store.index") -- ⭐ 添加 index

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

	-- 使用最新的纯展示模板（Active 区域固定存在）
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
-- ⭐ 修复：重命名 TODO 文件（使用 core 接口）
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

	-- 执行文件重命名
	local ok, err = os.rename(norm, new_path)
	if not ok then
		vim.notify("重命名失败: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end

	-- ⭐ 使用 core 的 handle_file_rename 更新所有相关任务
	local result = core.handle_file_rename(norm, new_path)

	-- 清除缓存
	_file_cache.data = {}
	_file_cache.timestamps = {}

	-- ⭐ 触发事件刷新
	if result.updated > 0 then
		events.on_state_changed({
			source = "file_manager.rename",
			ids = result.affected_ids,
			files = { new_path, norm },
		})
	end

	-- 更新 buffer 名称
	local bufnr = vim.fn.bufnr(norm)
	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_set_name(bufnr, new_path)
	end

	vim.notify(
		string.format("✅ 成功重命名文件并更新 %d 个任务引用", result.updated),
		vim.log.levels.INFO
	)

	return true
end

---------------------------------------------------------------------
-- ⭐ 修复：删除 TODO 文件（全面获取所有相关任务）
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

	-- ⭐ 获取该文件的所有相关任务
	local ids_to_delete = {}
	local id_set = {}

	-- 1. 获取TODO文件中的任务
	local todo_links = index.find_todo_links_by_file(norm) or {}
	for _, task in ipairs(todo_links) do
		if task and task.id and not id_set[task.id] then
			id_set[task.id] = true
			table.insert(ids_to_delete, task.id)
		end
	end

	-- 2. 也检查是否有代码标记指向这个文件（虽然不是TODO文件，但可能有代码标记）
	local code_links = index.find_code_links_by_file(norm) or {}
	for _, task in ipairs(code_links) do
		if task and task.id and not id_set[task.id] then
			id_set[task.id] = true
			table.insert(ids_to_delete, task.id)
		end
	end

	-- 如果没有找到任务ID，仍然允许删除空文件
	if #ids_to_delete == 0 then
		vim.notify("文件中未找到任务ID，将直接删除空文件", vim.log.levels.INFO)
	else
		vim.notify(string.format("找到 %d 个任务需要删除", #ids_to_delete), vim.log.levels.INFO)
	end

	-- ⭐ 让 deleter 处理所有删除（三位一体）
	local success, results = deleter.delete_by_ids(ids_to_delete)

	-- 删除文件本身
	local ok = os.remove(norm)
	if not ok then
		vim.notify("删除文件失败: " .. norm, vim.log.levels.ERROR)
		return false
	end

	-- 清理缓存
	_file_cache.data = {}
	_file_cache.timestamps = {}

	-- 报告结果
	if success then
		vim.notify(
			string.format("✅ 成功删除 TODO 文件\n📝 已清理 %d 个任务", #ids_to_delete),
			vim.log.levels.INFO
		)
	else
		vim.notify(
			string.format("⚠️ 文件已删除，但部分任务清理失败，请运行 cleanup"),
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
