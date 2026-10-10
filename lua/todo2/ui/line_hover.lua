-- lua/todo2/ui/line_hover.lua
-- 光标行浮窗：当前行内容超出所在窗口宽度时，用无边框、跟随光标的浮窗补全显示，
-- 避免被窄窗（如抽屉）截断。做法参考 rcarriga/nvim-dap-ui 的 render/line_hover.lua：
--   relative="cursor"、height=1、width=内容宽度、style=minimal、border=none，
--   并把 NormalFloat 映射为 Normal，让它看起来像该行「撑」到了整窗宽度。
local M = {}

local api = vim.api

-- 浮窗高亮命名空间
local NS = api.nvim_create_namespace("todo2_line_hover")

-- 源 buffer -> 浮窗 id
local buf_wins = {}
-- 源 buffer -> autocmd group
local buf_groups = {}

local function win_valid(w)
	return w ~= nil and api.nvim_win_is_valid(w)
end

---关闭与某 buffer 关联的浮窗
---@param buf integer|nil
function M.close(buf)
	buf = buf or api.nvim_get_current_buf()
	local w = buf_wins[buf]
	if w then
		if win_valid(w) then
			pcall(api.nvim_win_close, w, true)
		end
		buf_wins[buf] = nil
	end
end

---关闭当前 buffer 的浮窗
function M.hide()
	M.close(api.nvim_get_current_buf())
end

local function display_width(s)
	return vim.fn.strdisplaywidth(s or "")
end

--- 计算需要补显示的片段。
---@param win integer
---@param line integer 1-based
---@return table|nil { text=string, from_col=integer, width=integer }
local function compute_segment(win, line)
	local buf = api.nvim_get_current_buf()
	local text = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
	if text == "" then
		return nil
	end

	local win_width = vim.fn.winwidth(win) - (vim.fn.getwininfo(win)[1].textoff or 0)
	-- 整行放得下就不显示
	if display_width(text) <= win_width then
		return nil
	end

	local _, cur_col = unpack(api.nvim_win_get_cursor(win))
	local from_col = cur_col
	local tail = text:sub(from_col + 1)
	local width = display_width(tail)

	-- 从光标处向右会超出整屏时，退化为整行（尽量多展示）
	if vim.fn.screencol() - 1 + width > vim.o.columns then
		from_col = 0
		tail = text
		width = display_width(text)
	end

	if width <= 0 then
		return nil
	end
	return { text = tail, from_col = from_col, width = width }
end

--- 把源行的高亮 extmark 搬到浮窗 buffer（相对 from_col 平移）
local function copy_highlights(src_buf, line, from_col, dst_buf)
	local marks = api.nvim_buf_get_extmarks(src_buf, -1, { line - 1, 0 }, { line - 1, -1 }, { details = true })
	for _, m in ipairs(marks) do
		local scol, details = m[3], m[4]
		if details and details.hl_group and not details.virt_text then
			local ecol = details.end_col
			if not ecol or ecol > from_col then
				pcall(api.nvim_buf_set_extmark, dst_buf, NS, 0, math.max(scol - from_col, 0), {
					end_col = ecol and math.max(ecol - from_col, 0) or nil,
					hl_group = details.hl_group,
				})
			end
		end
	end
end

--- 根据当前光标行更新（或关闭）浮窗。应在光标移动 / 内容变化后调用。
function M.show()
	local win = api.nvim_get_current_win()
	if not win_valid(win) then
		return
	end
	-- 当前已是浮窗 → 不管
	if api.nvim_win_get_config(win).relative ~= "" then
		return
	end

	local buf = api.nvim_get_current_buf()
	local line = api.nvim_win_get_cursor(win)[1]
	local seg = compute_segment(win, line)
	if not seg then
		M.close(buf)
		return
	end

	local win_opts = {
		relative = "cursor",
		width = seg.width,
		height = 1,
		style = "minimal",
		border = "none",
		row = 0,
		col = 0,
		focusable = false,
		zindex = 200,
	}

	local hover_win = buf_wins[buf]
	if hover_win and not win_valid(hover_win) then
		buf_wins[buf] = nil
		hover_win = nil
	end

	if hover_win then
		-- 复用浮窗避免闪烁
		local hover_buf = api.nvim_win_get_buf(hover_win)
		api.nvim_win_set_config(hover_win, win_opts)
		vim.bo[hover_buf].modifiable = true
		api.nvim_buf_set_lines(hover_buf, 0, -1, false, { seg.text })
		vim.bo[hover_buf].modifiable = false
		api.nvim_buf_clear_namespace(hover_buf, NS, 0, -1)
		copy_highlights(buf, line, seg.from_col, hover_buf)
	else
		local hover_buf = api.nvim_create_buf(false, true)
		vim.fn.setbufline(hover_buf, 1, seg.text)
		vim.bo[hover_buf].bufhidden = "wipe"
		vim.bo[hover_buf].modifiable = false
		win_opts.noautocmd = true
		hover_win = api.nvim_open_win(hover_buf, false, win_opts)
		buf_wins[buf] = hover_win
		api.nvim_set_option_value("wrap", false, { win = hover_win })
		api.nvim_win_call(hover_win, function()
			vim.opt.winhighlight:append({ NormalFloat = "Normal" })
		end)
		copy_highlights(buf, line, seg.from_col, hover_buf)
	end
end

--- 为 buffer 挂上光标行浮窗（幂等）。
---@param buf integer|nil
function M.attach(buf)
	buf = buf or api.nvim_get_current_buf()
	if buf_groups[buf] then
		return
	end
	local group = api.nvim_create_augroup("Todo2LineHover" .. buf, { clear = true })
	buf_groups[buf] = group

	api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = group,
		buffer = buf,
		callback = function()
			vim.schedule(function()
				if api.nvim_get_current_buf() == buf then
					M.show()
				else
					M.close(buf)
				end
			end)
		end,
	})

	api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWipeout" }, {
		group = group,
		buffer = buf,
		callback = function()
			M.close(buf)
			if vim.fn.bufexists(buf) == 0 then
				buf_groups[buf] = nil
			end
		end,
	})
end

return M
