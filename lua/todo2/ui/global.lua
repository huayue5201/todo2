-- lua/todo2/ui/global.lua
-- 全局视图（:TodoGlobal）：只读列表，按项目分组展示跨项目活跃任务。
--
-- 写入永远回到“拥有该任务的项目”里进行：同项目就地打开，
-- 跨项目开新 tab 并 `tcd` 到对方项目根目录——store 绑定 cwd，
-- 这样对方的任务只会落到对方自己的 store 里，不会污染当前项目。

local M = {}

local index = require("todo2.global.index")
local ref_utils = require("todo2.global.ref")
local project_utils = require("todo2.utils.project")
local window_utils = require("todo2.ui.window")

-- state.pick：关系选择模式。`{ id, content, kind, rels }`；nil = 普通只读视图。
-- state.filter：当前过滤词（nil = 不过滤）。
local state = { buf = nil, win = nil, rows = {}, pick = nil, filter = nil }

local open -- 前向声明：toggle/open_pick 都往后调它
local ns = vim.api.nvim_create_namespace("todo2-global")

---@return integer|nil
local function valid_win()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		return state.win
	end
	state.win = nil
	return nil
end

local function close()
	local win = valid_win()
	if win then
		vim.api.nvim_win_close(win, true)
	end
	state.win, state.buf, state.rows, state.filter = nil, nil, {}, nil
end

--- 高亮：标题 / 项目分组 / 阻塞标记
local function highlight(buf, lines, rows)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "TodoGlobalHeader" })
	for i = 1, #lines do
		local row = rows[i]
		if row and row.project_header then
			vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #lines[i], hl_group = "TodoGlobalProject" })
		elseif row then
			local s, e = lines[i]:find("blocked×%d+")
			if s then
				vim.api.nvim_buf_set_extmark(buf, ns, i - 1, s - 1, { end_col = e, hl_group = "TodoGlobalBlocked" })
			end
		end
	end
end

--- 行前导标记：已关联的打 ✔（选择模式）
local function related_set()
	local set = {}
	for _, token in ipairs(state.pick and state.pick.rels or {}) do
		local r = ref_utils.parse(token)
		if r then
			set[ref_utils.qref(r.project, r.id)] = true
		end
	end
	return set
end

--- 过滤词匹配：id / 内容 / 项目名 / 标签，大小写不敏感子串
local function matches(entry)
	local f = state.filter
	if not f then
		return true
	end
	local hay = table.concat({ entry.id, entry.content or "", entry.project, table.concat(entry.tags or {}, " ") }, " ")
	return hay:lower():find(f:lower(), 1, true) ~= nil
end

--- 在当前窗口渲染一轮扫描结果
local function fill()
	local keep = state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_cursor(state.win)[1] or nil
	local data = index.scan()
	local related = related_set()
	local header, lines, rows = index.render_lines(data, {
		keep = matches,
		mark = state.pick and function(entry)
			return related[ref_utils.qref(entry.project, entry.id)] and "✔ " or "  "
		end or nil,
	})
	if state.pick then
		header = ("relate · %s %s  ·  kind: %s  ·  <CR>/<Space> toggle  b kind  f filter"):format(
			state.pick.id,
			state.pick.content or "",
			state.pick.kind
		)
	end
	if state.filter then
		header = header .. "  ·  /" .. state.filter
	end
	-- rows 里有空行留下的空洞，list_extend 会在这里提前停住；
	-- 逐行拷贝才能保证 aligned 按行号与 all 对齐。
	local all = { header, ("-"):rep(vim.fn.strdisplaywidth(header)) }
	local aligned = {}
	for i, line in ipairs(lines) do
		all[#all + 1] = line
		aligned[#all] = rows[i]
	end

	local buf = state.buf
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, all)
	vim.bo[buf].modifiable = false
	state.rows = aligned
	highlight(buf, all, aligned)

	-- 光标留在原地（切换关系后不跳回第一行）；没地方站就落到第一条任务
	local target = keep and aligned[keep] and keep or nil
	if not target then
		for i = 3, #all do
			if aligned[i] then
				target = i
				break
			end
		end
	end
	if target then
		pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 })
	end
end

--- 打开任务所在的 TODO 文件（跨项目开新 tab 并切换 cwd）
---@param entry table
local function open_entry(entry)
	-- 换 cwd 是跨项目跳转的关键：store 按 cwd 隔离，不换就会把对方的任务
	-- 同步进当前项目的 store。根目录不在了（仓库被移走/删除）就不要跳。
	if vim.fn.isdirectory(entry.root) ~= 1 then
		vim.notify(("[todo2] project root is gone: %s"):format(entry.root), vim.log.levels.WARN)
		return
	end

	-- 先收起视图：否则 `edit` 会把全局 buffer 换成 TODO 文件，
	-- 窗口还留在 state 里，下次 toggle 会关掉用户的窗口。
	close()

	local current = project_utils.current()
	if current and current.name == entry.project then
		window_utils.open_todo_file(entry.path, "edit", entry.line, { enter_insert = false })
		return
	end

	vim.cmd("tabnew")
	vim.cmd("tcd " .. vim.fn.fnameescape(entry.root))
	vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
	pcall(vim.api.nvim_win_set_cursor, 0, { entry.line or 1, 0 })
end

--- 光标下的条目
local function entry_under_cursor()
	local row = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
	if not row or row.project_header then
		return nil
	end
	return row
end

--- 选择模式：<CR> 增删一条边
local function toggle_edge()
	local entry = entry_under_cursor()
	if not entry or not state.pick then
		return
	end
	local qref = ref_utils.qref(entry.project, entry.id)
	local mode = related_set()[qref] and "remove" or "add"
	local token = state.pick.kind == "relates" and qref or (state.pick.kind .. ":" .. qref)
	local rels, err = require("todo2.handlers.rel").rels_for_id(state.pick.id, mode, { token })
	if not rels then
		vim.notify("[todo2] " .. err, vim.log.levels.ERROR)
		return
	end
	state.pick.rels = rels
	fill()
end

--- 选择模式：切换新边类型（relates ↔ blocks）
local function toggle_kind()
	if not state.pick then
		return
	end
	state.pick.kind = state.pick.kind == "relates" and "blocks" or "relates"
	fill()
end

--- 过滤：`f` 边打边过滤，`F` 清除
local function filter_prompt()
	local previous = state.filter
	require("todo2.ui.filter_prompt").open({
		title = "Filter tasks",
		default = previous or "",
		on_change = function(input)
			state.filter = input ~= "" and input or nil
			fill()
		end,
		on_cancel = function()
			state.filter = previous
			fill()
		end,
	})
end

local function clear_filter()
	state.filter = nil
	fill()
end

--- 打开 / 关闭全局视图
function M.toggle()
	if valid_win() then
		close()
		return
	end
	state.pick = nil
	open()
end

--- 关系选择模式：给 `source.id` 挑目标任务（:TodoRel 无参数 / 抽屉 `L`）
---@param source { id: string, content?: string, rels?: string[] }
function M.open_pick(source)
	if valid_win() then
		close()
	end
	state.pick = { id = source.id, content = source.content, kind = "relates", rels = source.rels or {} }
	open()
end

--- 创建视图 buffer 与窗口
function open()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "todo2://global")
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buflisted = false
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "todo2global"

	vim.cmd("botright split")
	state.buf, state.win = buf, vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.win, buf)
	vim.wo[state.win].cursorline = true
	vim.wo[state.win].wrap = false
	vim.wo[state.win].number = false

	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	map("<CR>", function()
		if state.pick then
			toggle_edge()
			return
		end
		local entry = entry_under_cursor()
		if entry then
			open_entry(entry)
		end
	end, "Open task / toggle relation")
	if state.pick then
		map(" ", toggle_edge, "Toggle relation")
		map("b", toggle_kind, "Toggle relation kind")
	end
	map("R", fill, "Rescan")
	map("f", filter_prompt, "Filter tasks")
	map("F", clear_filter, "Clear filter")
	map("q", close, "Close")
	map("<Esc>", close, "Close")

	fill()
end

return M
