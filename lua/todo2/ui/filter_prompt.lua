-- lua/todo2/ui/filter_prompt.lua
--- @brief 单行输入浮窗，带候选提示与 Tab 补全。
---
--- 抽屉里的 `f` 用它代替 vim.ui.input（后者不支持补全）：
---   ┌ Filter ────────────────────────────────────────────┐
---   │ tag:fix scope:tr                                   │
---   │   tag:fix  tag:frontend  scope:self  scope:tree     │
---   └────────────────────────────────────────────────────┘
--- Tab 补到公共前缀（只有一个候选则直接补全），Enter 提交，Esc 取消并还原。

local M = {}

local api = vim.api
local text = require("todo2.utils.text")

local HL_CANDIDATE = "Todo2FilterPromptCandidate"

local state = { buf = nil, win = nil, opts = nil, cycle = nil, written = nil }

local function ensure_hl()
	pcall(api.nvim_set_hl, 0, HL_CANDIDATE, { link = "Comment", default = true })
end

local function win_valid()
	return state.win ~= nil and api.nvim_win_is_valid(state.win)
end

local function buf_valid()
	return state.buf ~= nil and api.nvim_buf_is_valid(state.buf)
end

local function line_text()
	if not buf_valid() then
		return ""
	end
	return api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
end

--- 两个字符串的公共前缀
local function common_prefix(list)
	if #list == 0 then
		return ""
	end
	if #list == 1 then
		return list[1]
	end
	local prefix = list[1]
	for i = 2, #list do
		local other = list[i]
		local max = math.min(#prefix, #other)
		local j = 1
		while j <= max and prefix:sub(j, j) == other:sub(j, j) do
			j = j + 1
		end
		prefix = prefix:sub(1, j - 1)
	end
	return prefix
end

local function candidates()
	if not state.opts or not state.opts.complete then
		return {}, 1
	end
	local line = line_text()
	local col = 0
	if win_valid() then
		col = api.nvim_win_get_cursor(state.win)[2]
	end
	local prefix = line:sub(1, col)
	local items, from = state.opts.complete(prefix)
	return items, from
end

local function render_candidates()
	local items = candidates()
	local width = win_valid() and api.nvim_win_get_width(state.win) or 60
	local content
	if #items == 0 then
		content = ""
	else
		content = "  " .. table.concat(items, "  ")
		if text.width(content) > width then
			content = text.truncate(content, width, "…")
		end
	end
	if buf_valid() then
		api.nvim_buf_set_lines(state.buf, 1, 2, false, { content })
		api.nvim_buf_clear_namespace(state.buf, -1, 0, -1)
		local ns = api.nvim_create_namespace("todo2_filter_prompt")
		if content ~= "" then
			pcall(api.nvim_buf_set_extmark, state.buf, ns, 1, 0, { end_col = #content, hl_group = HL_CANDIDATE })
		end
	end
end

--- 关窗后必须回到普通模式：Neovim 关闭浮窗时不会自动 stopinsert，
--- 否则焦点回到底下的抽屉/TODO 文件时会带着插入态（那里本该只读）。
local function leave_insert()
	local mode = api.nvim_get_mode().mode
	if mode:sub(1, 1) == "i" or mode == "niI" or mode == "niR" or mode == "ic" then
		pcall(vim.cmd, "stopinsert")
	end
end

local function close_all()
	local buf = state.buf
	local win = state.win
	state.buf, state.win = nil, nil
	leave_insert()
	if win and api.nvim_win_is_valid(win) then
		pcall(api.nvim_win_close, win, true)
	end
	if buf and api.nvim_buf_is_valid(buf) then
		pcall(api.nvim_buf_delete, buf, { force = true })
	end
	-- 兜底：窗口关掉那一刻若还在插入态，等这一轮结束后再退一次
	vim.schedule(leave_insert)
end

function M.close()
	close_all()
	state.opts = nil
end

function M.is_open()
	return win_valid()
end

--- 接受补全，三档行为（保证每次按都有可见反馈）：
---   ① 只有一个候选 → 直接补全
---   ② 公共前缀比已输入的长 → 补到公共前缀（Vim 的老习惯）
---   ③ 否则就在候选之间循环：Tab 下一个、<S-Tab> 上一个
--- 空输入按 Tab 会补出第一个候选，不会像「按键没反应」。
--- 循环期间候选集合是冻结的：一旦补到一个具体值，实时计算的候选只剩它自己，
--- 若不冻结就永远轮不到下一个。
---@param direction integer 1 = 下一个，-1 = 上一个
local function accept(direction)
	local line = line_text()
	local col = api.nvim_win_get_cursor(state.win)[2]
	local fresh, from = candidates()
	local token = line:sub(from, col)
	local cycle = state.cycle
	local resuming = cycle ~= nil and cycle.from == from and cycle.token == token and cycle.items ~= nil
	local items = resuming and cycle.items or fresh
	if #items == 0 then
		return
	end

	local head = line:sub(1, from - 1)
	local tail = line:sub(col + 1)
	local target
	local prefix = common_prefix(items)
	if not resuming and #items == 1 then
		target = items[1]
		state.cycle = nil -- 单一候选补完即结束，不再算「正在循环」
	elseif not resuming and #prefix > #token then
		target = prefix
		state.cycle = nil
	else
		if not resuming then
			cycle = { from = from, token = token, items = items, index = 0 }
		end
		cycle.index = cycle.index + direction
		if cycle.index > #items then
			cycle.index = 1
		elseif cycle.index < 1 then
			cycle.index = #items
		end
		target = items[cycle.index]
		state.cycle = cycle
	end
	if target == token then
		return
	end
	state.written = head .. target .. tail
	api.nvim_buf_set_lines(state.buf, 0, 1, false, { state.written })
	api.nvim_win_set_cursor(state.win, { 1, #head + #target })
	-- 记住「我们刚写进去的是什么」，下一次 Tab 才知道可以接着循环
	if state.cycle then
		state.cycle.token = target
	end
	render_candidates()
end

--- 打开输入浮窗。
---@param opts { title: string?, default: string?, complete: function?, on_change: function?, on_submit: function, on_cancel: function? }
function M.open(opts)
	if win_valid() then
		M.close()
	end
	ensure_hl()
	state.opts = opts or {}

	local columns = vim.o.columns
	local width = math.max(30, math.min(78, columns - 12))
	local buf = api.nvim_create_buf(false, true)
	api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	api.nvim_set_option_value("modifiable", true, { buf = buf })
	api.nvim_set_option_value("filetype", "todo2filterprompt", { buf = buf })
	api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default or "", "" })

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor(vim.o.lines / 3)),
		col = math.max(0, math.floor((columns - width) / 2)),
		width = width,
		height = 2,
		style = "minimal",
		border = "rounded",
		title = " " .. (opts.title or "Filter") .. " ",
		title_pos = "center",
		zindex = 210,
	})
	state.buf, state.win = buf, win

	api.nvim_set_option_value("wrap", false, { scope = "local", win = win })
	api.nvim_set_option_value("cursorline", false, { scope = "local", win = win })

	-- 这一格是补全输入框，不需要别的补全插件掺和（blink 用全局 <Tab>，
	-- 它一旦接管，我们的 Tab 就变成 snippet 跳转）。vim.b.completion = false
	-- 是 blink / nvim-cmp 都认的标准开关。
	pcall(api.nvim_buf_set_var, buf, "completion", false)

	local function install_keys()
		if not buf_valid() then
			return
		end
		local map_opts = { buffer = buf, silent = true, nowait = true }
		vim.keymap.set({ "i", "n" }, "<Tab>", function()
			accept(1)
		end, map_opts)
		vim.keymap.set({ "i", "n" }, "<S-Tab>", function()
			accept(-1)
		end, map_opts)
	end
	install_keys()

	local map_opts = { buffer = buf, silent = true, nowait = true }
	vim.keymap.set("i", "<CR>", function()
		local value = line_text()
		local submit = state.opts and state.opts.on_submit
		M.close()
		if submit then
			submit(value)
		end
	end, map_opts)
	vim.keymap.set("n", "<CR>", function()
		local value = line_text()
		local submit = state.opts and state.opts.on_submit
		M.close()
		if submit then
			submit(value)
		end
	end, map_opts)
	vim.keymap.set({ "i", "n" }, "<Esc>", function()
		local cancel = state.opts and state.opts.on_cancel
		M.close()
		if cancel then
			cancel(line_text())
		end
	end, map_opts)
	vim.keymap.set("i", "<C-c>", function()
		local cancel = state.opts and state.opts.on_cancel
		M.close()
		if cancel then
			cancel(line_text())
		end
	end, map_opts)

	local group = api.nvim_create_augroup("todo2_filter_prompt_" .. buf, { clear = true })
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		group = group,
		callback = function()
			-- 内容不是我们自己写进去的 → 用户在打字，循环从头算
			-- （不能靠「是否正在写 buffer」的标志位判断：TextChanged 是延后触发的）
			if state.written ~= line_text() then
				state.cycle = nil
			end
			render_candidates()
			local change = state.opts and state.opts.on_change
			if change then
				change(line_text())
			end
		end,
	})
	api.nvim_create_autocmd("InsertEnter", {
		buffer = buf,
		group = group,
		callback = function()
			install_keys()
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		group = group,
		callback = function()
			pcall(api.nvim_del_augroup_by_id, group)
		end,
	})

	-- 先放光标再算候选：候选取决于光标所在的 token
	api.nvim_win_set_cursor(win, { 1, #line_text() })
	render_candidates()
	vim.cmd("startinsert!")
end

return M
