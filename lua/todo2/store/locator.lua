-- lua/todo2/store/locator.lua
-- 定位模块：负责在文件中查找任务的具体位置（仅支持 TAG:ref:ID）
local M = {}

local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core")
local hash = require("todo2.utils.hash")
local context = require("todo2.utils.context")

local warned = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 读取文件所有行（带缓存）
---@param filepath string
---@return string[]
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

--- 判断某行是否包含指定 ID（仅支持 TAG:ref:ID）
---@param line string
---@param id string
---@return boolean
local function line_contains_id(line, id)
	if not line or not id then
		return false
	end

	if id_utils.contains_code_mark(line) then
		local extracted = id_utils.extract_id_from_code_mark(line)
		return extracted == id
	end

	return false
end

--- UTF-8 安全截取前缀
---@param text string
---@param max_chars number
---@return string?
local function utf8_prefix(text, max_chars)
	if not text or max_chars <= 0 then
		return nil
	end

	if vim and vim.str_byteindex then
		local ok, byte_idx = pcall(vim.str_byteindex, text, max_chars, true)
		if ok and byte_idx and byte_idx >= 1 then
			return text:sub(1, byte_idx)
		end
	end

	if #text <= max_chars then
		return text
	end
	return text:sub(1, max_chars)
end

---------------------------------------------------------------------
-- 定位函数
---------------------------------------------------------------------

--- 通过 ID 定位行号（TAG:ref:ID）
---@param filepath string
---@param id string
---@return number?
local function locate_by_id(filepath, id)
	if not id or id == "" then
		return nil
	end
	local lines = read_lines(filepath)
	for i, line in ipairs(lines) do
		if line_contains_id(line, id) then
			return i
		end
	end
	return nil
end

--- 通过内容定位行号（模糊匹配）
---@param filepath string
---@param link table
---@return number?
local function locate_by_content(filepath, link)
	local lines = read_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_score = 0
	local best_line = nil

	local content_prefix = nil
	if link.content and link.content ~= "" then
		content_prefix = utf8_prefix(link.content, 40)
	end

	for i, line in ipairs(lines) do
		local score = 0

		if link.tag and line:find(link.tag, 1, true) then
			score = score + 40
		end
		if link.content_hash and hash.hash(line) == link.content_hash then
			score = score + 50
		end
		if content_prefix and line:find(content_prefix, 1, true) then
			score = score + 30
		end

		if score > best_score then
			best_score = score
			best_line = i
		end
	end

	return best_line
end

--- 通过上下文指纹定位（同步）
---@param filepath string
---@param stored_context table
---@param threshold? number
---@return { line: number, similarity: number }?
function M.locate_by_context_fingerprint(filepath, stored_context, threshold)
	threshold = threshold or 70
	if not stored_context then
		return nil
	end

	local lines = read_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best = { line = nil, similarity = 0 }

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	for i = 1, #lines do
		local ctx = context.build_from_buffer(temp_buf, i, filepath)
		if ctx then
			local sim = context.similarity(stored_context, ctx)
			if sim > best.similarity then
				best.line = i
				best.similarity = sim
			end
			if sim >= threshold then
				break
			end
		end
	end

	vim.api.nvim_buf_delete(temp_buf, { force = true })

	if best.line and best.similarity >= threshold then
		return best
	end

	return nil
end

---------------------------------------------------------------------
-- 核心定位逻辑
---------------------------------------------------------------------

--- 内部定位函数（ID → 内容 → 上下文）
---@param link table
---@return number?
function M._locate_in_file(link)
	if not link or not link.path then
		return nil
	end

	local filepath = link.path
	local id = link.id
	local lines = read_lines(filepath)

	if #lines == 0 then
		return nil
	end

	-- 1. 行号验证
	if link.line and link.line >= 1 and link.line <= #lines then
		if id and line_contains_id(lines[link.line], id) then
			return link.line
		end
	end

	-- 2. ID 定位
	if id then
		local ln = locate_by_id(filepath, id)
		if ln then
			return ln
		end
	end

	-- 3. 内容定位
	local ln = locate_by_content(filepath, link)
	if ln then
		return ln
	end

	-- 4. 上下文定位
	if link.context then
		local ctx = M.locate_by_context_fingerprint(filepath, link.context)
		if ctx and ctx.line then
			return ctx.line
		end
	end

	return nil
end

---------------------------------------------------------------------
-- 对外接口
---------------------------------------------------------------------

--- 同步定位任务（返回更新后的 link）
---@param link table
---@return table?
function M.locate_task_sync(link)
	local ln = M._locate_in_file(link)
	if not ln then
		return nil
	end

	local updated = vim.deepcopy(link or {})
	updated.line = ln
	updated.line_verified = true
	updated.last_verified_at = os.time()
	return updated
end

--- ⚠️ 异步定位（已废弃）
---@deprecated
---@param link table
---@param callback? function
---@return table?
function M.locate_task(link, callback)
	if not warned.locate_task then
		vim.notify("[todo2] locate_task is deprecated and will be removed in future versions.", vim.log.levels.WARN)
		warned.locate_task = true
	end

	local result = M.locate_task_sync(link)

	if result then
		local task = core.get_task(result.id)
		if task then
			if result.type == "todo_to_code" and task.locations.todo then
				task.locations.todo.line = result.line
			elseif result.type == "code_to_todo" and task.locations.code then
				task.locations.code.line = result.line
			end
			task.verification.line_verified = true
			task.verification.last_verified_at = os.time()
			task.timestamps.updated = os.time()
			core.save_task(result.id, task)
		end
	end

	if callback then
		callback(result)
	end

	return result
end

return M
