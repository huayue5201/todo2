-- lua/todo2/ui/input.lua
--- @module todo2.ui.input
--- @brief 浮动窗口多行输入组件（适配自 marker-groups）

local M = {}
local config = require("todo2.config")

--- 显示多行输入浮窗
--- @param opts table 选项
---   - title: string 窗口标题
---   - default: string 默认内容
---   - max_chars: number|nil 最大字符数（默认从配置获取）
---   - width: number|nil 窗口宽度（默认60）
---   - height: number|nil 窗口高度（默认10）
--- @param callback function 回调函数，参数为输入字符串（取消则为nil）
function M.prompt_multiline(opts, callback)
	opts = opts or {}
	local title = opts.title or "Edit Task"
	local default = opts.default or ""
	local max_chars = opts.max_chars or config.get("task_content_max_length") or 1000
	local width = opts.width or 60
	local height = opts.height or 10

	-- 创建编辑缓冲区
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "text", { buf = buf })

	-- 拆分默认内容为行
	local lines = {}
	for line in (default .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	if #lines == 0 then
		lines = { default }
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- 计算窗口位置
	local columns = vim.o.columns
	local lines_screen = vim.o.lines
	local content_height = math.max(3, height - 1)

	-- 主编辑窗口
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = content_height,
		col = math.floor((columns - width) / 2),
		row = math.floor((lines_screen - height) / 2) - 2,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		zindex = 200,
	})
	vim.api.nvim_set_option_value("wrap", true, { win = win })

	-- 底部帮助栏（独立窗口）
	local footer_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = footer_buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = footer_buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = footer_buf })

	local footer_win = vim.api.nvim_open_win(footer_buf, false, {
		relative = "editor",
		width = width,
		height = 1,
		col = math.floor((columns - width) / 2),
		row = math.floor((lines_screen - height) / 2) + content_height,
		style = "minimal",
		border = "rounded",
		title = " Help ",
		title_pos = "center",
		focusable = false,
		zindex = 201,
	})

	-- 设置帮助栏文本
	local function render_footer()
		vim.api.nvim_set_option_value("modifiable", true, { buf = footer_buf })
		local hint = "  Ctrl+Enter = Save    Esc/Q = Cancel"
		vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { hint })

		-- 使用 extmark 替代废弃的 nvim_buf_add_highlight
		local ns = vim.api.nvim_create_namespace("todo2_input_footer")
		vim.api.nvim_buf_clear_namespace(footer_buf, ns, 0, -1)

		-- 修正：end_col 必须为有效列索引（0-based，字节长度）
		local end_col = #hint -- 整行的字节长度
		vim.api.nvim_buf_set_extmark(footer_buf, ns, 0, 0, {
			hl_group = "Todo2InputHint",
			end_col = end_col,
			hl_eol = true, -- 确保高亮延伸到行尾（即使行内包含多字节字符也能正确显示）
		})

		vim.api.nvim_set_option_value("modifiable", false, { buf = footer_buf })
	end
	vim.cmd("highlight default link Todo2InputHint Comment")
	render_footer()

	-- 确保帮助栏在编辑器调整大小时跟随
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		callback = function()
			if footer_win and vim.api.nvim_win_is_valid(footer_win) then
				pcall(vim.api.nvim_win_set_config, footer_win, {
					relative = "editor",
					width = width,
					height = 1,
					col = math.floor((columns - width) / 2),
					row = math.floor((lines_screen - height) / 2) + content_height,
				})
			end
		end,
	})

	-- 状态标记，防止重复回调
	local completed = false
	local function finalize(result)
		if completed then
			return
		end
		completed = true
		-- 关闭窗口
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if footer_win and vim.api.nvim_win_is_valid(footer_win) then
			pcall(vim.api.nvim_win_close, footer_win, true)
		end
		callback(result)
	end

	-- 窗口关闭时触发取消
	vim.api.nvim_create_autocmd("WinClosed", {
		once = true,
		callback = function()
			finalize(nil)
		end,
		buffer = buf,
	})

	-- 按键绑定
	-- 取消
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", {
		noremap = true,
		silent = true,
		callback = function()
			finalize(nil)
		end,
	})
	vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
		noremap = true,
		silent = true,
		callback = function()
			finalize(nil)
		end,
	})
	vim.api.nvim_buf_set_keymap(buf, "i", "<C-c>", "", {
		noremap = true,
		silent = true,
		callback = function()
			finalize(nil)
		end,
	})

	-- 保存
	local function submit()
		local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local joined = table.concat(all_lines, "\n")
		local limited = vim.fn.strcharpart(joined, 0, max_chars)
		finalize(limited)
	end
	vim.api.nvim_buf_set_keymap(buf, "n", "<C-CR>", "", { noremap = true, silent = true, callback = submit })
	vim.api.nvim_buf_set_keymap(buf, "i", "<C-CR>", "", { noremap = true, silent = true, callback = submit })
	vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", { noremap = true, silent = true, callback = submit })

	-- 自动进入插入模式，光标定位到内容末尾
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_set_current_win, win)

			local line_count = vim.api.nvim_buf_line_count(buf)
			if line_count > 0 then
				local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
				local col = #last_line
				vim.api.nvim_win_set_cursor(win, { line_count, col })
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
			else
				vim.cmd("startinsert")
			end
		end
	end)
end

return M
