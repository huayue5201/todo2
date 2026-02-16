-- lua/todo2/store/locator.lua (修复版)
-- 行号定位模块 - 支持 ripgrep 异步搜索

local M = {}

local context = require("todo2.store.context")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	MAX_SCAN_LINES = 1000,
	SIMILARITY_THRESHOLD = 60,
	SCAN_WINDOW = 20,
	CONTEXT_SIMILARITY_THRESHOLD = 70,
	CONTEXT_SEARCH_RADIUS = 50,

	-- rg 配置
	SEARCH = {
		USE_CACHE = true,
		ASYNC = true,
		EXCLUDE_DIRS = { "node_modules", ".git", "dist", "build", "target" },
		FILE_TYPES = { "*.lua", "*.md", "*.todo", "*.rs", "*.py", "*.js", "*.ts", "*.go", "*.java", "*.cpp" },
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

local function calculate_content_hash(content)
	if not content or content == "" then
		return "00000000"
	end
	local hash = 0
	for i = 1, math.min(#content, 100) do
		hash = (hash * 31 + string.byte(content, i)) % 4294967296
	end
	return string.format("%08x", hash)
end

local function find_id_in_line(line, id)
	return line and (line:match("{#" .. id .. "}") or line:match(":ref:" .. id))
end

---------------------------------------------------------------------
-- rg 检测
---------------------------------------------------------------------
local function has_rg()
	return vim.fn.executable("rg") == 1
end

---------------------------------------------------------------------
-- ⭐ 异步 rg 搜索
---------------------------------------------------------------------
function M.async_search_file_by_id(id, callback)
	-- 检查缓存
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
		-- 没有 rg，回退到同步 find+grep
		local result = M._search_file_by_id_find(id)
		vim.schedule(function()
			if callback then
				callback(result)
			end
		end)
		return
	end

	-- 构建 rg 命令参数
	local args = {
		"-l", -- 只输出文件名
		"-m",
		"1", -- 第一个匹配后停止
		"-i", -- 忽略大小写
	}

	-- 添加文件类型过滤
	for _, pattern in ipairs(CONFIG.SEARCH.FILE_TYPES) do
		table.insert(args, "-g")
		table.insert(args, pattern)
	end

	-- 添加排除目录
	for _, dir in ipairs(CONFIG.SEARCH.EXCLUDE_DIRS) do
		table.insert(args, "-g")
		table.insert(args, "!" .. dir .. "/*")
	end

	-- 添加搜索模式和路径
	table.insert(args, string.format("'{%s}|:ref:%s'", id, id))
	table.insert(args, project_root)

	-- 创建异步进程
	local stdout = vim.loop.new_pipe(false)
	local stderr = vim.loop.new_pipe(false)

	local handle
	local output = {}

	handle = vim.loop.spawn("rg", {
		args = args,
		stdio = { nil, stdout, stderr },
	}, function(code, signal)
		-- 进程结束
		stdout:close()
		stderr:close()
		if handle then
			handle:close()
		end

		local result = table.concat(output):match("[^\n]+")

		-- 更新缓存
		if result and result ~= "" and CONFIG.SEARCH.USE_CACHE then
			search_cache[id] = result
		end

		-- 回调
		vim.schedule(function()
			if callback then
				callback(result)
			end
		end)
	end)

	-- 读取输出
	if stdout then
		stdout:read_start(function(err, data)
			if data then
				table.insert(output, data)
			end
		end)
	end

	-- 错误处理
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

---------------------------------------------------------------------
-- ⭐ 同步 rg 搜索（作为后备）
---------------------------------------------------------------------
function M._search_file_by_id_rg(id)
	local project_root = require("todo2.store.meta").get_project_root()

	local exclude_pattern = ""
	for _, dir in ipairs(CONFIG.SEARCH.EXCLUDE_DIRS) do
		exclude_pattern = exclude_pattern .. " -g '!" .. dir .. "/*'"
	end

	local cmd = string.format(
		"rg -l -m1 -g '%s' %s '{%s}|:ref:%s' %s 2>/dev/null | head -1",
		table.concat(CONFIG.SEARCH.FILE_TYPES, "' -g '"),
		exclude_pattern,
		id,
		id,
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

---------------------------------------------------------------------
-- ⭐ 同步 find+grep（最终后备）
---------------------------------------------------------------------
function M._search_file_by_id_find(id)
	local project_root = require("todo2.store.meta").get_project_root()

	-- 从文件类型提取扩展名
	local extensions = {}
	for _, pattern in ipairs(CONFIG.SEARCH.FILE_TYPES) do
		local ext = pattern:match("%*%.(.+)")
		if ext then
			table.insert(extensions, ext)
		end
	end

	local patterns = {}
	for _, ext in ipairs(extensions) do
		table.insert(patterns, "-name '*." .. ext .. "'")
	end

	local find_cmd = string.format(
		"find %s -type f \\( %s \\) -exec grep -l '{%s}\\|:ref:%s' {} \\; 2>/dev/null | head -1",
		project_root,
		table.concat(patterns, " -o "),
		id,
		id
	)

	local handle = io.popen(find_cmd)
	if handle then
		local result = handle:read("*l")
		handle:close()
		return result
	end
	return nil
end

---------------------------------------------------------------------
-- ⭐ 统一搜索入口
---------------------------------------------------------------------
function M.search_file_by_id(id, callback)
	if callback and type(callback) == "function" and CONFIG.SEARCH.ASYNC then
		-- 异步模式
		M.async_search_file_by_id(id, callback)
	else
		-- 同步模式（无回调或强制同步）
		-- 检查缓存
		if CONFIG.SEARCH.USE_CACHE and search_cache[id] then
			local cached = search_cache[id]
			if vim.fn.filereadable(cached) == 1 then
				return cached
			end
		end

		-- 执行搜索
		local result = nil
		if has_rg() then
			result = M._search_file_by_id_rg(id)
		else
			result = M._search_file_by_id_find(id)
		end

		-- 更新缓存
		if result and result ~= "" and CONFIG.SEARCH.USE_CACHE then
			search_cache[id] = result
		end

		return result
	end
end

-- ⭐ 同步版本（方便调用）
function M.search_file_by_id_sync(id)
	return M.search_file_by_id(id, nil)
end

---------------------------------------------------------------------
-- 清除缓存
---------------------------------------------------------------------
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
		if link.content_hash and calculate_content_hash(line) == link.content_hash then
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

local function locate_by_context(filepath, link)
	if not link.context then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local search_start = link.line and math.max(1, link.line - CONFIG.CONTEXT_SEARCH_RADIUS) or 1
	local search_end = link.line and math.min(#lines, link.line + CONFIG.CONTEXT_SEARCH_RADIUS) or #lines

	for line_num = search_start, search_end do
		local prev = line_num > 1 and lines[line_num - 1] or ""
		local curr = lines[line_num]
		local next = line_num < #lines and lines[line_num + 1] or ""
		local candidate = context.build(prev, curr, next)

		if context.match(link.context, candidate) then
			return { line = line_num, context = candidate }
		end
	end

	return nil
end

---------------------------------------------------------------------
-- ⭐ 主定位函数（修复版 - 确保永远不返回 nil）
---------------------------------------------------------------------
function M.locate_task(link, callback)
	-- 确保 link 存在
	if not link then
		local err_link =
			{ line_verified = false, verification_failed_at = os.time(), verification_note = "链接为空" }
		if callback then
			vim.schedule(function()
				callback(err_link)
			end)
		end
		return err_link
	end

	local function finish(located_link)
		-- 确保返回的一定是表
		if not located_link then
			located_link = vim.deepcopy(link)
			located_link.line_verified = false
			located_link.verification_failed_at = os.time()
			located_link.verification_note = "定位失败"
		end
		if callback then
			vim.schedule(function()
				callback(located_link)
			end)
		end
		return located_link
	end

	-- 如果没有 path 或 id，直接返回原链接（标记为未验证）
	if not link.path or not link.id then
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "缺少路径或ID"
		return finish(link)
	end

	-- 检查文件是否存在
	local filepath = link.path
	local file_exists = vim.fn.filereadable(filepath) == 1

	if not file_exists then
		-- 需要跨文件搜索
		M.search_file_by_id(link.id, function(found_path)
			if found_path then
				link.path = found_path
				link.line_verified = false
				vim.notify(
					string.format("找到移动的文件: %s", vim.fn.fnamemodify(found_path, ":.")),
					vim.log.levels.INFO
				)
				-- 继续定位行号
				local result = M._locate_in_file(link)
				finish(result)
			else
				link.line_verified = false
				link.verification_failed_at = os.time()
				link.verification_note = "文件不存在且未找到"
				finish(link)
			end
		end)
		return link -- 立即返回，实际结果在回调中
	else
		-- 文件存在，直接定位行号
		local result = M._locate_in_file(link)
		return finish(result)
	end
end

-- ⭐ 在已知文件中定位行号（修复版 - 确保永远不返回 nil）
function M._locate_in_file(link)
	-- 确保 link 存在
	if not link then
		return nil
	end

	-- 创建返回对象的副本，避免修改原始对象
	local result = vim.deepcopy(link)

	local filepath = result.path
	if not filepath or vim.fn.filereadable(filepath) ~= 1 then
		result.line_verified = false
		result.verification_failed_at = os.time()
		result.verification_note = "文件不存在"
		return result
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		result.line_verified = false
		result.verification_failed_at = os.time()
		result.verification_note = "文件为空"
		return result
	end

	-- 检查当前位置
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

	-- 尝试重新定位
	local new_line = locate_by_id(filepath, result.id) or locate_by_content(filepath, result)

	local context_match = nil
	if not new_line then
		context_match = locate_by_context(filepath, result)
		new_line = context_match and context_match.line
	end

	if new_line then
		result.line = new_line
		result.line_verified = true
		result.last_verified_at = os.time()
		result.updated_at = os.time()

		if context_match then
			result.context = context_match.context
			result.context_updated_at = os.time()
		end

		-- 异步通知，但不阻塞返回
		vim.schedule(function()
			vim.notify(
				string.format("修复链接 %s: 行号 %d → %d", result.id:sub(1, 6), link.line or 0, new_line),
				vim.log.levels.INFO
			)
		end)
	else
		result.line_verified = false
		result.verification_failed_at = os.time()
		result.verification_note = "无法重新定位链接"
	end

	return result
end

-- ⭐ 同步版本（兼容旧代码）- 修复版
function M.locate_task_sync(link)
	if not link then
		return { line_verified = false, verification_note = "链接为空" }
	end
	return M._locate_in_file(link)
end

---------------------------------------------------------------------
-- 批量定位文件中的所有任务（异步）
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

	-- 逐个异步处理
	for _, link in ipairs(links) do
		local old_line = link.line
		M.locate_task(link, function(located_link)
			if located_link and located_link.line ~= old_line then
				local prefix = (link.type == "todo_to_code") and "todo.links.todo." or "todo.links.code."
				store.set_key(prefix .. link.id, located_link)
				located = located + 1
			end
			table.insert(results, located_link or link)

			completed = completed + 1
			if completed == total and callback then
				callback({ located = located, total = total, results = results })
			end
		end)
	end

	return { located = 0, total = total } -- 立即返回，实际结果在回调中
end

M.calculate_content_hash = calculate_content_hash

return M
