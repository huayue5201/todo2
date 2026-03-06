-- lua/todo2/store/locator.lua (修复上下文定位 + 索引自动更新)

local M = {}

local context = require("todo2.store.context")
local hash = require("todo2.utils.hash")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	MAX_SCAN_LINES = 1000,
	SIMILARITY_THRESHOLD = 60,
	SCAN_WINDOW = 20,
	CONTEXT_SIMILARITY_THRESHOLD = 70,
	CONTEXT_SEARCH_RADIUS = 50,

	SEARCH = {
		USE_CACHE = true,
		ASYNC = true,
		EXCLUDE_DIRS = { "node_modules", ".git", "dist", "build", "target" },
	},
}

-- 搜索缓存
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

-- 使用 id_utils 检查ID是否存在
local function find_id_in_line(line, id)
	if not line then
		return false
	end
	return (id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id)
		or (id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id)
end

---------------------------------------------------------------------
-- 使用上下文指纹定位
---------------------------------------------------------------------
function M.locate_by_context_fingerprint(filepath, stored_context, similarity_threshold)
	similarity_threshold = similarity_threshold or 70

	if vim.fn.filereadable(filepath) ~= 1 then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match = {
		line = nil,
		similarity = 0,
		context = nil,
	}

	for line_num = 1, #lines do
		local temp_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

		local current_ctx = context.build_from_buffer(temp_buf, line_num, filepath)
		vim.api.nvim_buf_delete(temp_buf, { force = true })

		local similarity = context.similarity(stored_context, current_ctx)

		if similarity > best_match.similarity then
			best_match.line = line_num
			best_match.similarity = similarity
			best_match.context = current_ctx

			if similarity >= similarity_threshold then
				break
			end
		end
	end

	if best_match.similarity >= similarity_threshold then
		return best_match
	end

	return nil
end

---------------------------------------------------------------------
-- 改进的上下文定位函数
---------------------------------------------------------------------
local function locate_by_context(filepath, link)
	if not link.context then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	-- 使用 link.line 作为搜索中心
	local search_start = link.line and math.max(1, link.line - CONFIG.CONTEXT_SEARCH_RADIUS) or 1
	local search_end = link.line and math.min(#lines, link.line + CONFIG.CONTEXT_SEARCH_RADIUS) or #lines

	local best_match = {
		line = nil,
		similarity = 0,
		context = nil,
	}

	-- 先尝试在目标行附近查找
	for line_num = search_start, search_end do
		local temp_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

		local candidate = context.build_from_buffer(temp_buf, line_num, filepath)
		vim.api.nvim_buf_delete(temp_buf, { force = true })

		if candidate then
			local similarity = context.similarity(link.context, candidate)

			if similarity > best_match.similarity then
				best_match.line = line_num
				best_match.similarity = similarity
				best_match.context = candidate
			end

			if similarity >= CONFIG.CONTEXT_SIMILARITY_THRESHOLD then
				return best_match
			end
		end
	end

	-- 如果没找到，扩大搜索范围
	if best_match.similarity < 50 then
		for line_num = 1, #lines do
			if line_num < search_start or line_num > search_end then
				local temp_buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

				local candidate = context.build_from_buffer(temp_buf, line_num, filepath)
				vim.api.nvim_buf_delete(temp_buf, { force = true })

				if candidate then
					local similarity = context.similarity(link.context, candidate)
					if similarity > best_match.similarity then
						best_match.line = line_num
						best_match.similarity = similarity
						best_match.context = candidate
					end
				end
			end
		end
	end

	if best_match.similarity >= 40 then
		return best_match
	end

	return nil
end

---------------------------------------------------------------------
-- rg 检测
---------------------------------------------------------------------
local function has_rg()
	return vim.fn.executable("rg") == 1
end

---------------------------------------------------------------------
-- 异步 rg 搜索
---------------------------------------------------------------------
function M.async_search_file_by_id(id, callback)
	if CONFIG.SEARCH.USE_CACHE and search_cache[id] then
		local cached = search_cache[id]
		if vim.fn.filereadable(cached) == 1 then
			vim.schedule(function()
				if callback then
					callback(cached)
				end
			end)
			return
		end
	end

	local project_root = require("todo2.store.meta").get_project_root()

	if not has_rg() then
		local result = M._search_file_by_id_find(id)
		vim.schedule(function()
			if callback then
				callback(result)
			end
		end)
		return
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

	local todo_pattern = id_utils.escape_for_rg(id_utils.format_todo_anchor(id))
	table.insert(args, "-e")
	table.insert(args, todo_pattern)

	local code_pattern = id_utils.escape_for_rg(id_utils.REF_SEPARATOR .. id)
	table.insert(args, "-e")
	table.insert(args, code_pattern)

	table.insert(args, project_root)

	local stdout = vim.loop.new_pipe(false)
	local stderr = vim.loop.new_pipe(false)

	local handle
	local output = {}

	handle = vim.loop.spawn("rg", {
		args = args,
		stdio = { nil, stdout, stderr },
	}, function(code, signal)
		stdout:close()
		stderr:close()
		if handle then
			handle:close()
		end

		local result = table.concat(output):match("[^\n]+")

		if result and result ~= "" and CONFIG.SEARCH.USE_CACHE then
			search_cache[id] = result
		end

		vim.schedule(function()
			if callback then
				callback(result)
			end
		end)
	end)

	if stdout then
		stdout:read_start(function(err, data)
			if data then
				table.insert(output, data)
			end
		end)
	end

	if stderr then
		stderr:read_start(function(err, data)
			if data then
				vim.schedule(function()
					vim.notify("rg搜索错误: " .. data, vim.log.levels.DEBUG)
				end)
			end
		end)
	end
end

function M._search_file_by_id_rg(id)
	local project_root = require("todo2.store.meta").get_project_root()

	local exclude_pattern = ""
	for _, dir in ipairs(CONFIG.SEARCH.EXCLUDE_DIRS) do
		exclude_pattern = exclude_pattern .. " -g '!" .. dir .. "/*'"
	end

	local todo_pattern = id_utils.escape_for_rg(id_utils.format_todo_anchor(id))
	local code_pattern = id_utils.escape_for_rg(id_utils.REF_SEPARATOR .. id)

	local cmd = string.format(
		"rg -l -m1 --no-ignore -u %s '%s|%s' %s 2>/dev/null | head -1",
		exclude_pattern,
		todo_pattern,
		code_pattern,
		project_root
	)

	local handle = io.popen(cmd)
	if handle then
		local result = handle:read("*l")
		handle:close()
		return result
	end
	return nil
end

function M._search_file_by_id_find(id)
	local project_root = require("todo2.store.meta").get_project_root()

	local exclude_dirs = {}
	for _, dir in ipairs(CONFIG.SEARCH.EXCLUDE_DIRS) do
		table.insert(exclude_dirs, "-path '*/" .. dir .. "/*' -prune -o")
	end

	local exclude_part = table.concat(exclude_dirs, " ")

	local todo_pattern = id_utils.format_todo_anchor(id)
	local code_pattern = id_utils.REF_SEPARATOR .. id

	local find_cmd = string.format(
		"find %s %s -type f -exec grep -l '%s\\|%s' {} \\; 2>/dev/null | head -1",
		project_root,
		exclude_part,
		todo_pattern,
		code_pattern
	)

	local handle = io.popen(find_cmd)
	if handle then
		local result = handle:read("*l")
		handle:close()
		return result
	end
	return nil
end

function M.search_file_by_id(id, callback)
	if callback and type(callback) == "function" and CONFIG.SEARCH.ASYNC then
		M.async_search_file_by_id(id, callback)
	else
		if CONFIG.SEARCH.USE_CACHE and search_cache[id] then
			local cached = search_cache[id]
			if vim.fn.filereadable(cached) == 1 then
				return cached
			end
		end

		local result = nil
		if has_rg() then
			result = M._search_file_by_id_rg(id)
		else
			result = M._search_file_by_id_find(id)
		end

		if result and result ~= "" and CONFIG.SEARCH.USE_CACHE then
			search_cache[id] = result
		end

		return result
	end
end

function M.search_file_by_id_sync(id)
	return M.search_file_by_id(id, nil)
end

function M.clear_cache()
	search_cache = {}
	vim.notify("搜索缓存已清除", vim.log.levels.INFO)
end

---------------------------------------------------------------------
-- 定位策略
---------------------------------------------------------------------
local function locate_by_id(filepath, id)
	local lines = read_file_lines(filepath)
	for line_num = 1, #lines do
		if find_id_in_line(lines[line_num], id) then
			return line_num
		end
	end
	return nil
end

local function locate_by_content(filepath, link)
	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match, best_score = nil, 0
	local max_line = math.min(#lines, CONFIG.MAX_SCAN_LINES)

	for line_num = 1, max_line do
		local line = lines[line_num]
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
			local distance = math.abs(line_num - link.line)
			if distance < CONFIG.SCAN_WINDOW then
				score = score + math.max(0, 20 - distance)
			end
		end

		if score > best_score then
			best_score, best_match = score, line_num
		end
	end

	return best_match and best_score >= CONFIG.SIMILARITY_THRESHOLD and best_match or nil
end

---------------------------------------------------------------------
-- ⭐ 修复7：主定位函数（添加索引自动更新）
---------------------------------------------------------------------
function M.locate_task(link, callback)
	if not link then
		local err_link = {
			line_verified = false,
			verification_failed_at = os.time(),
			verification_note = "链接为空",
		}
		if callback then
			vim.schedule(function()
				callback(err_link)
			end)
		end
		return err_link
	end

	-- 归档链接不参与定位
	if link.status == "archived" then
		link.line_verified = true
		link.last_verified_at = os.time()
		if callback then
			vim.schedule(function()
				callback(link)
			end)
		end
		return link
	end

	-- ⭐ 关键修复：统一的完成函数，自动更新索引（只改这里）
	local function finish(located_link)
		if not located_link then
			located_link = vim.deepcopy(link)
			located_link.line_verified = false
			located_link.verification_failed_at = os.time()
			located_link.verification_note = "定位失败"
		end

		-- ⭐ 如果路径变了，更新索引（保持原有逻辑，只改调用方式）
		if located_link and located_link.path and link.path and located_link.path ~= link.path then
			local index = require("todo2.store.index")
			local link_type = link.type == "todo_to_code" and "todo" or "code"
			local index_ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"

			-- 从旧文件移除
			if link.path then
				index._remove_id_from_file_index(index_ns, link.path, link.id)
			end
			-- 添加到新文件
			if located_link.path then
				index._add_id_to_file_index(index_ns, located_link.path, link.id)

				-- ⭐ 修复：如果这是代码端，使用 link.update_todo 更新TODO端的路径
				if link_type == "code" then
					local todo_link = require("todo2.store.link").get_todo(link.id, { verify_line = false })
					if todo_link and todo_link.path ~= located_link.path then
						todo_link.path = located_link.path
						require("todo2.store.link").update_todo(link.id, todo_link)
					end
				end
			end

			-- 调试信息
			vim.schedule(function()
				vim.notify(
					string.format(
						"索引更新: %s 从 %s 移动到 %s",
						link.id:sub(1, 6),
						vim.fn.fnamemodify(link.path, ":t"),
						vim.fn.fnamemodify(located_link.path, ":t")
					),
					vim.log.levels.DEBUG
				)
			end)
		end

		if callback then
			vim.schedule(function()
				callback(located_link)
			end)
		end
		return located_link
	end

	if not link.path or not link.id then
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "缺少路径或ID"
		return finish(link)
	end

	local filepath = link.path
	local file_exists = vim.fn.filereadable(filepath) == 1

	if not file_exists then
		M.search_file_by_id(link.id, function(found_path)
			if found_path then
				link.path = found_path
				link.line_verified = false
				link.verification_failed_at = nil
				link.verification_note = nil
				vim.notify(
					string.format("找到移动的文件: %s", vim.fn.fnamemodify(found_path, ":.")),
					vim.log.levels.INFO
				)
				local result = M._locate_in_file(link)
				finish(result)
			else
				link.line_verified = false
				link.verification_failed_at = os.time()
				link.verification_note = "文件不存在且未找到"
				finish(link)
			end
		end)
		return link
	else
		local result = M._locate_in_file(link)
		return finish(result)
	end
end

--- 修复8：在文件中定位
function M._locate_in_file(link)
	if not link then
		return {
			line_verified = false,
			verification_failed_at = os.time(),
			verification_note = "链接为空",
		}
	end

	local result = vim.deepcopy(link)

	local filepath = result.path
	if not filepath or vim.fn.filereadable(filepath) ~= 1 then
		result.line_verified = false
		result.verification_failed_at = os.time()
		result.verification_note = "文件不存在"
		result.last_verified_at = nil
		return result
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		result.line_verified = false
		result.verification_failed_at = os.time()
		result.verification_note = "文件为空"
		result.last_verified_at = nil
		return result
	end

	-- 先检查当前记录的行号是否仍然正确
	if
		result.line
		and result.line >= 1
		and result.line <= #lines
		and find_id_in_line(lines[result.line], result.id)
	then
		result.line_verified = true
		result.last_verified_at = os.time()
		result.verification_failed_at = nil
		result.verification_note = nil
		return result
	end

	-- 通过ID查找
	local new_line = locate_by_id(filepath, result.id)

	-- 通过内容查找
	if not new_line then
		new_line = locate_by_content(filepath, result)
	end

	-- 通过上下文查找
	local context_match = nil
	if not new_line then
		context_match = locate_by_context(filepath, result)
		new_line = context_match and context_match.line
	end

	if new_line then
		local position_changed = (result.line ~= new_line)

		result.line = new_line
		result.line_verified = true
		result.last_verified_at = os.time()
		result.verification_failed_at = nil
		result.verification_note = nil

		if position_changed then
			if context_match then
				result.context = context_match.context
				result.context_updated_at = os.time()
			else
				-- 如果没有上下文匹配，重新构建上下文
				local temp_buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)
				local new_context = context.build_from_buffer(temp_buf, new_line, filepath)
				vim.api.nvim_buf_delete(temp_buf, { force = true })
				if new_context then
					result.context = new_context
					result.context_updated_at = os.time()
				end
			end

			vim.schedule(function()
				vim.notify(
					string.format("修复链接 %s: 行号 %d → %d", result.id:sub(1, 6), link.line or 0, new_line),
					vim.log.levels.INFO
				)
			end)
		end
	else
		result.line_verified = false
		result.verification_failed_at = os.time()
		result.verification_note = "无法重新定位链接"
		result.last_verified_at = nil
	end

	return result
end

function M.locate_task_sync(link)
	if not link then
		return {
			line_verified = false,
			verification_failed_at = os.time(),
			verification_note = "链接为空",
		}
	end
	return M._locate_in_file(link)
end

---------------------------------------------------------------------
-- 批量定位文件中的所有任务
---------------------------------------------------------------------
function M.locate_file_tasks(filepath, callback)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")

	local links = index.find_todo_links_by_file(filepath) or {}
	local code_links = index.find_code_links_by_file(filepath) or {}
	for _, link in ipairs(code_links) do
		table.insert(links, link)
	end

	local located = 0
	local total = #links
	local completed = 0
	local results = {}

	if total == 0 then
		if callback then
			callback({ located = 0, total = 0, results = {} })
		end
		return { located = 0, total = 0 }
	end

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
