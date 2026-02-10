-- lua/todo2/store/locator.lua
--- @module todo2.store.locator
--- 智能定位系统：集成基础定位和上下文定位

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local context = require("todo2.store.context")
local utils = require("todo2.store.utils")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	-- 基础定位配置
	MAX_SCAN_LINES = 1000, -- 最大扫描行数
	SIMILARITY_THRESHOLD = 60, -- 相似度阈值（0-100）
	SCAN_WINDOW = 20, -- 扫描窗口大小

	-- 上下文定位配置
	CONTEXT_WINDOW = 5, -- 上下文窗口大小（前后行数）
	CONTEXT_SIMILARITY_THRESHOLD = 70, -- 上下文相似度阈值
	MAX_CONTEXT_MATCHES = 3, -- 最大上下文匹配数
	CONTEXT_SEARCH_RADIUS = 50, -- 上下文搜索半径（±行数）
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

-- 计算简单哈希（用于内容验证）
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

-- 查找任务ID在行中的位置
local function find_id_in_line(line, id)
	if not line then
		return false
	end
	return line:match("{#" .. id .. "}") or line:match(":ref:" .. id)
end

-- 读取上下文行
local function read_context_lines(filepath, line_num, window_size)
	if not filepath or vim.fn.filereadable(filepath) ~= 1 then
		return {}
	end

	local lines = vim.fn.readfile(filepath)
	local context_lines = {}

	local start_line = math.max(1, line_num - window_size)
	local end_line = math.min(#lines, line_num + window_size)

	for i = start_line, end_line do
		table.insert(context_lines, lines[i])
	end

	return context_lines
end

-- 构建上下文指纹
local function build_context_fingerprint(filepath, line_num)
	if not filepath or not line_num then
		return nil
	end

	local lines = vim.fn.readfile(filepath)
	if #lines == 0 or line_num > #lines then
		return nil
	end

	local prev_line = line_num > 1 and lines[line_num - 1] or ""
	local curr_line = lines[line_num]
	local next_line = line_num < #lines and lines[line_num + 1] or ""

	return context.build(prev_line, curr_line, next_line)
end

-- 计算上下文相似度
local function calculate_context_similarity(old_ctx, new_ctx)
	if not old_ctx or not new_ctx then
		return 0
	end

	local score = 0

	-- 1. 直接比较指纹哈希（最精确）
	if old_ctx.fingerprint and new_ctx.fingerprint and old_ctx.fingerprint.hash == new_ctx.fingerprint.hash then
		return 100
	end

	-- 2. 比较代码结构
	if
		old_ctx.fingerprint
		and new_ctx.fingerprint
		and old_ctx.fingerprint.struct
		and new_ctx.fingerprint.struct
		and old_ctx.fingerprint.struct == new_ctx.fingerprint.struct
	then
		score = score + 60
	end

	-- 3. 比较规范化行内容
	if old_ctx.fingerprint and new_ctx.fingerprint then
		if old_ctx.fingerprint.n_curr == new_ctx.fingerprint.n_curr then
			score = score + 20
		end

		if old_ctx.fingerprint.n_prev == new_ctx.fingerprint.n_prev then
			score = score + 10
		end

		if old_ctx.fingerprint.n_next == new_ctx.fingerprint.n_next then
			score = score + 10
		end
	end

	return score
end

---------------------------------------------------------------------
-- 定位策略1：ID精确匹配
---------------------------------------------------------------------
function M._locate_by_id(filepath, id)
	local lines = read_file_lines(filepath)
	for line_num = 1, #lines do
		if find_id_in_line(lines[line_num], id) then
			return line_num
		end
	end
	return nil
end

---------------------------------------------------------------------
-- 定位策略2：内容和标签匹配
---------------------------------------------------------------------
function M._locate_by_content(filepath, link)
	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match = nil
	local best_score = 0

	-- 只扫描前1000行（性能优化）
	local max_line = math.min(#lines, CONFIG.MAX_SCAN_LINES)

	for line_num = 1, max_line do
		local line = lines[line_num]
		local score = 0

		-- 1. 检查标签（TODO/FIX等）
		if link.tag and line:match("%[" .. link.tag .. "%]") then
			score = score + 40
		end

		-- 2. 检查内容哈希
		if link.content_hash then
			local line_hash = calculate_content_hash(line)
			if line_hash == link.content_hash then
				score = score + 50
			end
		end

		-- 3. 检查行内容
		if link.content and line:match(link.content:sub(1, 20)) then
			score = score + 30
		end

		-- 4. 行号接近度（如果原有行号有效）
		if link.line and link.line > 0 then
			local distance = math.abs(line_num - link.line)
			if distance < CONFIG.SCAN_WINDOW then
				score = score + math.max(0, 20 - distance)
			end
		end

		-- 更新最佳匹配
		if score > best_score then
			best_score = score
			best_match = line_num
		end
	end

	-- 只有达到阈值才认为匹配成功
	if best_match and best_score >= CONFIG.SIMILARITY_THRESHOLD then
		return best_match
	end

	return nil
end

---------------------------------------------------------------------
-- 定位策略3：上下文匹配
---------------------------------------------------------------------
function M._locate_by_context(filepath, link)
	if not link.context then
		return nil
	end

	local lines = read_file_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_match = nil
	local best_similarity = 0

	-- 在附近区域搜索（如果原有行号有效）
	local search_start, search_end

	if link.line and link.line > 0 then
		-- 以原有行号为中心，在附近搜索
		search_start = math.max(1, link.line - CONFIG.CONTEXT_SEARCH_RADIUS)
		search_end = math.min(#lines, link.line + CONFIG.CONTEXT_SEARCH_RADIUS)
	else
		-- 没有行号，搜索整个文件
		search_start = 1
		search_end = math.min(#lines, CONFIG.MAX_SCAN_LINES)
	end

	for line_num = search_start, search_end do
		-- 构建该行的上下文
		local prev_line = line_num > 1 and lines[line_num - 1] or ""
		local curr_line = lines[line_num]
		local next_line = line_num < #lines and lines[line_num + 1] or ""

		local candidate_context = context.build(prev_line, curr_line, next_line)

		-- 计算相似度
		local similarity = calculate_context_similarity(link.context, candidate_context)

		if similarity > best_similarity and similarity >= CONFIG.CONTEXT_SIMILARITY_THRESHOLD then
			best_similarity = similarity
			best_match = {
				line = line_num,
				similarity = similarity,
				context = candidate_context,
			}
		end

		-- 如果找到足够好的匹配，提前退出
		if best_similarity >= 95 then
			break
		end
	end

	return best_match
end

---------------------------------------------------------------------
-- 主定位函数（整合所有策略）
---------------------------------------------------------------------
function M.locate_task(link)
	if not link or not link.path or not link.id then
		return link
	end

	local filepath = link.path

	-- 检查文件是否存在
	if vim.fn.filereadable(filepath) ~= 1 then
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "文件不存在"
		return link
	end

	-- 读取文件内容
	local lines = read_file_lines(filepath)

	-- 检查当前行号是否仍然有效
	if link.line and link.line >= 1 and link.line <= #lines then
		local current_line = lines[link.line]
		if find_id_in_line(current_line, link.id) then
			-- 行号仍然有效，验证上下文（如果存在）
			if link.context then
				local new_context = build_context_fingerprint(filepath, link.line)
				if new_context then
					local similarity = calculate_context_similarity(link.context, new_context)
					link.context_matched = similarity >= CONFIG.CONTEXT_SIMILARITY_THRESHOLD
					link.context_similarity = similarity

					if similarity >= 90 then
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

	-- 开始重新定位
	local new_line = nil
	local used_strategy = nil
	local context_match = nil

	-- 策略1：尝试通过ID精确匹配
	new_line = M._locate_by_id(filepath, link.id)
	if new_line then
		used_strategy = "id_match"
	end

	-- 策略2：如果ID匹配失败，尝试内容和标签匹配
	if not new_line then
		new_line = M._locate_by_content(filepath, link)
		if new_line then
			used_strategy = "content_match"
		end
	end

	-- 策略3：如果前两种策略失败，尝试上下文匹配
	if not new_line and link.context then
		context_match = M._locate_by_context(filepath, link)
		if context_match then
			new_line = context_match.line
			used_strategy = "context_match"
		end
	end

	-- 更新链接
	if new_line and new_line ~= link.line then
		link.line = new_line
		link.line_verified = true
		link.last_verified_at = os.time()
		link.updated_at = os.time()

		-- 更新内容哈希
		if lines[new_line] then
			link.content_hash = calculate_content_hash(lines[new_line])
		end

		-- 更新上下文信息
		if context_match then
			link.context_matched = true
			link.context_similarity = context_match.similarity
			link.context = context_match.context
			link.context_updated_at = os.time()
		else
			-- 重新构建上下文
			local new_context = build_context_fingerprint(filepath, new_line)
			if new_context then
				link.context = new_context
				link.context_updated_at = os.time()
			end
		end

		-- 记录修复日志
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
		-- 保持原行号但标记为未验证
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "无法重新定位链接"
	else
		-- 完全没有行号信息
		link.line_verified = false
		link.verification_failed_at = os.time()
		link.verification_note = "缺少行号信息"
	end

	return link
end

---------------------------------------------------------------------
-- 上下文管理功能
---------------------------------------------------------------------
--- 更新链接的上下文信息
--- @param link table 链接对象
--- @return table 更新后的链接
function M.update_context(link)
	if not link or not link.path or not link.line then
		return link
	end

	local new_context = build_context_fingerprint(link.path, link.line)
	if new_context then
		link.context = new_context
		link.context_updated_at = os.time()
		link.updated_at = os.time()
	end

	return link
end

--- 批量更新文件中的链接上下文（同时更新TODO和代码链接）
--- @param filepath string 文件路径
--- @return table 更新报告
function M.update_file_contexts(filepath)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")

	local result = {
		updated = 0,
		total = 0,
	}

	-- 更新TODO链接
	local todo_links = index.find_todo_links_by_file(filepath)
	for _, todo_link in ipairs(todo_links) do
		result.total = result.total + 1

		local updated = M.update_context(todo_link)
		if updated.context then
			store.set_key("todo.links.todo." .. todo_link.id, updated)
			result.updated = result.updated + 1
		end
	end

	-- 更新代码链接
	local code_links = index.find_code_links_by_file(filepath)
	for _, code_link in ipairs(code_links) do
		result.total = result.total + 1

		local updated = M.update_context(code_link)
		if updated.context then
			store.set_key("todo.links.code." .. code_link.id, updated)
			result.updated = result.updated + 1
		end
	end

	return result
end

--- 获取上下文匹配统计
--- @return table 统计信息
function M.get_context_stats()
	local link = require("todo2.store.link")

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local stats = {
		total_links_with_context = 0,
		context_matched_links = 0,
		context_similarity_avg = 0,
		total_links = 0,
	}

	local total_similarity = 0

	-- 统计TODO链接
	for _, todo_link in pairs(all_todo) do
		stats.total_links = stats.total_links + 1

		if todo_link.context then
			stats.total_links_with_context = stats.total_links_with_context + 1
		end

		if todo_link.context_matched then
			stats.context_matched_links = stats.context_matched_links + 1
		end

		if todo_link.context_similarity then
			total_similarity = total_similarity + todo_link.context_similarity
		end
	end

	-- 统计代码链接
	for _, code_link in pairs(all_code) do
		stats.total_links = stats.total_links + 1

		if code_link.context then
			stats.total_links_with_context = stats.total_links_with_context + 1
		end

		if code_link.context_matched then
			stats.context_matched_links = stats.context_matched_links + 1
		end

		if code_link.context_similarity then
			total_similarity = total_similarity + code_link.context_similarity
		end
	end

	-- 计算平均相似度
	if stats.context_matched_links > 0 then
		stats.context_similarity_avg = math.floor(total_similarity / stats.context_matched_links)
	end

	return stats
end

---------------------------------------------------------------------
-- 批量定位
---------------------------------------------------------------------
function M.locate_file_tasks(filepath)
	local index = require("todo2.store.index")
	local store = require("todo2.store.nvim_store")
	local types = require("todo2.store.types")

	-- 收集所有链接
	local links = {}

	local todo_links = index.find_todo_links_by_file(filepath)
	for _, link in ipairs(todo_links) do
		table.insert(links, link)
	end

	local code_links = index.find_code_links_by_file(filepath)
	for _, link in ipairs(code_links) do
		table.insert(links, link)
	end

	-- 定位每个链接
	local located = 0
	for _, link in ipairs(links) do
		local old_line = link.line
		local located_link = M.locate_task(link)

		if located_link.line ~= old_line then
			-- 保存更新
			local key_prefix = link.type == types.LINK_TYPES.TODO_TO_CODE and "todo.links.todo." or "todo.links.code."
			store.set_key(key_prefix .. link.id, located_link)
			located = located + 1
		end
	end

	return {
		located = located,
		total = #links,
	}
end

---------------------------------------------------------------------
-- 工具函数导出
---------------------------------------------------------------------
M.calculate_content_hash = calculate_content_hash

return M
