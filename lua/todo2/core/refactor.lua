-- lua/todo2/core/refactor.lua
-- 新版：基于轻量 AST 的结构级移动检测（完全不依赖行号 diff）

local M = {}

local parser = require("todo2.core.code_block_parser")
local matcher = require("todo2.core.block_matcher")
local move = require("todo2.store.link.move")

-- 保存旧内容快照
local last_content = {}

---------------------------------------------------------------------
-- 工具：获取缓冲区所有行
---------------------------------------------------------------------
local function get_buffer_lines(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---------------------------------------------------------------------
-- 保存快照（BufWritePre）
---------------------------------------------------------------------
function M.save_snapshot(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	last_content[bufnr] = get_buffer_lines(bufnr)
end

---------------------------------------------------------------------
-- 清除快照（BufWritePost）
---------------------------------------------------------------------
function M.clear_snapshot(bufnr)
	last_content[bufnr] = nil
end

---------------------------------------------------------------------
-- ⭐ 核心：结构级移动检测（AST diff）
---------------------------------------------------------------------
function M.detect_block_move(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local old_lines = last_content[bufnr]
	if not old_lines or #old_lines == 0 then
		return {}
	end

	local new_lines = get_buffer_lines(bufnr)

	-- 构建轻量 AST
	local old_ast = parser.parse(old_lines)
	local new_ast = parser.parse(new_lines)

	-- AST diff → 找到移动块
	local moves = matcher.detect_moves(old_ast, new_ast)

	return moves
end

---------------------------------------------------------------------
-- 应用检测到的移动（保持旧 API）
---------------------------------------------------------------------
function M.apply_detected_moves(bufnr, auto_confirm)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return { applied = 0, failed = {} }
	end

	local moves = vim.b[bufnr].detected_moves
	if not moves or #moves == 0 then
		return { applied = 0, failed = {} }
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return { applied = 0, failed = {} }
	end

	local result = { applied = 0, failed = {} }

	-- 用户确认
	if not auto_confirm then
		local msg = string.format("检测到 %d 个代码块移动，是否应用？", #moves)
		local choice = vim.fn.confirm(msg, "&Yes\n&No", 1)
		if choice ~= 1 then
			return result
		end
	end

	-- 应用每个移动
	for _, m in ipairs(moves) do
		local move_result = move.handle_block_move_within_file(path, m.old_start, m.old_end, m.new_start)

		result.applied = result.applied + #move_result.moved
		for _, id in ipairs(move_result.failed) do
			table.insert(result.failed, id)
		end
	end

	vim.b[bufnr].detected_moves = nil
	return result
end

---------------------------------------------------------------------
-- 手动扫描并修复（保持旧 API）
---------------------------------------------------------------------
function M.scan_and_fix_file(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return { relocated = 0, failed = {} }
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return { relocated = 0, failed = {} }
	end

	return move.relocate_file_tasks(path)
end

---------------------------------------------------------------------
-- 移动统计（保持旧 API）
---------------------------------------------------------------------
function M.get_move_stats(bufnr)
	local moves = vim.b[bufnr].detected_moves or {}
	local total_blocks = #moves
	local blocks_with_tasks = total_blocks -- AST diff 只返回含任务的块

	local total_lines = 0
	for _, m in ipairs(moves) do
		total_lines = total_lines + (m.old_end - m.old_start + 1)
	end

	return {
		total_blocks = total_blocks,
		total_lines = total_lines,
		blocks_with_tasks = blocks_with_tasks,
	}
end

return M
