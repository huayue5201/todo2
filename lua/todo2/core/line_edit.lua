-- lua/todo2/core/line_edit.lua
-- 批量改行：按文件收集编辑，提交时每个文件只写一次 buffer、只落盘一次、只同步一次。
--
-- 为什么需要：删除/移动/状态写回都是「一次操作改很多行」，逐行 set_lines 会让行号
-- 在循环里漂移（调用方被迫倒序排序兜底），也让 undo 变成 N 步、sync 变成 N 次。
-- 这里统一成「先算好新内容，再一次性写入」。
--
-- 编辑按 1-based 行号描述：从 lnum 开始删 count 行，再插入 lines。
--   replace: { path, lnum, count = 1, lines = { new_line } }
--   delete:  { path, lnum, count = n }
--   insert:  { path, lnum, count = 0, lines = { ... } }

local M = {}

---@class todo2.LineEdit
---@field path string 文件路径
---@field lnum integer 1-based 行号（插入时插入到该行之前）
---@field count? integer 删除/替换的行数，缺省 0（纯插入）
---@field lines? string[] 插入的新行，缺省 {}

---把一个文件上的编辑应用到行数组（按行号倒序，互不影响）
---@param lines string[]
---@param edits todo2.LineEdit[]
---@return string[]
local function apply_to_lines(lines, edits)
	table.sort(edits, function(a, b)
		return a.lnum > b.lnum
	end)

	for _, edit in ipairs(edits) do
		local lnum = edit.lnum
		if lnum >= 1 and lnum <= #lines + 1 then
			for _ = 1, edit.count or 0 do
				if lines[lnum] then
					table.remove(lines, lnum)
				end
			end
			local insert = edit.lines or {}
			for i = #insert, 1, -1 do
				table.insert(lines, lnum, insert[i])
			end
		end
	end
	return lines
end

---立即落盘（TODO 文件改完必须马上与磁盘一致：store 已经先改了）
---写入是我们自己算好的完整行，BufWritePre 的防抖同步与正文规整都不该再跑一遍
---@param bufnr number
local function save(bufnr)
	pcall(function()
		vim.b[bufnr].todo2_programmatic_write = true
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("silent! write!")
		end)
	end)
	vim.b[bufnr].todo2_programmatic_write = nil
end

---提交一批编辑。
---@param edits todo2.LineEdit[]
---@param opts? { sync?: boolean } sync 缺省 true；false 时由调用方自己同步
---@return string[] touched 被改写的文件（按首次出现的顺序）
function M.apply(edits, opts)
	opts = opts or {}

	local order, by_path = {}, {}
	for _, edit in ipairs(edits) do
		if edit.path and edit.path ~= "" then
			local bucket = by_path[edit.path]
			if not bucket then
				bucket = {}
				by_path[edit.path] = bucket
				order[#order + 1] = edit.path
			end
			bucket[#bucket + 1] = edit
		end
	end

	for path, list in pairs(by_path) do
		local bufnr = vim.fn.bufadd(path)
		require("todo2.utils.buffer").ensure_loaded(bufnr)
		if vim.api.nvim_buf_is_valid(bufnr) then
			local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local after = apply_to_lines(vim.deepcopy(before), list)
			if not vim.deep_equal(before, after) then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, after)
				save(bufnr)
			end
		end
	end

	if opts.sync ~= false then
		for _, path in ipairs(order) do
			pcall(require("todo2.core.sync").sync_todo_file, path)
		end
	end

	return order
end

return M
