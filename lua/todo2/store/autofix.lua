-- lua/todo2/store/autofix.lua (增量优化版)
-- 自动修复模块 - 只修复物理位置，不覆盖状态（兼容统一软删除规则）
local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local index = require("todo2.store.index")
local config = require("todo2.config")
local parser = require("todo2.core.parser")
local format = require("todo2.utils.format")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	DEBOUNCE_MS = 500,
	THROTTLE_MS = 5000,
	MAX_FILE_SIZE_KB = 1024,
}

---------------------------------------------------------------------
-- ⭐ 优化：缓存系统
---------------------------------------------------------------------
local cache = {
	file_type = {}, -- { [path] = { is_todo = boolean, timestamp } }
	file_lines = {}, -- { [path] = { lines = table, timestamp, hash } }
	existing_links = {}, -- { [path] = { links = table, timestamp } }
}

local CACHE_TTL = {
	FILE_TYPE = 30000, -- 30秒
	FILE_LINES = 5000, -- 5秒
	EXISTING_LINKS = 10000, -- 10秒
}

-- 清理过期缓存
local function cleanup_cache()
	local now = vim.loop.now()

	for path, info in pairs(cache.file_type) do
		if now - info.timestamp > CACHE_TTL.FILE_TYPE then
			cache.file_type[path] = nil
		end
	end

	for path, info in pairs(cache.file_lines) do
		if now - info.timestamp > CACHE_TTL.FILE_LINES then
			cache.file_lines[path] = nil
		end
	end

	for path, info in pairs(cache.existing_links) do
		if now - info.timestamp > CACHE_TTL.EXISTING_LINKS then
			cache.existing_links[path] = nil
		end
	end
end

-- 定时清理（1分钟一次）
vim.loop.new_timer():start(60000, 60000, vim.schedule_wrap(cleanup_cache))

---------------------------------------------------------------------
-- 防抖/节流控制（保持不变）
---------------------------------------------------------------------
local debounce_timers = {}
local last_run_time = {}
local pending_files = {}

local function cleanup_tracking()
	local now = vim.loop.now()
	for path, time in pairs(last_run_time) do
		if now - time > 60000 then
			last_run_time[path] = nil
		end
	end

	for path, timer in pairs(debounce_timers) do
		if not timer:is_active() then
			debounce_timers[path] = nil
		end
	end
end

vim.loop.new_timer():start(30000, 30000, vim.schedule_wrap(cleanup_tracking))

---------------------------------------------------------------------
-- ⭐ 优化：文件过滤（使用缓存）
---------------------------------------------------------------------

--- 检查文件大小是否在限制内
local function check_file_size(filepath)
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return false
	end
	local size_kb = stat.size / 1024
	return size_kb <= CONFIG.MAX_FILE_SIZE_KB
end

--- ⭐ 优化：快速判断文件类型（带缓存）
local function is_todo_file_fast(filepath)
	local cached = cache.file_type[filepath]
	local now = vim.loop.now()

	if cached and (now - cached.timestamp) < CACHE_TTL.FILE_TYPE then
		return cached.is_todo
	end

	local is_todo = filepath:match("%.todo%.md$") or filepath:match("%.todo$")
	cache.file_type[filepath] = {
		is_todo = is_todo,
		timestamp = now,
	}

	return is_todo
end

--- ⭐ 优化：读取文件前几行（带缓存）
local function read_file_head_fast(filepath, max_lines)
	max_lines = max_lines or 50

	local cached = cache.file_lines[filepath]
	local now = vim.loop.now()

	if cached and (now - cached.timestamp) < CACHE_TTL.FILE_LINES then
		return cached.lines
	end

	local stat = vim.loop.fs_stat(filepath)
	local file_hash = stat and string.format("%d_%d", stat.size, stat.mtime.sec) or ""

	-- 如果缓存存在但文件已变化，重新读取
	if cached and cached.hash ~= file_hash then
		cache.file_lines[filepath] = nil
	end

	local ok, lines = pcall(vim.fn.readfile, filepath, "", max_lines)
	if ok and lines then
		cache.file_lines[filepath] = {
			lines = lines,
			timestamp = now,
			hash = file_hash,
		}
		return lines
	end

	return nil
end

--- 检查文件是否应该被处理（优化版）
function M.should_process_file(filepath)
	if not filepath or filepath == "" then
		return false
	end

	-- 检查文件大小
	if not check_file_size(filepath) then
		return false
	end

	-- 快速判断 TODO 文件
	if is_todo_file_fast(filepath) then
		return true
	end

	-- 读取前50行（使用缓存）
	local lines = read_file_head_fast(filepath, 50)
	if not lines then
		return false
	end

	-- 获取关键词配置（只获取一次）
	local keywords = config.get_code_keywords() or { "@todo" }

	-- 查找是否有任何标记
	for _, line in ipairs(lines) do
		-- 快速检查 {#id} 或 :ref:id 格式
		if line:find("{%#%x+%}") or line:find(":ref:%x+") then
			-- 检查关键词
			for _, kw in ipairs(keywords) do
				if line:find(kw, 1, true) then -- 使用 plain find 更快
					return true
				end
			end
		end
	end

	return false
end

function M.get_watch_patterns()
	return { "*" }
end

---------------------------------------------------------------------
-- 防抖/节流处理函数（保持不变）
---------------------------------------------------------------------
local function debounced_process(filepath, processor_fn, callback)
	if debounce_timers[filepath] then
		debounce_timers[filepath]:stop()
		debounce_timers[filepath]:close()
		debounce_timers[filepath] = nil
	end

	pending_files[filepath] = pending_files[filepath] or {}
	table.insert(pending_files[filepath], callback)

	debounce_timers[filepath] = vim.defer_fn(function()
		local callbacks = pending_files[filepath] or {}
		pending_files[filepath] = nil

		local success, result = pcall(processor_fn, filepath)
		if not success then
			vim.notify(string.format("自动修复处理失败: %s", tostring(result)), vim.log.levels.ERROR)
			result = { success = false, error = tostring(result) }
		end

		for _, cb in ipairs(callbacks) do
			if type(cb) == "function" then
				pcall(cb, result)
			end
		end

		debounce_timers[filepath] = nil
	end, CONFIG.DEBOUNCE_MS)
end

local function throttled_process(filepath, processor_fn, callback)
	local now = vim.loop.now()
	local last = last_run_time[filepath] or 0

	if now - last >= CONFIG.THROTTLE_MS then
		last_run_time[filepath] = now
		local success, result = pcall(processor_fn, filepath)
		if not success then
			vim.notify(string.format("节流处理失败: %s", tostring(result)), vim.log.levels.ERROR)
			result = { success = false, error = tostring(result) }
		end
		if type(callback) == "function" then
			callback(result)
		end
	else
		debounced_process(filepath, processor_fn, callback)
	end
end

---------------------------------------------------------------------
-- ⭐ 优化：键名缓存
---------------------------------------------------------------------
local KEY_PATTERNS = {
	todo = "todo.links.todo.%s",
	code = "todo.links.code.%s",
}

local INDEX_NS = {
	todo = "todo.index.file_to_todo",
	code = "todo.index.file_to_code",
}

local function get_link_key(link_type, id)
	return KEY_PATTERNS[link_type]:format(id)
end

---------------------------------------------------------------------
-- 核心修复：智能更新链接（保持不变）
---------------------------------------------------------------------
local function update_link_with_changes(old, updates, report, link_type)
	local content_changed = false
	local position_changed = false
	local changes = {}

	if not old or type(old) ~= "table" then
		return false, {}, "无效对象"
	end

	if updates.content and old.content ~= updates.content then
		old.content = updates.content
		old.content_hash = updates.content_hash or locator.calculate_content_hash(updates.content)
		content_changed = true
		table.insert(changes, "content")
	end

	if updates.tag and old.tag ~= updates.tag then
		old.tag = updates.tag
		content_changed = true
		table.insert(changes, "tag")
	end

	if updates.line and old.line ~= updates.line then
		old.line = updates.line
		position_changed = true
		table.insert(changes, "line")
	end

	if updates.path and old.path ~= updates.path then
		if old.path and updates.path then
			local index_ns = INDEX_NS[link_type]
			pcall(index._remove_id_from_file_index, index_ns, old.path, old.id)
			pcall(index._add_id_to_file_index, index_ns, updates.path, old.id)
		end
		old.path = updates.path
		position_changed = true
		table.insert(changes, "path")
	end

	if content_changed then
		old.updated_at = os.time()
		report.updated = report.updated + 1
	elseif position_changed then
		report.updated = report.updated + 1
	end

	return (content_changed or position_changed), changes, (content_changed and "内容" or "位置")
end

---------------------------------------------------------------------
-- ⭐ 优化：获取现有链接（带缓存）
---------------------------------------------------------------------
local function get_existing_links_fast(filepath, link_type)
	local cached = cache.existing_links[filepath .. ":" .. link_type]
	local now = vim.loop.now()

	if cached and (now - cached.timestamp) < CACHE_TTL.EXISTING_LINKS then
		return cached.links
	end

	local find_fn = link_type == "todo" and index.find_todo_links_by_file or index.find_code_links_by_file
	local ok, links = pcall(find_fn, filepath)

	local result = {}
	if ok and links then
		for _, obj in ipairs(links) do
			result[obj.id] = obj
		end
	end

	cache.existing_links[filepath .. ":" .. link_type] = {
		links = result,
		timestamp = now,
	}

	return result
end

---------------------------------------------------------------------
-- 核心：TODO文件全量同步（优化版）
---------------------------------------------------------------------
function M.sync_todo_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, error = "空文件路径" }
	end

	if not is_todo_file_fast(filepath) then
		return { success = false, skipped = true, reason = "非TODO文件" }
	end

	local ok, tasks, _, id_to_task = pcall(parser.parse_file, filepath, true)
	if not ok then
		vim.notify(string.format("解析TODO文件失败: %s", tostring(tasks)), vim.log.levels.ERROR)
		return { success = false, error = "解析文件失败: " .. tostring(tasks) }
	end

	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {},
	}

	-- 使用缓存的现有链接
	local existing = get_existing_links_fast(filepath, "todo")

	for id, task in pairs(id_to_task or {}) do
		table.insert(report.ids, id)

		if existing[id] then
			local old = existing[id]

			local changed, changes, change_type = update_link_with_changes(old, {
				content = task.content,
				tag = task.tag or "TODO",
				line = task.line_num,
				path = filepath,
				content_hash = locator.calculate_content_hash(task.content),
			}, report, "todo")

			if changed then
				pcall(store.set_key, get_link_key("todo", id), old)
			end
			existing[id] = nil
		else
			local add_ok = pcall(link.add_todo, id, {
				path = filepath,
				line = task.line_num,
				content = task.content,
				tag = task.tag or "TODO",
				status = task.status,
				created_at = os.time(),
				active = true,
			})
			if add_ok then
				report.created = report.created + 1
			end
		end
	end

	for id, _ in pairs(existing) do
		table.insert(report.ids, id)
		pcall(verification.mark_link_deleted, id, "todo")
		report.deleted = report.deleted + 1
	end

	-- 清除相关缓存
	cache.existing_links[filepath .. ":todo"] = nil
	cache.file_lines[filepath] = nil

	pcall(verification.refresh_metadata_stats)

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 核心：代码文件全量同步（优化版）
---------------------------------------------------------------------
function M.sync_code_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, error = "空文件路径" }
	end

	if not M.should_process_file(filepath) then
		return { success = false, skipped = true, reason = "文件无需处理" }
	end

	-- 尝试从缓存读取文件
	local lines = read_file_head_fast(filepath, nil) -- 读取全部
	if not lines then
		return { success = false, error = "无法读取文件" }
	end

	local keywords = config.get_code_keywords() or { "@todo" }
	local report = {
		created = 0,
		updated = 0,
		deleted = 0,
		ids = {},
	}
	local current = {}

	-- 解析代码文件中的标记
	for ln, line in ipairs(lines) do
		local tag, id = format.extract_from_code_line(line)
		if id then
			for _, kw in ipairs(keywords) do
				if line:find(kw, 1, true) then
					if not tag then
						tag = config.get_tag_name_by_keyword(kw) or "TODO"
					end

					local cleaned_content = line:gsub("%{%#" .. id .. "%}", "")
						:gsub(":ref:" .. id, "")
						:gsub(kw, "")
						:gsub("%s+$", "")
						:gsub("^%s+", "")

					if cleaned_content == "" then
						cleaned_content = "任务标记"
					end

					current[id] = {
						id = id,
						path = filepath,
						line = ln,
						content = cleaned_content,
						tag = tag or "CODE",
						content_hash = locator.calculate_content_hash(cleaned_content),
						active = true,
					}
					break
				end
			end
		end
	end

	if vim.tbl_isempty(current) then
		return { success = false, skipped = true, reason = "无待处理标记" }
	end

	-- 使用缓存的现有链接
	local existing = get_existing_links_fast(filepath, "code")

	for id, data in pairs(current) do
		table.insert(report.ids, id)

		if existing[id] then
			local old = existing[id]

			local changed, changes, change_type = update_link_with_changes(old, {
				content = data.content,
				tag = data.tag,
				line = data.line,
				path = data.path,
				content_hash = data.content_hash,
			}, report, "code")

			if changed then
				pcall(store.set_key, get_link_key("code", id), old)
			end
			existing[id] = nil
		else
			local add_ok = pcall(link.add_code, id, data)
			if add_ok then
				report.created = report.created + 1
			end
		end
	end

	for id, _ in pairs(existing) do
		table.insert(report.ids, id)

		local todo_link_ok, todo_link = pcall(link.get_todo, id, { verify_line = false })
		local is_archived = false
		if todo_link_ok and todo_link then
			is_archived = types.is_archived_status(todo_link.status)
		end

		if not is_archived then
			pcall(verification.mark_link_deleted, id, "code")
			report.deleted = report.deleted + 1
		end
	end

	-- 清除相关缓存
	cache.existing_links[filepath .. ":code"] = nil
	cache.file_lines[filepath] = nil

	pcall(verification.refresh_metadata_stats)

	report.success = report.created + report.updated + report.deleted > 0
	return report
end

---------------------------------------------------------------------
-- 位置修复（保持不变）
---------------------------------------------------------------------
function M.locate_file_links(filepath, callback)
	if not filepath or filepath == "" then
		local result = { located = 0, total = 0, error = "空文件路径" }
		if type(callback) == "function" then
			callback(result)
		end
		return result
	end

	if not M.should_process_file(filepath) then
		local result = { located = 0, total = 0, skipped = true, reason = "文件无需处理" }
		if type(callback) == "function" then
			callback(result)
		end
		return result
	end

	local function do_locate()
		local success, result = pcall(function()
			if type(locator.locate_file_tasks) == "function" then
				return locator.locate_file_tasks(filepath)
			else
				return { located = 0, total = 0, error = "locator.locate_file_tasks 未定义" }
			end
		end)

		if not success then
			return { located = 0, total = 0, error = tostring(result) }
		end
		return result
	end

	if type(callback) == "function" then
		vim.schedule(function()
			local result = do_locate()
			callback(result)
		end)
		return { located = 0, total = 0, processing = true }
	else
		return do_locate()
	end
end

---------------------------------------------------------------------
-- 自动命令设置（保持不变）
---------------------------------------------------------------------
function M.setup_autofix()
	pcall(vim.api.nvim_del_augroup_by_name, "Todo2AutoFix")

	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	if config.get("autofix.on_save") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = M.get_watch_patterns(),
			callback = function(args)
				if not args.file or args.file == "" then
					return
				end

				if not M.should_process_file(args.file) then
					return
				end

				local is_todo = is_todo_file_fast(args.file)
				local fn = is_todo and M.sync_todo_links or M.sync_code_links

				debounced_process(args.file, fn, function(report)
					if config.get("autofix.show_progress") and report and report.success then
						local msg = string.format(
							"%s同步: +%d ~%d -%d",
							is_todo and "TODO" or "代码",
							report.created or 0,
							report.updated or 0,
							report.deleted or 0
						)
						vim.notify(msg, vim.log.levels.INFO)
					end
				end)
			end,
		})
	end

	if config.get("autofix.enabled") then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = group,
			pattern = M.get_watch_patterns(),
			callback = function(args)
				if not args.file or args.file == "" then
					return
				end

				if not M.should_process_file(args.file) then
					return
				end

				throttled_process(args.file, function(file)
					return M.locate_file_links(file)
				end, function(result)
					if result and result.located and result.located > 0 then
						if config.get("autofix.show_progress") then
							vim.notify(
								string.format("修复 %d/%d 个行号", result.located, result.total or 0),
								vim.log.levels.INFO
							)
						end
					end
				end)
			end,
		})
	end
end

---------------------------------------------------------------------
-- ⭐ 新增：缓存管理
---------------------------------------------------------------------
function M.clear_cache()
	cache.file_type = {}
	cache.file_lines = {}
	cache.existing_links = {}
	return true
end

function M.get_cache_stats()
	return {
		file_type = vim.tbl_count(cache.file_type),
		file_lines = vim.tbl_count(cache.file_lines),
		existing_links = vim.tbl_count(cache.existing_links),
	}
end

M.set_config = function(new_config)
	if type(new_config) ~= "table" then
		vim.notify("配置必须是table类型", vim.log.levels.WARN)
		return
	end
	for k, v in pairs(new_config) do
		if CONFIG[k] ~= nil then
			CONFIG[k] = v
		end
	end
end

M.get_config = function()
	return vim.deepcopy(CONFIG)
end

return M
