-- lua/todo2/autofix/locator.lua
-- 定位模块：分析任务状态并返回修复建议

local M = {}
local id_utils = require("todo2.utils.id")
local code_block = require("todo2.code_block")

---------------------------------------------------------------------
-- 辅助函数
---------------------------------------------------------------------

--- 检查行是否包含指定ID
---@param line string
---@param id string
---@return boolean
local function line_contains_id(line, id)
	if not line or not id then
		return false
	end
	if id_utils.contains_code_mark(line) then
		return id_utils.extract_id_from_code_mark(line) == id
	end
	return false
end

--- 通过签名在文件中查找代码块
---@param bufnr number
---@param block_info table
---@return table|nil
local function find_block_by_signature(bufnr, block_info)
	if not block_info or not block_info.signature_hash then
		return nil
	end

	local blocks = code_block.get_all_blocks(bufnr)
	for _, block in ipairs(blocks) do
		if block.signature_hash == block_info.signature_hash then
			return block
		end
	end
	return nil
end

--- 在代码块中查找标记行
---@param bufnr number
---@param block table
---@param task_id string
---@return number|nil
local function find_mark_in_block(bufnr, block, task_id)
	local start_line = block.start_line
	local end_line = block.end_line

	for line = start_line, end_line do
		local line_content = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
		if line_content and line_contains_id(line_content, task_id) then
			return line
		end
	end

	return nil
end

--- 验证存储的代码块是否仍然存在
---@param ctx LocateContext
---@return table|nil found_block, boolean exists_in_file
local function verify_stored_block_exists(ctx)
	if not ctx.block_info then
		return nil, false
	end

	-- 1. 先在存储行号上检查
	local block_at_line = code_block.get_block_at_line(ctx.bufnr, ctx.stored_line)
	if block_at_line and block_at_line.signature_hash == ctx.block_info.signature_hash then
		return block_at_line, true
	end

	-- 2. 在整个文件中搜索
	local found_block = find_block_by_signature(ctx.bufnr, ctx.block_info)
	if found_block then
		return found_block, true
	end

	return nil, false
end

---------------------------------------------------------------------
-- 状态检测
---------------------------------------------------------------------

---@class LocateContext
---@field lines string[]
---@field bufnr number
---@field task table
---@field location table
---@field block_info table|nil
---@field stored_line number
---@field task_id string

--- 检测当前状态（增强版）
---@param ctx LocateContext
---@return string state, table|nil current_block, table|nil stored_block
local function detect_state(ctx)
	local stored_line = ctx.stored_line
	local lines = ctx.lines
	local task_id = ctx.task_id

	-- 1. 检查存储行号上的标记
	local mark_exists = stored_line >= 1 and stored_line <= #lines and line_contains_id(lines[stored_line], task_id)

	-- 2. 获取当前行上的代码块
	local current_block = code_block.get_block_at_line(ctx.bufnr, stored_line)

	-- 3. 验证存储的代码块是否还存在
	local stored_block, stored_block_exists = verify_stored_block_exists(ctx)

	-- 4. 判断当前块是否匹配存储的块
	local current_block_matches_stored = current_block
		and stored_block
		and current_block.signature_hash == stored_block.signature_hash

	-- 5. 状态判断
	if mark_exists then
		if current_block_matches_stored then
			return "both_exist", current_block, stored_block
		else
			if stored_block_exists then
				return "mark_exists_block_moved", current_block, stored_block
			else
				return "mark_exists_block_deleted", current_block, nil
			end
		end
	end

	if not mark_exists then
		if current_block_matches_stored then
			return "mark_missing_block_exists", current_block, stored_block
		else
			if stored_block_exists then
				return "both_missing_block_relocated", nil, stored_block
			else
				return "both_missing", nil, nil
			end
		end
	end

	return "both_missing", nil, nil
end

---------------------------------------------------------------------
-- 处理函数
---------------------------------------------------------------------

--- 场景1: 标记存在，代码块移动（存储块在其他位置）
---@param stored_block table 存储的代码块（一定存在）
---@param task_id string 任务ID
---@param bufnr number 缓冲区号
---@return table
local function handle_mark_exists_block_moved(stored_block, task_id, bufnr)
	local mark_line = find_mark_in_block(bufnr, stored_block, task_id)

	if mark_line then
		return {
			action = "relocate",
			new_line = mark_line,
			new_block = stored_block,
			method = "block_moved",
			confidence = 90,
		}
	else
		return {
			action = "restore_mark",
			block = stored_block,
			line = stored_block.start_line,
			method = "restore_mark_in_moved_block",
			confidence = 85,
		}
	end
end

--- 场景1b: 标记存在，但代码块被删除/重命名
---@param current_block table|nil 当前代码块
---@return table
local function handle_mark_exists_block_deleted(current_block)
	return {
		action = "mark_orphaned",
		current_block = current_block,
		reason = "stored_block_deleted",
		method = "block_deleted",
		confidence = 60,
	}
end

--- 场景2: 标记缺失，代码块还在
---@param current_block table 当前代码块（一定存在）
---@param task_id string 任务ID
---@param bufnr number 缓冲区号
---@return table
local function handle_mark_missing_block_exists(current_block, task_id, bufnr)
	local mark_line = find_mark_in_block(bufnr, current_block, task_id)

	if mark_line then
		return {
			action = "update_location",
			new_line = mark_line,
			block = current_block,
			method = "mark_relocated",
			confidence = 95,
		}
	else
		return {
			action = "restore_mark",
			block = current_block,
			line = current_block.start_line,
			method = "restore_missing_mark",
			confidence = 90,
		}
	end
end

--- 场景3: 都缺失，但存储块在其他位置
---@param stored_block table 存储的代码块（一定存在）
---@param task_id string 任务ID
---@param bufnr number 缓冲区号
---@return table
local function handle_both_missing_block_relocated(stored_block, task_id, bufnr)
	local mark_line = find_mark_in_block(bufnr, stored_block, task_id)

	if mark_line then
		return {
			action = "relocate",
			new_line = mark_line,
			new_block = stored_block,
			method = "block_relocated",
			confidence = 85,
		}
	else
		return {
			action = "restore_mark",
			block = stored_block,
			line = stored_block.start_line,
			method = "restore_mark_in_relocated_block",
			confidence = 80,
		}
	end
end

--- 场景4: 都缺失（代码块完全消失）
---@param task table 任务对象
---@return table
local function handle_both_missing(task)
	local todo_location = task.locations.todo
	if todo_location then
		return {
			action = "mark_orphaned",
			reason = "code_block_deleted",
			method = "code_block_deleted",
			confidence = 100,
		}
	else
		return {
			action = "delete_task",
			reason = "both_missing",
			method = "task_obsolete",
			confidence = 100,
		}
	end
end

--- 场景5: 都正常
---@param current_block table 当前代码块（一定存在）
---@param stored_block table|nil 存储的代码块
---@return table
local function handle_both_exist(current_block, stored_block)
	if stored_block and current_block.signature_hash ~= stored_block.signature_hash then
		return {
			action = "update_context",
			block = current_block,
			method = "context_updated",
			confidence = 95,
		}
	end

	return {
		action = "no_change",
		method = "valid",
		confidence = 100,
	}
end

---------------------------------------------------------------------
-- 公开接口
---------------------------------------------------------------------

--- 定位任务并返回修复建议
---@param task table 任务对象
---@param location_type "todo"|"code"
---@return table
function M.locate(task, location_type)
	if not task or not task.id then
		return { action = "error", reason = "invalid_task" }
	end

	local location = task.locations and task.locations[location_type]
	if not location or not location.path then
		return { action = "error", reason = "no_location" }
	end

	-- 读取文件
	local filepath = location.path
	local lines = vim.fn.readfile(filepath) or {}
	if #lines == 0 then
		return { action = "error", reason = "file_not_found" }
	end

	-- 加载缓冲区
	local bufnr = vim.fn.bufadd(filepath)
	vim.fn.bufload(bufnr)

	-- 准备上下文
	local ctx = {
		lines = lines,
		bufnr = bufnr,
		task = task,
		location = location,
		block_info = location_type == "code" and location.context and location.context.code_block_info or nil,
		stored_line = location.line,
		task_id = task.id,
	}

	-- 检测状态
	local state, current_block, stored_block = detect_state(ctx)

	-- 根据状态处理
	if state == "both_exist" then
		return handle_both_exist(current_block, stored_block)
	elseif state == "mark_exists_block_moved" then
		return handle_mark_exists_block_moved(stored_block, ctx.task_id, ctx.bufnr)
	elseif state == "mark_exists_block_deleted" then
		return handle_mark_exists_block_deleted(current_block)
	elseif state == "mark_missing_block_exists" then
		return handle_mark_missing_block_exists(current_block, ctx.task_id, ctx.bufnr)
	elseif state == "both_missing_block_relocated" then
		return handle_both_missing_block_relocated(stored_block, ctx.task_id, ctx.bufnr)
	else -- both_missing
		return handle_both_missing(ctx.task)
	end
end

return M
