-- lua/todo2/utils/win.lua
-- 真实文件 / quickfix 的「落点窗口」管理。
--
-- quickfix 跳转用的是打开 quickfix 时的当前窗口（当前是 qf 窗口时用它的上一个窗口）。
-- 如果在抽屉 / 日历这类插件 UI 窗口里直接 :copen，跳转就会把真实文件塞进 UI
-- 窗口，把抽屉内容冲掉。这里统一在打开前先切到一个能承载文件的普通窗口。
--
-- 兜底还有 'winfixbuf'（见 ui/window.fix_buffer）：即便有别的路径试图把 UI
-- 窗口换成普通 buffer，Neovim 也会跳过该窗口或直接拒绝。

local M = {}

---窗口能否承载真实文件（非浮窗、非 UI、非 qf/loclist、未被 winfixbuf 钉住）。
---@param win integer
---@return boolean
function M.usable(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	if vim.api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	if vim.wo[win].winfixbuf then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local buftype = vim.bo[buf].buftype
	return buftype == "" or buftype == "acwrite"
end

---挑一个承载 qf 跳转的窗口：当前窗口优先，其次最近访问过的窗口，再其次同 tab 内其它窗口。
---@return integer|nil
function M.target_win()
	local current = vim.api.nvim_get_current_win()
	if M.usable(current) then
		return current
	end
	local ok, prev = pcall(vim.fn.win_getid, vim.fn.winnr("#"))
	if ok and prev ~= current and M.usable(prev) then
		return prev
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= current and M.usable(win) then
			return win
		end
	end
	return nil
end

---切到一个能承载真实文件的窗口（没有就新建一个）。
---@return integer win
function M.focus()
	local current = vim.api.nvim_get_current_win()
	local target = M.target_win()
	if target then
		if target ~= current then
			vim.api.nvim_set_current_win(target)
		end
		return target
	end
	-- 当前 tab 里没有可用窗口：开一个普通窗口当落点
	vim.cmd("leftabove new")
	return vim.api.nvim_get_current_win()
end

---打开 quickfix，并保证后续跳转落在普通编辑窗口而不是 UI 窗口。
function M.copen()
	M.focus()
	vim.cmd("copen")
end

return M
