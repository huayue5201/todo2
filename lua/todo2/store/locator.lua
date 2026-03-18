-- lua/todo2/store/locator.lua
-- 定位模块：负责在文件中查找任务的具体位置
-- 注意：locate_task 函数即将废弃，请使用事件机制

local M = {}

local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id")
local core = require("todo2.store.link.core")
local hash = require("todo2.utils.hash")
local context = require("todo2.utils.context")

-- 警告记录
local warned = {}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---统一读取文件行
---@param filepath string 文件路径
---@return string[] 行数组
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

---统一判断某行是否包含 ID
---@param line string 行内容
---@param id string 任务ID
---@return boolean
local function line_contains_id(line, id)
	if not line or not id then
		return false
	end
	if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
		return true
	end
	if id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id then
		return true
	end
	return false
end

---安全截取 UTF-8 前缀
---@param text string 文本
---@param max_chars number 最大字符数
---@return string? 截取后的文本
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

---通过ID定位行号
---@param filepath string 文件路径
---@param id string 任务ID
---@return number? 行号
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

---通过内容定位行号
---@param filepath string 文件路径
---@param link table 链接信息
---@return number? 行号
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

		if link.tag and line:match("%[" .. link.tag .. "%]") then
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

---通过上下文指纹定位（同步）
---@param filepath string 文件路径
---@param stored_context table 存储的上下文
---@param threshold? number 相似度阈值，默认70
---@return { line: number, similarity: number }? 定位结果
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

---异步上下文定位
---@param link table 链接信息
---@param callback function 回调函数，参数为定位结果或nil
function M.locate_by_context(link, callback)
	if not callback then
		return
	end
	if not link or not link.context then
		return callback(nil)
	end

	local lines = read_lines(link.path)
	if #lines == 0 then
		return callback(nil)
	end

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	local best = { line = nil, similarity = 0 }
	local total = #lines
	local i = 1
	local threshold = 70

	local function scan()
		for _ = 1, 50 do
			if i > total then
				vim.api.nvim_buf_delete(temp_buf, { force = true })
				if best.line and best.similarity >= threshold then
					return callback(best)
				else
					return callback(nil)
				end
			end

			local ctx = context.build_from_buffer(temp_buf, i, link.path)
			if ctx then
				local sim = context.similarity(link.context, ctx)
				if sim > best.similarity then
					best.line = i
					best.similarity = sim
				end
				if sim >= threshold then
					vim.api.nvim_buf_delete(temp_buf, { force = true })
					return callback(best)
				end
			end

			i = i + 1
		end

		vim.defer_fn(scan, 1)
	end

	scan()
end

---异步rg搜索文件
---@param id string 任务ID
---@param callback function 回调函数，参数为文件路径或nil
function M.async_search_file_by_id(id, callback)
	if not callback then
		return
	end
	if not id or id == "" then
		return callback(nil)
	end

	local project_root = require("todo2.store.meta").get_project_root()
	local rg = "rg -l -m 1 -i --no-ignore -u -e "
		.. id_utils.escape_for_rg(id_utils.format_todo_anchor(id))
		.. " -e "
		.. id_utils.escape_for_rg(id_utils.REF_SEPARATOR .. id)
		.. " "
		.. project_root

	local done = false

	vim.fn.jobstart(rg, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if done then
				return
			end
			if data and data[1] and data[1] ~= "" then
				done = true
				callback(data[1])
			end
		end,
		on_exit = function()
			if not done then
				done = true
				callback(nil)
			end
		end,
	})
end

---内部定位函数
---@param link table 链接信息
---@return number? 行号
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
-- 主定位函数
---------------------------------------------------------------------

---同步定位（返回定位后的 link 对象）
---@param link table 链接信息
---@return table? 更新后的link对象
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

---⚠️ 异步定位（即将废弃）- 请使用事件机制
---@deprecated
---@param link table 链接信息
---@param callback? function 回调函数
---@return table? 定位结果
function M.locate_task(link, callback)
	-- 弃用警告
	if not warned.locate_task then
		vim.notify(
			"[todo2] locate_task is deprecated and will be removed in future versions. "
				.. "Please use locate_task_sync + events mechanism instead.",
			vim.log.levels.WARN
		)
		warned.locate_task = true
	end

	local result = M.locate_task_sync(link)

	if result then
		-- 更新内部格式（保持原有功能以兼容旧代码）
		local task = core.get_task(result.id)
		if task then
			if result.type == "todo_to_code" and task.locations.todo then
				task.locations.todo.line = result.line
				task.verification.line_verified = true
				task.verification.last_verified_at = os.time()
				task.timestamps.updated = os.time()
				core.save_task(result.id, task)
			elseif result.type == "code_to_todo" and task.locations.code then
				task.locations.code.line = result.line
				task.verification.line_verified = true
				task.verification.last_verified_at = os.time()
				task.timestamps.updated = os.time()
				core.save_task(result.id, task)
			end
		end
	end

	if callback then
		callback(result)
	end

	return result
end

return M
