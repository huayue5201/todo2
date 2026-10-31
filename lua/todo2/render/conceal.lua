-- lua/todo2/render/conceal.lua
-- 精简版：仅处理 TODO 文件的 conceal 渲染

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local core = require("todo2.store.task.core")
local types = require("todo2.store.types")
local constants = require("todo2.constants")
local checkbox = require("todo2.render.checkbox")
local status_domain = require("todo2.core.status")
local fold = require("todo2.render.fold")
local due_utils = require("todo2.utils.due")

local NS_CONCEAL = constants.ns("conceal")
local NS_STRIKE = constants.ns("strike")
local NS_DUE = constants.ns("due_conceal")

-- 行内到期日隐藏的状态（定义在最早处，避免 cleanup_buffer 等上面的函数引用到全局）
local due_lines = {} -- [buf] = { [lnum] = true } 行内带可隐藏 due 的行
local hooked = {} -- [buf] = true
local cursor_at = {} -- [buf] = lnum

local function reveal_due(buf, lnum)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, NS_DUE, lnum - 1, lnum)
	end
end

---------------------------------------------------------------------
-- 工具：行号有效性
---------------------------------------------------------------------
local function valid(buf, lnum)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local total = vim.api.nvim_buf_line_count(buf)
	return lnum >= 1 and lnum <= total
end

---------------------------------------------------------------------
-- 删除线
---------------------------------------------------------------------
local function strike(buf, lnum, len)
	vim.api.nvim_buf_set_extmark(buf, NS_STRIKE, lnum - 1, 0, {
		end_col = len,
		hl_group = "TodoCompleted",
		hl_mode = "combine",
		priority = 5,
	})
end

---------------------------------------------------------------------
-- 清理
---------------------------------------------------------------------
function M.cleanup_buffer(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, NS_CONCEAL, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, NS_STRIKE, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, NS_DUE, 0, -1)
	end
	due_lines[buf] = nil
end

---------------------------------------------------------------------
-- 设置窗口 conceal 选项
---------------------------------------------------------------------
function M.setup_window_conceal(buf)
	-- 应用到所有显示该 buffer 的窗口，而不只是第一个：
	--   * buffer 可能在显示到窗口之前就已渲染（此时 bufwinid == -1），
	--     之后第一次显示时不会再有 BufRead，窗口的 conceallevel 仍是 0；
	--   * 同一个 buffer 可能同时显示在多个窗口（分屏 / 浮窗）里。
	local wins = vim.fn.win_findbuf(buf)
	if #wins == 0 then
		return
	end

	-- 仅设置窗口局部值（scope = "local"）。
	-- 直接使用 vim.wo[win].x = y 会像 :set 一样同时写入全局值，
	-- 导致 conceallevel=2 泄漏到后续新建的窗口（如 fff 的浮窗输入框），
	-- 使输入框内文字被 conceal、光标视觉上意外左移。
	for _, win in ipairs(wins) do
		pcall(function()
			vim.api.nvim_set_option_value("conceallevel", 2, { scope = "local", win = win })
			vim.api.nvim_set_option_value("concealcursor", "nvic", { scope = "local", win = win })
		end)
	end

	-- 任务正文默认折叠（窗口局部；内部幂等，不覆盖用户展开/收起）
	fold.setup_window(buf)
end

---------------------------------------------------------------------
-- 隐藏区间（统一入口）
---------------------------------------------------------------------
---@param buf number
---@param lnum number 1-based 行号
---@param start_col number 1-based 起始列
---@param end_col number 1-based 结束列（含）
---@param text string 替换文本（"" 表示完全隐藏）
---@param hl? string 替换文本的高亮组
local function conceal_range_ns(buf, ns, lnum, start_col, end_col, text, hl)
	vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, start_col - 1, {
		end_col = end_col,
		conceal = text,
		hl_group = hl,
	})
end

---@param hl? string 替换文本的高亮组
local function conceal_range(buf, lnum, start_col, end_col, text, hl)
	conceal_range_ns(buf, NS_CONCEAL, lnum, start_col, end_col, text, hl)
end

---------------------------------------------------------------------
-- 行内到期日的隐藏 / 光标行显形
--
-- 到期日已搬到行尾元数据带展示（task_virt.build_status），行内那份真实文本
-- 就只是语法噪声。但它是真源，且是用户可能要手改的值，所以：
--   * 平时隐藏；只有光标**压在那几个字符上**时才显出原文（列级显形）
--     —— 这样整行视觉上就是「内容在前、日期在行尾 band」，与抽屉/代码侧一致；
--     要手改日期时把光标移过去就能看到，不会在隐藏文本上摸黑移动
--   * 用单独的 namespace，光标移动时只增删一个 extmark，不重渲整行
---------------------------------------------------------------------
--- 计算行内时间字段（`~start` / `@due`）的隐藏区间（1-based，含首尾）
---@param line string
---@param parsed table
---@return table[] 每项 `{ s = number, e = number }`
local function date_ranges(line, parsed)
	if not parsed then
		return {}
	end
	local _, mk_e = format.get_mark_position(line)
	if not mk_e then
		return {}
	end
	local out = {}
	local cursor = mk_e + 1
	-- 语法顺序固定：~start 在前、@due 在后；手写行多空格时对不上就不隐藏
	for _, seg in ipairs({ due_utils.format_start(parsed.start), due_utils.format(parsed.due) }) do
		if seg ~= "" and line:sub(cursor, cursor + #seg - 1) == seg then
			out[#out + 1] = { s = cursor, e = cursor + #seg - 1 }
			cursor = cursor + #seg
		end
	end
	return out
end

--- 隐藏指定行的时间字段段（行文本现读，宁可不隐藏也不粗暴切错）
local function conceal_due_on_line(buf, lnum)
	if not valid(buf, lnum) then
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
	reveal_due(buf, lnum) -- 先清旧标记，避免同一行堆叠多个 extmark
	for _, range in ipairs(date_ranges(line, format.parse_task_line(line))) do
		conceal_range_ns(buf, NS_DUE, lnum, range.s, range.e, "")
	end
end

--- 光标是否正压在某段的那几个字符上（列级判断，0-based 字节列）
---@param ranges table[]
---@return boolean
local function cursor_in_ranges(buf, lnum, ranges)
	if vim.api.nvim_get_current_buf() ~= buf then
		return false
	end
	local pos = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())
	if pos[1] ~= lnum then
		return false
	end
	local col = pos[2] -- 0-based 字节列
	for _, range in ipairs(ranges) do
		if col >= range.s - 1 and col < range.e then
			return true
		end
	end
	return false
end

--- 按当前光标位置决定本行是否隐藏（只有光标压到日期上才显形）
local function apply_due_conceal(buf, lnum, line, parsed)
	reveal_due(buf, lnum)

	local ranges = date_ranges(line, parsed)
	local set = due_lines[buf]
	if #ranges == 0 then
		if set then
			set[lnum] = nil
		end
		return
	end

	set = set or {}
	due_lines[buf] = set
	set[lnum] = true

	if cursor_in_ranges(buf, lnum, ranges) then
		return
	end

	conceal_due_on_line(buf, lnum)
end

--- 现读一行，判断并应用（光标列变化时要重算）
local function sync_due_on_line(buf, lnum)
	if not valid(buf, lnum) then
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
	local ranges = date_ranges(line, format.parse_task_line(line))
	if #ranges == 0 then
		reveal_due(buf, lnum)
		return
	end
	if cursor_in_ranges(buf, lnum, ranges) then
		reveal_due(buf, lnum)
	else
		conceal_due_on_line(buf, lnum)
	end
end

local function ensure_cursor_hook(buf)
	if hooked[buf] then
		return
	end
	hooked[buf] = true

	local group = vim.api.nvim_create_augroup("todo2_due_conceal_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			local set = due_lines[buf]
			if not set or not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			local now = vim.fn.line(".")
			local prev = cursor_at[buf]
			cursor_at[buf] = now
			-- 只是换行：离开的行一律隐藏
			if prev and prev ~= now and set[prev] then
				conceal_due_on_line(buf, prev)
			end
			-- 同一行内的水平移动也要重算（列级显形）
			if set[now] then
				sync_due_on_line(buf, now)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		group = group,
		buffer = buf,
		callback = function()
			due_lines[buf] = nil
			cursor_at[buf] = nil
			hooked[buf] = nil
			pcall(vim.api.nvim_del_augroup_by_id, group)
		end,
	})
end

---------------------------------------------------------------------
-- 核心：单行渲染（仅 TODO 文件）
---------------------------------------------------------------------
function M.apply_line_conceal(buf, lnum)
	if not config.get("conceal_enable") then
		return false
	end
	if not valid(buf, lnum) then
		return false
	end

	M.setup_window_conceal(buf)

	-- 清理当前行的现有渲染
	vim.api.nvim_buf_clear_namespace(buf, NS_CONCEAL, lnum - 1, lnum)
	vim.api.nvim_buf_clear_namespace(buf, NS_STRIKE, lnum - 1, lnum)

	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
	local len = #line

	-----------------------------------------------------------------
	-- 解析任务（仅 TODO 文件格式）
	-----------------------------------------------------------------
	local parsed = format.parse_task_line(line)
	if not parsed then
		return false
	end

	local id = parsed.id
	local task = id and core.get_task(id)

	-- 有效状态：优先 store，回退到文本 checkbox
	local status = task and task.core.status or status_domain.resolve_checkbox(parsed.checkbox)
	local is_completed = types.is_completed_status(status)
	local is_archived = status == types.STATUS.ARCHIVED

	-----------------------------------------------------------------
	-- checkbox 渲染（统一走共享 checkbox 模块）
	-----------------------------------------------------------------
	local cb_s, cb_e = format.get_checkbox_position(line)
	if cb_s and cb_e then
		local icon, icon_hl = checkbox.get(status)
		conceal_range(buf, lnum, cb_s, cb_e, icon, icon_hl)

		if is_completed or is_archived then
			strike(buf, lnum, len)
		end
	end

	-----------------------------------------------------------------
	-- 任务标记（<status>:<id>）隐去，编辑时只保留图标 + 内容
	-----------------------------------------------------------------
	local mk_s, mk_e = format.get_mark_position(line)
	if mk_s and mk_e then
		conceal_range(buf, lnum, mk_s, mk_e, "")
	end

	-----------------------------------------------------------------
	-- 到期日段（` @YYYY-MM-DD`）隐去：已在行尾元数据带展示；光标行显形
	-----------------------------------------------------------------
	if config.get("conceal_due") ~= false then
		apply_due_conceal(buf, lnum, line, parsed)
		ensure_cursor_hook(buf)
	else
		-- 配置关掉时把旧标记收拾干净（不能只靠下次重渲）
		reveal_due(buf, lnum)
		if due_lines[buf] then
			due_lines[buf][lnum] = nil
		end
	end

	return true
end

---------------------------------------------------------------------
-- 范围渲染
---------------------------------------------------------------------
function M.apply_range_conceal(buf, s, e)
	local count = 0
	for l = s, e do
		local ok, r = pcall(M.apply_line_conceal, buf, l)
		if ok and r then
			count = count + 1
		end
	end
	return count
end

---------------------------------------------------------------------
-- 智能渲染（增量）
---------------------------------------------------------------------
function M.apply_smart_conceal(buf, changed)
	if not config.get("conceal_enable") then
		return 0
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end

	M.setup_window_conceal(buf)

	local total = vim.api.nvim_buf_line_count(buf)

	if changed and #changed > 0 then
		local count = 0
		for _, l in ipairs(changed) do
			if type(l) == "number" and l >= 1 and l <= total then
				if M.apply_line_conceal(buf, l) then
					count = count + 1
				end
			end
		end
		return count
	end

	return M.apply_range_conceal(buf, 1, total)
end

---------------------------------------------------------------------
-- 全量渲染
---------------------------------------------------------------------
function M.apply_buffer_conceal(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end

	M.setup_window_conceal(buf)
	M.cleanup_buffer(buf)

	local total = vim.api.nvim_buf_line_count(buf)
	local count = M.apply_range_conceal(buf, 1, total)

	-- 重绘标签筛选（若该缓冲区开启了筛选）。
	-- 只在全量渲染时刷新，避免编辑过程中误隐藏正在输入的行。
	pcall(function()
		require("todo2.render.filter").refresh(buf)
	end)

	return count
end

return M
