-- lua/todo2/store/autofix.lua
-- 专业级重构版：去除关键词依赖，只以 ID 标记为真，合并自动命令，保留缓存

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local index = require("todo2.store.index")
local config = require("todo2.config")
local parser = require("todo2.core.parser")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification")
local hash = require("todo2.utils.hash")
local cleanup = require("todo2.store.cleanup")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	DEBOUNCE_MS = 500,
	THROTTLE_MS = 5000,
	MAX_FILE_SIZE_KB = 1024,
}

---------------------------------------------------------------------
-- LRU 缓存
---------------------------------------------------------------------
local function create_lru_cache(max_size)
	local cache = {}
	local order = {}

	return {
		get = function(key)
			local item = cache[key]
			if not item then
				return nil
			end
			for i, k in ipairs(order) do
				if k == key then
					table.remove(order, i)
					break
				end
			end
			table.insert(order, 1, key)
			return item.value
		end,

		set = function(key, value)
			if cache[key] then
				for i, k in ipairs(order) do
					if k == key then
						table.remove(order, i)
						break
					end
				end
			elseif #order >= max_size then
				local oldest = order[#order]
				cache[oldest] = nil
				table.remove(order)
			end

			cache[key] = { value = value }
			table.insert(order, 1, key)
		end,

		delete = function(key)
			cache[key] = nil
			for i, k in ipairs(order) do
				if k == key then
					table.remove(order, i)
					break
				end
			end
		end,

		clear = function()
			cache = {}
			order = {}
		end,

		size = function()
			return #order
		end,
	}
end

local cache = {
	file_type = create_lru_cache(100),
	file_lines = create_lru_cache(50),
	existing_links = create_lru_cache(100),
}

---------------------------------------------------------------------
-- 文件过滤 / 读取
---------------------------------------------------------------------
local function check_file_size(filepath)
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return false
	end
	return (stat.size / 1024) <= CONFIG.MAX_FILE_SIZE_KB
end

local function is_todo_file_fast(filepath)
	local cached = cache.file_type:get(filepath)
	if cached ~= nil then
		return cached
	end

	local is_todo = filepath:match("%.todo%.md$") or filepath:match("%.todo$")
	cache.file_type:set(filepath, is_todo)
	return is_todo
end

local function read_file_head_fast(filepath, max_lines)
	max_lines = max_lines or 50

	local cached = cache.file_lines:get(filepath)
	local stat = vim.loop.fs_stat(filepath)
	local file_hash = stat and string.format("%d_%d", stat.size, stat.mtime.sec) or ""

	if cached and cached.hash == file_hash then
		return cached.lines
	end

	local ok, lines = pcall(vim.fn.readfile, filepath, "", max_lines)
	if ok and lines then
		cache.file_lines:set(filepath, {
			lines = lines,
			hash = file_hash,
		})
		return lines
	end

	return nil
end

local function read_file_all_fast(filepath)
	local cached = cache.file_lines:get(filepath)
	local stat = vim.loop.fs_stat(filepath)
	local file_hash = stat and string.format("%d_%d", stat.size, stat.mtime.sec) or ""

	if cached and cached.hash == file_hash then
		return cached.lines
	end

	local ok, lines = pcall(vim.fn.readfile, filepath)
	if ok and lines then
		cache.file_lines:set(filepath, {
			lines = lines,
			hash = file_hash,
		})
		return lines
	end

	return nil
end

---------------------------------------------------------------------
-- 是否需要处理文件（只看 ID 标记，不再依赖关键词）
---------------------------------------------------------------------
local function should_process(filepath)
	if not filepath or filepath == "" then
		return false
	end

	if not check_file_size(filepath) then
		return false
	end

	if is_todo_file_fast(filepath) then
		return true
	end

	local lines = read_file_head_fast(filepath, 50)
	if not lines then
		return false
	end

	for _, line in ipairs(lines) do
		if id_utils.contains_code_mark(line) or id_utils.contains_todo_anchor(line) then
			return true
		end
	end

	return false
end

M.should_process_file = should_process

---------------------------------------------------------------------
-- 获取现有链接（缓存）
---------------------------------------------------------------------
local function get_existing_links(filepath, link_type)
	local key = filepath .. ":" .. link_type
	local cached = cache.existing_links:get(key)
	if cached then
		return cached
	end

	local find_fn = link_type == "todo" and index.find_todo_links_by_file or index.find_code_links_by_file
	local ok, links = pcall(find_fn, filepath)

	local result = {}
	if ok and links then
		for _, obj in ipairs(links) do
			result[obj.id] = obj
		end
	end

	cache.existing_links:set(key, result)
	return result
end

---------------------------------------------------------------------
-- 统一更新逻辑
---------------------------------------------------------------------
local function update_link_safe(id, old, updates, report, link_type)
	local changed = false

	if updates.content and old.content ~= updates.content then
		old.content = updates.content
		old.content_hash = updates.content_hash or hash.hash(updates.content)
		changed = true
	end

	if updates.tag and old.tag ~= updates.tag then
		old.tag = updates.tag
		changed = true
	end

	if updates.line and old.line ~= updates.line then
		old.line = updates.line
		changed = true
	end

	if updates.path and old.path ~= updates.path then
		old.path = updates.path
		changed = true
	end

	if changed then
		report.updated = report.updated + 1
		if link_type == "todo" then
			pcall(link.update_todo, id, old)
		else
			pcall(link.update_code, id, old)
		end
	end

	return changed
end

---------------------------------------------------------------------
-- 清理悬挂链接（直接使用 deleted_ids）
---------------------------------------------------------------------
local function cleanup_deleted_ids(filepath, deleted_ids)
	if not deleted_ids or #deleted_ids == 0 then
		return
	end

	vim.defer_fn(function()
		local report = cleanup.check_dangling_by_ids(deleted_ids, {
			dry_run = false,
			verbose = config.get("autofix.show_progress") or false,
		})

		if report and report.cleaned > 0 and config.get("autofix.show_progress") then
			vim.notify(
				string.format(
					"自动清理 %d 个悬挂链接（文件: %s）",
					report.cleaned,
					vim.fn.fnamemodify(filepath, ":t")
				),
				vim.log.levels.INFO
			)
		end
	end, 200)
end

---------------------------------------------------------------------
-- TODO 文件同步（完全依赖 parser）
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
		return { success = false, error = "解析失败" }
	end

	local report = { created = 0, updated = 0, deleted = 0, ids = {} }
	local existing = get_existing_links(filepath, "todo")
	local deleted_ids = {}

	for id, task in pairs(id_to_task or {}) do
		report.ids[#report.ids + 1] = id

		if existing[id] then
			update_link_safe(id, existing[id], {
				content = task.content,
				tag = task.tag or "TODO",
				line = task.line_num,
				path = filepath,
				content_hash = hash.hash(task.content),
			}, report, "todo")

			existing[id] = nil
		else
			local ok_add = pcall(link.add_todo, id, {
				path = filepath,
				line = task.line_num,
				content = task.content,
				tag = task.tag or "TODO",
				status = task.status,
				created_at = os.time(),
				active = true,
			})
			if ok_add then
				report.created = report.created + 1
			end
		end
	end

	for id, _ in pairs(existing) do
		report.ids[#report.ids + 1] = id
		deleted_ids[#deleted_ids + 1] = id

		if pcall(link.delete_todo, id) then
			report.deleted = report.deleted + 1
		end
	end

	cache.existing_links:delete(filepath .. ":todo")
	cache.file_lines:delete(filepath)

	pcall(verification.refresh_metadata_stats)

	report.success = (report.created + report.updated + report.deleted) > 0

	if report.success then
		cleanup_deleted_ids(filepath, deleted_ids)
	end

	return report
end

---------------------------------------------------------------------
-- 代码文件同步（只依赖 ID 标记，不再依赖关键词）
---------------------------------------------------------------------
local function extract_tag_and_id(line)
	if not line or line == "" then
		return nil, nil
	end

	if id_utils.contains_code_mark(line) then
		local id = id_utils.extract_id_from_code_mark(line)
		if id then
			local tag = id_utils.extract_tag_from_code_mark(line)
			return tag or "TODO", id
		end
	end

	if id_utils.contains_todo_anchor(line) then
		local id = id_utils.extract_id_from_todo_anchor(line)
		if id then
			return "TODO", id
		end
	end

	return nil, nil
end

local function build_clean_content(line)
	if not line or line == "" then
		return "任务标记"
	end

	local cleaned = line
	cleaned = cleaned:gsub(id_utils.TODO_ANCHOR_PATTERN_NO_CAPTURE, "")
	cleaned = cleaned:gsub(id_utils.CODE_MARK_PATTERN_NO_CAPTURE, "")
	cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")

	if cleaned == "" then
		return "任务标记"
	end

	return cleaned
end

function M.sync_code_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, error = "空文件路径" }
	end

	if not should_process(filepath) then
		return { success = false, skipped = true, reason = "无需处理" }
	end

	local lines = read_file_all_fast(filepath)
	if not lines then
		return { success = false, error = "无法读取文件" }
	end

	local report = { created = 0, updated = 0, deleted = 0, ids = {} }
	local current = {}

	for ln, line in ipairs(lines) do
		local tag, id = extract_tag_and_id(line)
		if id then
			local cleaned = build_clean_content(line)
			current[id] = {
				id = id,
				path = filepath,
				line = ln,
				content = cleaned,
				tag = tag or "CODE",
				content_hash = hash.hash(cleaned),
				active = true,
			}
		end
	end

	if vim.tbl_isempty(current) then
		return { success = false, skipped = true, reason = "无标记" }
	end

	local existing = get_existing_links(filepath, "code")
	local deleted_ids = {}

	for id, data in pairs(current) do
		report.ids[#report.ids + 1] = id

		if existing[id] then
			update_link_safe(id, existing[id], data, report, "code")
			existing[id] = nil
		else
			if pcall(link.add_code, id, data) then
				report.created = report.created + 1
			end
		end
	end

	for id, _ in pairs(existing) do
		report.ids[#report.ids + 1] = id

		local todo_link = link.get_todo(id, { verify_line = false })
		if not (todo_link and types.is_archived_status(todo_link.status)) then
			if pcall(link.delete_code, id) then
				report.deleted = report.deleted + 1
				deleted_ids[#deleted_ids + 1] = id
			end
		end
	end

	cache.existing_links:delete(filepath .. ":code")
	cache.file_lines:delete(filepath)

	pcall(verification.refresh_metadata_stats)

	report.success = (report.created + report.updated + report.deleted) > 0

	if report.success then
		cleanup_deleted_ids(filepath, deleted_ids)
	end

	return report
end

---------------------------------------------------------------------
-- 位置修复
---------------------------------------------------------------------
function M.locate_file_links(filepath, callback)
	if not filepath or filepath == "" then
		local result = { located = 0, total = 0, error = "空文件路径" }
		if callback then
			callback(result)
		end
		return result
	end

	if not should_process(filepath) then
		local result = { located = 0, total = 0, skipped = true, reason = "无需处理" }
		if callback then
			callback(result)
		end
		return result
	end

	local function do_locate()
		local ok, result = pcall(locator.locate_file_tasks, filepath)
		if not ok then
			return { located = 0, total = 0, error = tostring(result) }
		end
		return result
	end

	if callback then
		vim.schedule(function()
			callback(do_locate())
		end)
		return { located = 0, total = 0, processing = true }
	else
		return do_locate()
	end
end

---------------------------------------------------------------------
-- 自动命令（合并为一个组，两个行为共存）
---------------------------------------------------------------------
function M.setup_autofix()
	pcall(vim.api.nvim_del_augroup_by_name, "Todo2AutoFix")

	local group = vim.api.nvim_create_augroup("Todo2AutoFix", { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "*" },
		callback = function(args)
			local file = args.file
			if not file or file == "" then
				return
			end

			if not should_process(file) then
				return
			end

			-- 同步链接（TODO / CODE）
			if config.get("autofix.on_save") then
				local is_todo = is_todo_file_fast(file)
				local fn = is_todo and M.sync_todo_links or M.sync_code_links

				vim.defer_fn(function()
					local report = fn(file)
					if config.get("autofix.show_progress") and report and report.success then
						vim.notify(
							string.format(
								"%s同步: +%d ~%d -%d",
								is_todo and "TODO" or "代码",
								report.created or 0,
								report.updated or 0,
								report.deleted or 0
							),
							vim.log.levels.INFO
						)
					end
				end, CONFIG.DEBOUNCE_MS)
			end

			-- 定位行号
			if config.get("autofix.enabled") then
				M._last_locate_time = M._last_locate_time or 0
				local now = vim.loop.now()

				if now - M._last_locate_time >= CONFIG.THROTTLE_MS then
					M._last_locate_time = now
					local result = M.locate_file_links(file)
					if result and result.located and result.located > 0 and config.get("autofix.show_progress") then
						vim.notify(
							string.format("修复 %d/%d 个行号", result.located, result.total or 0),
							vim.log.levels.INFO
						)
					end
				end
			end
		end,
	})
end

---------------------------------------------------------------------
-- 缓存管理
---------------------------------------------------------------------
function M.clear_cache()
	cache.file_type.clear()
	cache.file_lines.clear()
	cache.existing_links.clear()
	return true
end

function M.get_cache_stats()
	return {
		file_type = cache.file_type.size(),
		file_lines = cache.file_lines.size(),
		existing_links = cache.existing_links.size(),
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
