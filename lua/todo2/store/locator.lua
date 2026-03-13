-- lua/todo2/store/locator.lua
-- 重写版：统一 scheduler + id_utils + link 中心
-- 保留所有旧接口，但内部逻辑已完全统一

local M = {}

local scheduler = require("todo2.render.scheduler")
local id_utils = require("todo2.utils.id")
local link_mod = require("todo2.store.link")
local hash = require("todo2.utils.hash")
local context = require("todo2.store.context")

---------------------------------------------------------------------
-- 工具：统一读取文件行（scheduler 是唯一真相源）
---------------------------------------------------------------------
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

---------------------------------------------------------------------
-- 工具：统一判断某行是否包含 ID
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 工具：安全截取 UTF-8 前缀（按字符数）
---------------------------------------------------------------------
local function utf8_prefix(text, max_chars)
	if not text or max_chars <= 0 then
		return nil
	end

	-- 尽量按“字符数”截断，避免截断到半个 UTF-8 字节序列
	if vim and vim.str_byteindex then
		local ok, byte_idx = pcall(vim.str_byteindex, text, max_chars, true)
		if ok and byte_idx and byte_idx >= 1 then
			return text:sub(1, byte_idx)
		end
	end

	-- 退化为普通字节截断（最坏情况）
	if #text <= max_chars then
		return text
	end
	return text:sub(1, max_chars)
end

---------------------------------------------------------------------
-- 1. ID 定位（最快路径）
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 2. 内容定位（次快路径）
---------------------------------------------------------------------
local function locate_by_content(filepath, link)
	local lines = read_lines(filepath)
	if #lines == 0 then
		return nil
	end

	local best_score = 0
	local best_line = nil

	-- 预先计算内容前缀，避免每行重复计算
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

---------------------------------------------------------------------
-- 3. 上下文定位（同步，兼容旧接口）
-- 返回：{ line = number, similarity = number } 或 nil
---------------------------------------------------------------------
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

	-- 用临时 buffer 构建上下文（保持兼容）
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
-- 4. 异步上下文定位（兼容旧接口）
-- callback(best | nil)，best 结构同上
---------------------------------------------------------------------
function M.locate_by_context(filepath, link, callback)
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

---------------------------------------------------------------------
-- 5. rg 搜索（兼容旧接口）
-- callback(filepath | nil)，保证只调用一次
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 6. 主定位函数（核心）
---------------------------------------------------------------------
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

	-- 1. 行号验证（最保守：只在该行仍然包含同一个 ID 时才信任）
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

	-- 4. 上下文定位（同步 fingerprint）
	if link.context then
		local ctx = M.locate_by_context_fingerprint(filepath, link.context)
		if ctx and ctx.line then
			return ctx.line
		end
	end

	return nil
end

---------------------------------------------------------------------
-- 7. 同步定位（不写回存储）
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 8. 异步定位（写回 link 中心）
---------------------------------------------------------------------
function M.locate_task(link, callback)
	local result = M.locate_task_sync(link)

	if result then
		-- 写回 link 中心（自动同步 TODO ↔ CODE）
		if result.type == "todo_to_code" then
			link_mod.update_todo(result.id, result)
		else
			link_mod.update_code(result.id, result)
		end
	end

	if callback then
		callback(result)
	end

	return result
end

return M
