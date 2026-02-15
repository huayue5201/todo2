-- lua/todo2/store/locator.lua
-- 智能定位系统

local M = {}

local context = require("todo2.store.context")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	MAX_SCAN_LINES = 1000,
	SIMILARITY_THRESHOLD = 60,
	SCAN_WINDOW = 20,
	CONTEXT_WINDOW = 5,
	CONTEXT_SIMILARITY_THRESHOLD = 70,
	MAX_CONTEXT_MATCHES = 3,
	CONTEXT_SEARCH_RADIUS = 50,
}

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
	if not line then
		return false
	end
	return line:match("{#" .. id .. "}") or line:match(":ref:" .. id)
end

-- 从文件路径获取缓冲区号
local function get_bufnr_from_path(filepath)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name == filepath then
				return bufnr
			end
		end
	end
	return nil
end

-- 构建上下文指纹（使用新 API）
local function build_context_fingerprint(filepath, line_num)
	if not filepath or not line_num then
		return nil
	end

	-- 优先使用 context.build_from_file（它会自动处理缓冲区和文件读取）
	return context.build_from_file(filepath, line_num)
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

-- 基于内容匹配定位
local function locate_by_content(filepath, link)
	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match = nil
	local best_score = 0
	local max_line = math.min(#lines, CONFIG.MAX_SCAN_LINES)

	for line_num = 1, max_line do
		local line = lines[line_num]
		local score = 0

		if link.tag and line:match("%[" .. link.tag .. "%]") then
			score = score + 40
		end
		if link.content_hash then
			local line_hash = calculate_content_hash(line)
			if line_hash == link.content_hash then
				score = score + 50
			end
		end
		if link.content and line:match(link.content:sub(1, 20)) then
			score = score + 30
		end
		if link.line and link.line > 0 then
			local distance = math.abs(line_num - link.line)
			if distance < CONFIG.SCAN_WINDOW then
				score = score + math.max(0, 20 - distance)
			end
		end

		if score > best_score then
			best_score = score
			best_match = line_num
		end
	end

	if best_match and best_score >= CONFIG.SIMILARITY_THRESHOLD then
		return best_match
	end
	return nil
end

-- 基于上下文匹配定位
local function locate_by_context(filepath, link)
	if not link.context then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match = nil
	local search_start, search_end

	if link.line and link.line > 0 then
		search_start = math.max(1, link.line - CONFIG.CONTEXT_SEARCH_RADIUS)
		search_end = math.min(#lines, link.line + CONFIG.CONTEXT_SEARCH_RADIUS)
	else
		search_start = 1
		search_end = math.min(#lines, CONFIG.MAX_SCAN_LINES)
	end

	for line_num = search_start, search_end do
		local candidate_context = context.build_from_file(filepath, line_num)

		if candidate_context then
			local is_match = context.match(link.context, candidate_context)

			if is_match and not best_match then
				best_match = {
					line = line_num,
					similarity = 100,
					context = candidate_context,
				}
				break
			end
		end
	end

	return best_match
end

-- 跨文件搜索函数
function M.search_file_by_id(id)
	local project_root = require("todo2.store.meta").get_project_root()

	-- 搜索常见的文件类型
	local extensions = { "lua", "md", "todo", "rs", "py", "js", "ts", "go", "java", "cpp", "c", "h" }
	local patterns = {}
	for _, ext in ipairs(extensions) do
		table.insert(patterns, "-name '*." .. ext .. "'")
	end
	local name_pattern = table.concat(patterns, " -o ")

	-- 构建 find 命令
	local find_cmd = string.format(
		"find %s -type f \\( %s \\) -exec grep -l '{%s}\\|:ref:%s' {} \\; 2>/dev/null | head -1",
		project_root,
		name_pattern,
		id,
		id
	)

	local handle = io.popen(find_cmd)
	if handle then
		local result = handle:read("*l")
		handle:close()
		if result and result ~= "" then
			return result
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 主定位函数
---------------------------------------------------------------------
function M.locate_task(link)
	if not link or not link.path or not link.id then
		return link
	end

	local filepath = link.path
	local file_exists = vim.fn.filereadable(filepath) == 1

	-- 1. 如果文件不存在，立即触发跨文件搜索
	if not file_exists then
		local found_path = M.search_file_by_id(link.id)
		if found_path then
			link.path = found_path
			filepath = found_path
			file_exists = true
			link.line_verified = false
			vim.notify(
				string.format("找到移动的文件: %s", vim.fn.fnamemodify(found_path, ":.")),
				vim.log.levels.INFO
			)
		else
			link.line_verified = false
			link.verification_failed_at = os.time()
			link.verification_note = "文件不存在且未找到"
			return link
		end
	end

	local lines = read_file_lines(filepath)

	-- 检查当前行是否有效
	if link.line and link.line >= 1 and link.line <= #lines then
		local current_line = lines[link.line]
		if find_id_in_line(current_line, link.id) then
			if link.context then
				-- 使用新 API 构建上下文
				local new_context = build_context_fingerprint(filepath, link.line)
				if new_context then
					-- 使用 context.match 进行匹配
					local is_match = context.match(link.context, new_context)
					link.context_matched = is_match
					link.context_similarity = is_match and 100 or 0
					if is_match then
						link.context = new_context
						link.context_updated_at = os.time()
					end
				end
			end
			link.line_verified = true
			link.last_verified_at = os.time()
			return link
		end
	end

	-- 尝试重新定位
	local new_line = nil
	local used_strategy = nil
	local context_match = nil

	new_line = locate_by_id(filepath, link.id)
	if new_line then
		used_strategy = "id_match"
	end

	if not new_line then
		new_line = locate_by_content(filepath, link)
		if new_line then
			used_strategy = "content_match"
		end
	end

	if not new_line and link.context then
		context_match = locate_by_context(filepath, link)
		if context_match then
			new_line = context_match.line
			used_strategy = "context_match"
		end
	end

	if new_line and new_line ~= link.line then
		link.line = new_line
		link.line_verified = true
		link.last_verified_at = os.time()
		link.updated_at = os.time()

		if lines[new_line] then
			link.content_hash = calculate_content_hash(lines[new_line])
		end

		if context_match then
			link.context_matched = true
			link.context_similarity = context_match.similarity
			link.context = context_match.context
			link.context_updated_at = os.time()
		else
			-- 使用新 API 构建上下文
			local new_context = build_context_fingerprint(filepath, new_line)
			if new_context then
				link.context = new_context
				link.context_updated_at = os.time()
			end
		end

		vim.schedule(function()
			vim.notify(
				string.format(
					"修复链接 %s: 行号 %d → %d (策略: %s)",
					link.id:sub(1, 6),
					link.line or 0,
					new_line,
					used_strategy or "unknown"
				),
				vim.log.levels.INFO
			)
		end)
	elseif link.line then
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "无法重新定位链接"
	else
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "缺少行号信息"
	end

	return link
end

--- 批量更新文件中的链接上下文
function M.update_file_contexts(filepath)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")

	local result = { updated = 0, total = 0 }

	local todo_links = index.find_todo_links_by_file(filepath)
	for _, todo_link in ipairs(todo_links) do
		result.total = result.total + 1
		local updated = M.locate_task(todo_link)
		if updated.context then
			store.set_key("todo.links.todo." .. todo_link.id, updated)
			result.updated = result.updated + 1
		end
	end

	local code_links = index.find_code_links_by_file(filepath)
	for _, code_link in ipairs(code_links) do
		result.total = result.total + 1
		local updated = M.locate_task(code_link)
		if updated.context then
			store.set_key("todo.links.code." .. code_link.id, updated)
			result.updated = result.updated + 1
		end
	end

	return result
end

--- 批量定位文件中的所有任务
function M.locate_file_tasks(filepath)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")
	local types = require("todo2.store.types")

	local links = {}
	local todo_links = index.find_todo_links_by_file(filepath)
	for _, link in ipairs(todo_links) do
		table.insert(links, link)
	end
	local code_links = index.find_code_links_by_file(filepath)
	for _, link in ipairs(code_links) do
		table.insert(links, link)
	end

	local located = 0
	for _, link in ipairs(links) do
		local old_line = link.line
		local located_link = M.locate_task(link)
		if located_link.line ~= old_line then
			local key_prefix = (link.type == types.LINK_TYPES.TODO_TO_CODE) and "todo.links.todo." or "todo.links.code."
			store.set_key(key_prefix .. link.id, located_link)
			located = located + 1
		end
	end

	return { located = located, total = #links }
end

--- 查找恢复代码标记的最佳位置
function M.find_restore_position(code_snapshot)
	if not code_snapshot or not code_snapshot.path then
		return 1
	end

	local filepath = code_snapshot.path
	if vim.fn.filereadable(filepath) == 0 then
		return 1
	end

	local lines = read_file_lines(filepath)

	if code_snapshot.context then
		local fake_link = {
			context = code_snapshot.context,
			line = code_snapshot.line,
		}
		local context_match = locate_by_context(filepath, fake_link)
		if context_match then
			return context_match.line
		end
	end

	if code_snapshot.line and code_snapshot.line <= #lines then
		for i = code_snapshot.line, 1, -1 do
			if i <= #lines then
				local line = lines[i]
				if line:match("^function ") or line:match("^local function") then
					return i + 1
				end
			end
		end

		for i = code_snapshot.line, 1, -1 do
			if i <= #lines and lines[i]:match("^%s*$") then
				return i + 1
			end
		end
	end

	if code_snapshot.content then
		local best_match = nil
		local best_score = 0

		for line_num = 1, math.min(#lines, 1000) do
			local line = lines[line_num]
			local score = 0

			local content_preview = code_snapshot.content:sub(1, 50)
			for word in content_preview:gmatch("%w+") do
				if #word > 3 and line:find(word, 1, true) then
					score = score + 5
				end
			end

			if score > best_score then
				best_score = score
				best_match = line_num
			end
		end

		if best_match and best_score > 10 then
			return best_match
		end
	end

	return #lines + 1
end

--- 验证恢复位置是否合适
function M.validate_restore_position(filepath, line_num, code_snapshot)
	if vim.fn.filereadable(filepath) == 0 then
		return false, "文件不存在"
	end

	local lines = read_file_lines(filepath)
	if line_num < 1 or line_num > #lines + 1 then
		return false, "行号超出范围"
	end

	if line_num <= #lines then
		local existing_line = lines[line_num]

		if code_snapshot.id and existing_line:find(code_snapshot.id) then
			return false, "该位置已存在相同ID的标记"
		end

		if existing_line:match("^%s*$") then
			return true, "空行位置，理想"
		end

		if existing_line:match("^%s*//") or existing_line:match("^%s*#") or existing_line:match("^%s*%-%-") then
			return true, "注释行位置，可接受"
		end
	end

	return true, "位置可用"
end

M.calculate_content_hash = calculate_content_hash

return M
