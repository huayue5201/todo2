-- lua/todo2/store/autofix.lua
-- 重写版：统一走 scheduler + link 中心，不再直接操作底层存储

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local index = require("todo2.store.index")
local config = require("todo2.config")
local types = require("todo2.store.types")
local verification = require("todo2.store.verification")
local hash = require("todo2.utils.hash")
local cleanup = require("todo2.store.cleanup")
local id_utils = require("todo2.utils.id")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	DEBOUNCE_MS = 500,
	THROTTLE_MS = 5000,
	MAX_FILE_SIZE_KB = 1024,
}

---------------------------------------------------------------------
-- LRU 缓存（仅用于文件类型 / 现有链接）
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
	}
end

local cache = {
	file_type = create_lru_cache(100),
	existing_links = create_lru_cache(100),
}

---------------------------------------------------------------------
-- 文件过滤 / 读取（统一走 scheduler）
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

local function read_file_all(filepath)
	-- scheduler 已经有文件行缓存，这里直接复用
	return scheduler.get_file_lines(filepath, false)
end

local function read_file_head(filepath, max_lines)
	local lines = scheduler.get_file_lines(filepath, false)
	if not lines or #lines == 0 then
		return nil
	end
	max_lines = max_lines or #lines
	if #lines <= max_lines then
		return lines
	end
	local head = {}
	for i = 1, max_lines do
		head[i] = lines[i]
	end
	return head
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

	local lines = read_file_head(filepath, 50)
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
-- 统一更新逻辑：构造 updated，再交给 link 中心
---------------------------------------------------------------------
local function apply_updates_via_link(id, old, updates, link_type, report)
	local updated = vim.deepcopy(old)

	if updates.content and updated.content ~= updates.content then
		updated.content = updates.content
		updated.content_hash = updates.content_hash or hash.hash(updates.content)
	end

	if updates.tag and updated.tag ~= updates.tag then
		updated.tag = updates.tag
	end

	if updates.line and updated.line ~= updates.line then
		updated.line = updates.line
	end

	if updates.path and updated.path ~= updates.path then
		updated.path = updates.path
	end

	local changed = false
	for k, v in pairs(updates) do
		if updated[k] ~= old[k] then
			changed = true
			break
		end
	end

	if not changed then
		return false
	end

	local ok
	if link_type == "todo" then
		ok = link.update_todo(id, updated)
	else
		ok = link.update_code(id, updated)
	end

	if ok and report then
		report.updated = (report.updated or 0) + 1
	end

	return ok
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
-- TODO 文件同步（完全依赖 scheduler.parse_tree + link 中心）
---------------------------------------------------------------------
function M.sync_todo_links(filepath)
	filepath = filepath or vim.fn.expand("%:p")
	if filepath == "" then
		return { success = false, error = "空文件路径" }
	end

	if not is_todo_file_fast(filepath) then
		return { success = false, skipped = true, reason = "非TODO文件" }
	end

	-- 统一通过 scheduler 获取解析树
	local ok, tasks, _, id_to_task = pcall(scheduler.get_parse_tree, filepath, true)
	if not ok then
		return { success = false, error = "解析失败" }
	end

	local report = { created = 0, updated = 0, deleted = 0, ids = {} }
	local existing = get_existing_links(filepath, "todo")
	local deleted_ids = {}

	for id, task in pairs(id_to_task or {}) do
		report.ids[#report.ids + 1] = id

		if existing[id] then
			local old = existing[id]
			local updates = {
				content = task.content,
				tag = task.tag or "TODO",
				line = task.line_num,
				path = filepath,
				content_hash = hash.hash(task.content),
			}
			apply_updates_via_link(id, old, updates, "todo", report)
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

	pcall(verification.refresh_metadata_stats)

	report.success = (report.created + report.updated + report.deleted) > 0

	if report.success then
		cleanup_deleted_ids(filepath, deleted_ids)
	end

	return report
end

---------------------------------------------------------------------
-- 代码文件同步（只依赖 ID 标记 + link 中心）
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

	local lines = read_file_all(filepath)
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
			local old = existing[id]
			apply_updates_via_link(id, old, data, "code", report)
			existing[id] = nil
		else
			if pcall(link.add_code, id, data) then
				report.created = report.created + 1
			end
		end
	end

	for id, _ in pairs(existing) do
		report.ids[#report.ids + 1] = id

		local todo_link = link.get_todo(id )
		if not (todo_link and types.is_archived_status(todo_link.status)) then
			if pcall(link.delete_code, id) then
				report.deleted = report.deleted + 1
				deleted_ids[#deleted_ids + 1] = id
			end
		end
	end

	cache.existing_links:delete(filepath .. ":code")

	pcall(verification.refresh_metadata_stats)

	report.success = (report.created + report.updated + report.deleted) > 0

	if report.success then
		cleanup_deleted_ids(filepath, deleted_ids)
	end

	return report
end

---------------------------------------------------------------------
-- 自动修复入口（保留原有接口形态）
---------------------------------------------------------------------
local debounce_timer = nil
local last_run_ts = 0

local function schedule_autofix(filepath)
	if debounce_timer then
		debounce_timer:stop()
		debounce_timer:close()
		debounce_timer = nil
	end

	debounce_timer = vim.loop.new_timer()
	debounce_timer:start(CONFIG.DEBOUNCE_MS, 0, function()
		debounce_timer:stop()
		debounce_timer:close()
		debounce_timer = nil

		local now = vim.loop.now()
		if now - last_run_ts < CONFIG.THROTTLE_MS then
			return
		end
		last_run_ts = now

		vim.schedule(function()
			if not filepath or filepath == "" then
				filepath = vim.fn.expand("%:p")
			end
			if filepath == "" then
				return
			end

			if is_todo_file_fast(filepath) then
				M.sync_todo_links(filepath)
			else
				M.sync_code_links(filepath)
			end
		end)
	end)
end

function M.setup_autofix()
	-- 这里只保留调度入口，具体 autocmd 在 autocmds.lua 里调用 sync_* 或 schedule_autofix
	return true
end

function M.set_config(opts)
	opts = opts or {}
	if opts.DEBOUNCE_MS then
		CONFIG.DEBOUNCE_MS = opts.DEBOUNCE_MS
	end
	if opts.THROTTLE_MS then
		CONFIG.THROTTLE_MS = opts.THROTTLE_MS
	end
	if opts.MAX_FILE_SIZE_KB then
		CONFIG.MAX_FILE_SIZE_KB = opts.MAX_FILE_SIZE_KB
	end
end

M.schedule_autofix = schedule_autofix

return M
