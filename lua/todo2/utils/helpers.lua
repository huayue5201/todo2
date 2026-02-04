-- lua/todo2/keymaps/helpers.lua
--- @module todo2.keymaps.helpers
--- @brief 按键处理器的辅助函数

local M = {}

---------------------------------------------------------------------
-- 通用工具函数
---------------------------------------------------------------------

--- 获取当前缓冲区信息
--- @return table 包含缓冲区信息的表
function M.get_current_buffer_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = filename:match("%.todo%.md$")
	local is_float_window = false

	local win_id = vim.api.nvim_get_current_win()
	local config = vim.api.nvim_win_get_config(win_id)
	if config.relative ~= "" then
		is_float_window = true
	end

	return {
		bufnr = bufnr,
		win_id = win_id,
		filename = filename,
		is_todo_file = is_todo_file,
		is_float_window = is_float_window,
	}
end

---------------------------------------------------------------------
-- 行类型分析器
---------------------------------------------------------------------

--- 分析当前行的类型和内容
--- @return table 包含以下字段:
--   is_todo_task: 是否是TODO任务行 (- [ ] 或 - [x])
--   is_code_mark: 是否是代码标记行 (TAG:ref:id)
--   is_todo_mark: 是否是TODO标记行 ({#id})
--   is_mark: 是否是任意类型的标记行
--   id: 标记ID (如果存在)
--   tag: 标记标签 (如果存在, 仅限代码标记行)
--   line: 当前行内容
function M.analyze_current_line()
	local info = M.get_current_buffer_info()
	local line = vim.fn.getline(".")
	local result = {
		is_todo_task = false,
		is_code_mark = false,
		is_todo_mark = false,
		is_mark = false,
		id = nil,
		tag = nil,
		line = line,
		info = info,
	}

	-- 检查TODO任务行
	if info.is_todo_file and line:match("^%s*%- %[[ x]%]") then
		result.is_todo_task = true
	end

	-- 检查TODO标记行
	local todo_mark_id = line:match("{#(%w+)}")
	if todo_mark_id then
		result.is_todo_mark = true
		result.is_mark = true
		result.id = todo_mark_id
	end

	-- 检查代码标记行
	local code_tag, code_id = line:match("%s*(%u+):ref:(%w+)")
	if code_id then
		result.is_code_mark = true
		result.is_mark = true
		result.id = code_id
		result.tag = code_tag
	end

	return result
end

--- 分析指定行的类型和内容
--- @param bufnr integer 缓冲区号
--- @param lnum integer 行号
--- @return table 行分析结果
function M.analyze_line(bufnr, lnum)
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo_file = filename:match("%.todo%.md$")
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

	local result = {
		is_todo_task = false,
		is_code_mark = false,
		is_todo_mark = false,
		is_mark = false,
		id = nil,
		tag = nil,
		line = line,
		is_todo_file = is_todo_file,
	}

	-- 检查TODO任务行
	if is_todo_file and line:match("^%s*%- %[[ x]%]") then
		result.is_todo_task = true
	end

	-- 检查TODO标记行
	local todo_mark_id = line:match("{#(%w+)}")
	if todo_mark_id then
		result.is_todo_mark = true
		result.is_mark = true
		result.id = todo_mark_id
	end

	-- 检查代码标记行
	local code_tag, code_id = line:match("%s*(%u+):ref:(%w+)")
	if code_id then
		result.is_code_mark = true
		result.is_mark = true
		result.id = code_id
		result.tag = code_tag
	end

	return result
end

--- 分析多行的标记
--- @param bufnr integer 缓冲区号
--- @param start_lnum integer 起始行号
--- @param end_lnum integer 结束行号
--- @return table 多行分析结果
function M.analyze_lines(bufnr, start_lnum, end_lnum)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
	local results = {
		has_markers = false,
		ids = {},
		line_analyses = {},
	}

	for i, line in ipairs(lines) do
		local lnum = start_lnum + i - 1
		local analysis = M.analyze_line(bufnr, lnum)
		table.insert(results.line_analyses, analysis)

		if analysis.is_mark then
			results.has_markers = true
			if analysis.id then
				table.insert(results.ids, analysis.id)
			end
		end
	end

	return results
end

---------------------------------------------------------------------
-- 其他辅助函数
---------------------------------------------------------------------

--- 发送按键
--- @param keys string 按键序列
--- @param mode string 模式 (默认 "n")
function M.feedkeys(keys, mode)
	mode = mode or "n"
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), mode, false)
end

--- 安全关闭窗口
--- @param win_id integer 窗口ID
function M.safe_close_window(win_id)
	if vim.api.nvim_win_is_valid(win_id) then
		vim.api.nvim_win_close(win_id, true)
	end
end

return M
