-- lua/todo2/store/locator.lua
-- 无软删除版：ID 定位 + 内容定位 + 上下文定位 + 文件移动检测 + 索引自动更新

local M = {}

local context = require("todo2.store.context")
local hash = require("todo2.utils.hash")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	MAX_SCAN_LINES = 2000,
	SIMILARITY_THRESHOLD = 60,
	SCAN_WINDOW = 20,
	CONTEXT_SIMILARITY_THRESHOLD = 70,
	CONTEXT_SEARCH_RADIUS = 50,
	CHUNK_SIZE = 50,

	SEARCH = {
		USE_CACHE = true,
		ASYNC = true,
		EXCLUDE_DIRS = { "node_modules", ".git", "dist", "build", "target" },
	},
}

local search_cache = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------
local function read_file_lines(filepath)
	if vim.fn.filereadable(filepath) == 1 then
		return vim.fn.readfile(filepath)
	end
	return {}
end

local function find_id_in_line(line, id)
	if not line then
		return false
	end
	return (id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id)
		or (id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id)
end

---------------------------------------------------------------------
-- 上下文定位（同步）
---------------------------------------------------------------------
function M.locate_by_context_fingerprint(filepath, stored_context, threshold)
	threshold = threshold or CONFIG.CONTEXT_SIMILARITY_THRESHOLD

	if vim.fn.filereadable(filepath) ~= 1 then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best = { line = nil, similarity = 0, context = nil }

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	for i = 1, #lines do
		local ctx = context.build_from_buffer(temp_buf, i, filepath)
		if ctx then
			local sim = context.similarity(stored_context, ctx)
			if sim > best.similarity then
				best.line = i
				best.similarity = sim
				best.context = ctx
			end
			if sim >= threshold then
				break
			end
		end
	end

	vim.api.nvim_buf_delete(temp_buf, { force = true })

	if best.similarity >= threshold then
		return best
	end

	return nil
end

---------------------------------------------------------------------
-- 异步上下文定位
---------------------------------------------------------------------
function M.locate_by_context(filepath, link, callback)
	if not link.context or not callback then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return callback(nil)
	end

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	local best = { line = nil, similarity = 0 }
	local total = #lines
	local current = 1

	local function scan_chunk()
		local end_line = math.min(current + CONFIG.CHUNK_SIZE - 1, total)

		for i = current, end_line do
			local ctx = context.build_from_buffer(temp_buf, i, filepath)
			if ctx then
				local sim = context.similarity(link.context, ctx)
				if sim > best.similarity then
					best.line = i
					best.similarity = sim
				end
				if sim >= CONFIG.CONTEXT_SIMILARITY_THRESHOLD then
					current = total + 1
					break
				end
			end
		end

		current = current + CONFIG.CHUNK_SIZE
		if current <= total then
			vim.defer_fn(scan_chunk, 1)
		else
			vim.api.nvim_buf_delete(temp_buf, { force = true })
			callback(best.similarity >= 50 and best or nil)
		end
	end

	scan_chunk()
end

---------------------------------------------------------------------
-- rg 搜索
---------------------------------------------------------------------
local function has_rg()
	return vim.fn.executable("rg") == 1
end

function M.async_search_file_by_id(id, callback)
	if CONFIG.SEARCH.USE_CACHE and search_cache[id] then
		local cached = search_cache[id]
		if vim.fn.filereadable(cached) == 1 then
			return vim.schedule(function()
				callback(cached)
			end)
		end
	end

	local project_root = require("todo2.store.meta").get_project_root()

	if not has_rg() then
		local result = M._search_file_by_id_find(id)
		return vim.schedule(function()
			callback(result)
		end)
	end

	local args = {
		"-l",
		"-m",
		"1",
		"-i",
		"--no-ignore",
		"-u",
	}

	for _, dir in ipairs(CONFIG.SEARCH.EXCLUDE_DIRS) do
		table.insert(args, "-g")
		table.insert(args, "!" .. dir .. "/*")
	end

	table.insert(args, "-e")
	table.insert(args, id_utils.escape_for_rg(id_utils.format_todo_anchor(id)))
	table.insert(args, "-e")
	table.insert(args, id_utils.escape_for_rg(id_utils.REF_SEPARATOR .. id))
	table.insert(args, project_root)

	local stdout = vim.loop.new_pipe(false)
	local stderr = vim.loop.new_pipe(false)
	local output = {}

	local handle
	handle = vim.loop.spawn("rg", {
		args = args,
		stdio = { nil, stdout, stderr },
	}, function()
		stdout:close()
		stderr:close()
		if handle then
			handle:close()
		end

		local result = table.concat(output):match("[^\n]+")
		if result and CONFIG.SEARCH.USE_CACHE then
			search_cache[id] = result
		end

		vim.schedule(function()
			callback(result)
		end)
	end)

	stdout:read_start(function(_, data)
		if data then
			table.insert(output, data)
		end
	end)

	stderr:read_start(function(_, data)
		if data then
			vim.schedule(function()
				vim.notify("rg 搜索错误: " .. data, vim.log.levels.DEBUG)
			end)
		end
	end)
end

---------------------------------------------------------------------
-- ID 定位
---------------------------------------------------------------------
local function locate_by_id(filepath, id)
	local lines = read_file_lines(filepath)
	for i = 1, #lines do
		if find_id_in_line(lines[i], id) then
			return i
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 内容定位
---------------------------------------------------------------------
local function locate_by_content(filepath, link)
	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_score = 0
	local best_line = nil
	local max_line = math.min(#lines, CONFIG.MAX_SCAN_LINES)

	for i = 1, max_line do
		local line = lines[i]
		local score = 0

		if link.tag and line:match("%[" .. link.tag .. "%]") then
			score = score + 40
		end
		if link.content_hash and hash.hash(line) == link.content_hash then
			score = score + 50
		end
		if link.content and line:match(link.content:sub(1, 20)) then
			score = score + 30
		end
		if link.line then
			local d = math.abs(i - link.line)
			if d < CONFIG.SCAN_WINDOW then
				score = score + math.max(0, 20 - d)
			end
		end

		if score > best_score then
			best_score = score
			best_line = i
		end
	end

	return (best_score >= CONFIG.SIMILARITY_THRESHOLD) and best_line or nil
end

---------------------------------------------------------------------
-- 主定位函数（无软删除版）
---------------------------------------------------------------------
function M.locate_task(link, callback)
	if not link then
		local err = {
			line_verified = false,
			verification_failed_at = os.time(),
			verification_note = "链接为空",
		}
		if callback then
			callback(err)
		end
		return err
	end

	-- 归档任务不参与定位（正确）
	if link.status == "archived" then
		link.line_verified = true
		link.last_verified_at = os.time()
		link.verification_failed_at = nil
		link.verification_note = nil
		if callback then
			callback(link)
		end
		return link
	end

	-- 刚创建的链接（避免 race）
	if link.created_at and os.time() - link.created_at < 1 then
		link.line_verified = true
		link.last_verified_at = os.time()
		if callback then
			callback(link)
		end
		return link
	end

	local function finish(located)
		if not located then
			located = vim.deepcopy(link)
			located.line_verified = false
			located.verification_failed_at = os.time()
			located.verification_note = "定位失败"
		end

		if callback then
			vim.schedule(function()
				callback(located)
			end)
		end
		return located
	end

	if not link.path or vim.fn.filereadable(link.path) ~= 1 then
		M.async_search_file_by_id(link.id, function(found)
			if found then
				link.path = found
				finish(M._locate_in_file(link))
			else
				link.line_verified = false
				link.verification_note = "文件不存在且未找到"
				finish(link)
			end
		end)
		return link
	end

	return finish(M._locate_in_file(link))
end

---------------------------------------------------------------------
-- 同步定位
---------------------------------------------------------------------
function M._locate_in_file(link)
	local result = vim.deepcopy(link)

	local filepath = result.path
	if not filepath or vim.fn.filereadable(filepath) ~= 1 then
		result.line_verified = false
		result.verification_note = "文件不存在"
		return result
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		result.line_verified = false
		result.verification_note = "文件为空"
		return result
	end

	-- 1. 检查当前行号
	if
		result.line
		and result.line >= 1
		and result.line <= #lines
		and find_id_in_line(lines[result.line], result.id)
	then
		result.line_verified = true
		result.last_verified_at = os.time()
		return result
	end

	-- 2. ID 定位
	local new_line = locate_by_id(filepath, result.id)

	-- 3. 内容定位
	if not new_line then
		new_line = locate_by_content(filepath, result)
	end

	-- 4. 上下文定位
	local ctx_match = nil
	if not new_line then
		ctx_match = M.locate_by_context_fingerprint(filepath, result.context)
		new_line = ctx_match and ctx_match.line
	end

	if new_line then
		result.line = new_line
		result.line_verified = true
		result.last_verified_at = os.time()

		if ctx_match then
			result.context = ctx_match.context
			result.context_updated_at = os.time()
		end
	else
		result.line_verified = false
		result.verification_note = "无法重新定位链接"
	end

	return result
end

function M.locate_task_sync(link)
	return M._locate_in_file(link)
end

---------------------------------------------------------------------
-- 批量定位
---------------------------------------------------------------------
function M.locate_file_tasks(filepath, callback)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")

	local todo_links = index.find_todo_links_by_file(filepath) or {}
	local code_links = index.find_code_links_by_file(filepath) or {}

	local links = {}
	for _, l in ipairs(todo_links) do
		table.insert(links, l)
	end
	for _, l in ipairs(code_links) do
		table.insert(links, l)
	end

	local total = #links
	if total == 0 then
		if callback then
			callback({ located = 0, total = 0, results = {} })
		end
		return { located = 0, total = 0 }
	end

	local completed = 0
	local located = 0
	local results = {}

	for _, link in ipairs(links) do
		local old_line = link.line
		M.locate_task(link, function(located_link)
			if located_link and located_link.line_verified then
				located = located + 1
			end

			if located_link and located_link.line ~= old_line then
				local prefix = (link.type == "todo_to_code") and "todo.links.todo." or "todo.links.code."
				store.set_key(prefix .. link.id, located_link)
			end

			table.insert(results, located_link or link)

			completed = completed + 1
			if completed == total and callback then
				callback({ located = located, total = total, results = results })
			end
		end)
	end

	return { located = 0, total = total }
end

return M
