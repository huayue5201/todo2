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
-- 1. ID 定位（最快路径）
---------------------------------------------------------------------
local function locate_by_id(filepath, id)
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

	for i, line in ipairs(lines) do
		local score = 0

		if link.tag and line:match("%[" .. link.tag .. "%]") then
			score = score + 40
		end
		if link.content_hash and hash.hash(line) == link.content_hash then
			score = score + 50
		end
		if link.content and line:find(link.content:sub(1, 20), 1, true) then
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
-- 3. 上下文定位（兼容旧接口）
---------------------------------------------------------------------
function M.locate_by_context_fingerprint(filepath, stored_context, threshold)
	threshold = threshold or 70
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

	if best.similarity >= threshold then
		return best
	end

	return nil
end

---------------------------------------------------------------------
-- 4. 异步上下文定位（兼容旧接口）
---------------------------------------------------------------------
function M.locate_by_context(filepath, link, callback)
	if not link.context or not callback then
		return callback(nil)
	end

	local lines = read_lines(filepath)
	if #lines == 0 then
		return callback(nil)
	end

	local temp_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(temp_buf, 0, -1, false, lines)

	local best = { line = nil, similarity = 0 }
	local total = #lines
	local i = 1

	local function scan()
		for _ = 1, 50 do
			if i > total then
				vim.api.nvim_buf_delete(temp_buf, { force = true })
				return callback(best.similarity >= 50 and best or nil)
			end

			local ctx = context.build_from_buffer(temp_buf, i, filepath)
			if ctx then
				local sim = context.similarity(link.context, ctx)
				if sim > best.similarity then
					best.line = i
					best.similarity = sim
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
---------------------------------------------------------------------
function M.async_search_file_by_id(id, callback)
	-- 保留旧接口，但内部简化
	local project_root = require("todo2.store.meta").get_project_root()
	local rg = "rg -l -m 1 -i --no-ignore -u -e "
		.. id_utils.escape_for_rg(id_utils.format_todo_anchor(id))
		.. " -e "
		.. id_utils.escape_for_rg(id_utils.REF_SEPARATOR .. id)
		.. " "
		.. project_root

	vim.fn.jobstart(rg, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if data and data[1] and data[1] ~= "" then
				callback(data[1])
			else
				callback(nil)
			end
		end,
		on_exit = function()
			callback(nil)
		end,
	})
end

---------------------------------------------------------------------
-- 6. 主定位函数（核心）
---------------------------------------------------------------------
function M._locate_in_file(link)
	local filepath = link.path
	local id = link.id
	local lines = read_lines(filepath)

	if #lines == 0 then
		return nil
	end

	-- 1. 行号验证
	if link.line and link.line >= 1 and link.line <= #lines then
		if line_contains_id(lines[link.line], id) then
			return link.line
		end
	end

	-- 2. ID 定位
	local ln = locate_by_id(filepath, id)
	if ln then
		return ln
	end

	-- 3. 内容定位
	ln = locate_by_content(filepath, link)
	if ln then
		return ln
	end

	-- 4. 上下文定位
	if link.context then
		local ctx = M.locate_by_context_fingerprint(filepath, link.context)
		if ctx then
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

	local updated = vim.deepcopy(link)
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
		if link.type == "todo_to_code" then
			link_mod.update_todo(link.id, result)
		else
			link_mod.update_code(link.id, result)
		end
	end

	if callback then
		callback(result)
	end

	return result
end

return M
