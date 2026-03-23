-- lua/todo2/autofix/refactor.lua
-- 移动检测模块（基于 Treesitter）

local M = {}
local code_block = require("todo2.code_block")
local verification = require("todo2.autofix.verification")

local last_snapshot = {}

function M.save_snapshot(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	last_snapshot[bufnr] = code_block.get_all_blocks(bufnr)
end

function M.clear_snapshot(bufnr)
	last_snapshot[bufnr] = nil
end

function M.detect_block_move(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local old_blocks = last_snapshot[bufnr]
	if not old_blocks then
		return {}
	end

	local new_blocks = code_block.get_all_blocks(bufnr)
	if #new_blocks == 0 then
		return {}
	end

	local moves = {}
	local old_index = {}

	for _, block in ipairs(old_blocks) do
		if block.signature_hash then
			old_index[block.signature_hash] = block
		end
	end

	for _, new_block in ipairs(new_blocks) do
		if new_block.signature_hash and old_index[new_block.signature_hash] then
			local old_block = old_index[new_block.signature_hash]
			if old_block.start_line ~= new_block.start_line then
				table.insert(moves, {
					signature = new_block.signature,
					old_start = old_block.start_line,
					old_end = old_block.end_line,
					new_start = new_block.start_line,
					new_end = new_block.end_line,
				})
			end
		end
	end

	return moves
end

function M.apply_detected_moves(bufnr, auto_confirm)
	local moves = M.detect_block_move(bufnr)
	if #moves == 0 then
		return { applied = 0 }
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return { applied = 0 }
	end

	-- 触发验证，通知由 verification 自己处理
	verification.verify_file(path, nil)

	return { applied = 0, pending = true, total_moves = #moves }
end

return M
