-- lua/todo2/ui/init.lua
local M = {}

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local config = {
	float_reuse_strategy = "file",
}

---------------------------------------------------------------------
-- 初始化
---------------------------------------------------------------------
function M.setup(user_config)
	if user_config and user_config.ui then
		config = vim.tbl_deep_extend("force", config, user_config.ui)
	end
	return M
end

---------------------------------------------------------------------
-- open_todo_file（供 jumper.lua 调用）
---------------------------------------------------------------------
function M.open_todo_file(path, mode, line_number, opts)
	local ui_window = require("todo2.ui.window")
	opts = opts or {}

	local enter_insert = opts.enter_insert ~= false
	local reuse_strategy = opts.reuse_strategy or config.float_reuse_strategy

	-- 修复：正确展开路径
	path = vim.fs.normalize(path) -- 或 vim.fn.fnamemodify(vim.fn.expand(path), ":p")

	if vim.fn.filereadable(path) == 0 then
		vim.notify("TODO 文件不存在: " .. path, vim.log.levels.ERROR)
		return nil, nil
	end

	line_number = line_number or 1

	if mode == "float" then
		if reuse_strategy == "global" then
			return ui_window.find_or_create_global_float(path, line_number, enter_insert)
		elseif reuse_strategy == "file" then
			local existing_win = ui_window.find_existing_float(path)
			if existing_win then
				local bufnr = vim.api.nvim_win_get_buf(existing_win)
				vim.api.nvim_set_current_win(existing_win)
				vim.api.nvim_win_set_cursor(existing_win, { line_number, 0 })
				return bufnr, existing_win
			end
		end

		local bufnr, win = ui_window.show_floating(path, line_number, enter_insert)
		if bufnr then
			pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
		end
		return bufnr, win
	end

	if mode == "split" then
		local bufnr, win = ui_window.show_split(path, line_number, enter_insert)
		if bufnr then
			pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
		end
		return bufnr, win
	end

	local bufnr = ui_window.show_edit(path, line_number, enter_insert)
	local win = bufnr and vim.api.nvim_get_current_win() or nil
	if bufnr then
		pcall(vim.api.nvim_buf_set_var, bufnr, "todo2_file", true)
	end
	return bufnr, win
end
return M
