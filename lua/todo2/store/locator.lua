-- lua/todo2/store/locator.lua
-- 定位模块：负责在文件中查找任务的具体位置
---@module "todo2.store.locator"

local M = {}

local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core")
local hash = require("todo2.utils.hash")
local code_block = require("todo2.code_block")

-- 常量
local CONTEXT_SIMILARITY_THRESHOLD = 85 -- 上下文相似度阈值

local warned = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---读取文件所有行（带缓存）
---@param filepath string
---@return string[]
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

---判断某行是否包含指定 ID
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

---UTF-8 安全截取前缀
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
-- 基于签名的定位
---------------------------------------------------------------------

---通过函数签名定位
---@param filepath string
---@param block_info table 存储的代码块信息
---@return { line: number, block: table }?
local function locate_by_signature(filepath, block_info)
	if not block_info or not block_info.signature or block_info.signature == "" then
		return nil
	end

	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	-- 获取文件中所有代码块
	local blocks = code_block.get_all_blocks(bufnr)

	local best_match = nil
	local best_score = 0

	for _, block in ipairs(blocks) do
		local score = 0

		-- 1. 签名完全匹配
		if block.signature == block_info.signature then
			score = score + 100
		-- 2. 名称匹配
		elseif block.name == block_info.name then
			score = score + 50
		end

		-- 3. 类型匹配
		if block.type == block_info.type then
			score = score + 30
		end

		-- 4. 签名哈希匹配（快速匹配）
		if block.signature_hash and block.signature_hash == block_info.signature_hash then
			score = score + 80
		end

		if score > best_score then
			best_score = score
			best_match = block
		end

		-- 完全匹配直接返回
		if score >= 100 then
			break
		end
	end

	if best_match and best_score >= 50 then
		return {
			line = best_match.start_line,
			block = best_match,
		}
	end

	return nil
end

---通过行范围定位（使用存储的边界）
---@param filepath string
---@param block_info table
---@return { line: number, block: table }?
local function locate_by_range(filepath, block_info)
	if not block_info or not block_info.start_line or not block_info.end_line then
		return nil
	end

	local lines = read_lines(filepath)
	if #lines == 0 then
		return nil
	end

	-- 检查存储的行范围内是否有 TODO 标记
	for i = block_info.start_line, math.min(block_info.end_line, #lines) do
		if block_info.name then
			-- 查找包含函数名的行
			if lines[i] and lines[i]:find(block_info.name, 1, true) then
				return { line = i, block = nil }
			end
		end
	end

	return nil
end

---通过内容定位行号（模糊匹配）
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

---通过结构化上下文定位
---@param filepath string
---@param stored_context table 存储的结构化上下文
---@param threshold? number
---@return { line: number, similarity: number, block: table }?
local function locate_by_structured_context(filepath, stored_context, threshold)
	threshold = threshold or CONTEXT_SIMILARITY_THRESHOLD

	if not stored_context or not stored_context.code_block_info then
		return nil
	end

	local block_info = stored_context.code_block_info

	-- 1. 优先使用签名定位
	local result = locate_by_signature(filepath, block_info)
	if result then
		return {
			line = result.line,
			similarity = 100,
			block = result.block,
		}
	end

	-- 2. 使用行范围定位
	result = locate_by_range(filepath, block_info)
	if result then
		return {
			line = result.line,
			similarity = 80,
			block = result.block,
		}
	end

	-- 3. 降级：使用内容匹配
	local line = locate_by_content(filepath, { content = block_info.name, tag = block_info.type })
	if line then
		return {
			line = line,
			similarity = 60,
			block = nil,
		}
	end

	return nil
end

---------------------------------------------------------------------
-- 核心定位逻辑
---------------------------------------------------------------------

---内部定位函数（ID → 签名 → 内容 → 范围）
---@param link table
---@return table? { line: number, block: table? }
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
			return { line = link.line, block = nil }
		end
	end

	-- 2. ID 定位
	if id then
		for i, line in ipairs(lines) do
			if line_contains_id(line, id) then
				return { line = i, block = nil }
			end
		end
	end

	-- 3. 结构化上下文定位
	if link.context and link.context.code_block_info then
		local result = locate_by_structured_context(filepath, link.context)
		if result and result.line then
			return result
		end
	end

	-- 4. 内容定位（降级）
	local line = locate_by_content(filepath, link)
	if line then
		return { line = line, block = nil }
	end

	return nil
end

---------------------------------------------------------------------
-- 对外接口
---------------------------------------------------------------------

---同步定位任务（返回更新后的 link）
---@param link table
---@return table?
function M.locate_task_sync(link)
	local result = M._locate_in_file(link)
	if not result then
		return nil
	end

	local updated = vim.deepcopy(link or {})
	updated.line = result.line
	updated.line_verified = true
	updated.last_verified_at = os.time()

	-- 如果有新的代码块信息，更新到上下文
	if result.block and link.context and link.context.code_block_info then
		updated.context = vim.deepcopy(link.context)
		updated.context.code_block_info = result.block
		-- ❌ 删除 fingerprint 相关代码
	end

	return updated
end

---⚠️ 异步定位（已废弃）
---@deprecated 请使用 locate_task_sync
---@param link table
---@param callback? function
---@return table?
function M.locate_task(link, callback)
	if not warned.locate_task then
		vim.notify("[todo2] locate_task is deprecated, use locate_task_sync instead", vim.log.levels.WARN)
		warned.locate_task = true
	end

	local result = M.locate_task_sync(link)

	-- 如果定位成功，更新任务存储
	if result then
		local task = core.get_task(result.id)
		if task then
			-- 根据文件路径判断更新哪个位置
			if task.locations.todo and task.locations.todo.path == link.path then
				task.locations.todo.line = result.line
			elseif task.locations.code and task.locations.code.path == link.path then
				task.locations.code.line = result.line
				-- 更新上下文信息
				if result.context then
					task.locations.code.context = result.context
				end
			end

			task.verified = true
			task.timestamps = task.timestamps or {}
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
