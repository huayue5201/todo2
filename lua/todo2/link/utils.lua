-- lua/todo/link/utils.lua
local M = {}

---------------------------------------------------------------------
-- 生成唯一 ID
---------------------------------------------------------------------
function M.generate_id()
	return string.format("%06x", math.random(0, 0xFFFFFF))
end

---------------------------------------------------------------------
function M.find_task_insert_position(lines)
	for i, line in ipairs(lines) do
		if line:match("^%s*[-*]%s+%[[ xX]%]") then
			return i
		end
	end

	for i, line in ipairs(lines) do
		if line:match("^#+ ") then
			for j = i + 1, #lines do
				if lines[j] == "" then
					return j + 1
				end
			end
			return i + 1
		end
	end

	return 1
end

---------------------------------------------------------------------
-- 获取注释前缀
---------------------------------------------------------------------
function M.get_comment_prefix(bufnr)
	bufnr = bufnr or 0 -- 默认当前 buffer
	local cs = vim.api.nvim_buf_get_option(bufnr, "commentstring") or "%s"
	cs = cs:gsub("^%s+", ""):gsub("%s+$", "")

	local pattern = "^(.-)%%s"
	local prefix = cs:match(pattern)

	if prefix then
		prefix = prefix:gsub("%s+$", "")
		return prefix
	end

	local ft = vim.api.nvim_buf_get_option(bufnr, "filetype")
	local defaults = {
		lua = "--",
		python = "#",
		vim = '"',
		sh = "#",
		c = "//",
		cpp = "//",
		java = "//",
		javascript = "//",
		typescript = "//",
		go = "//",
		rust = "//",
	}

	return defaults[ft] or "//"
end

---------------------------------------------------------------------
-- 统一：在代码 buffer 中将 TODO 标记插入到"上一行"
---------------------------------------------------------------------
-- 修改点：添加 tag 参数，使用传入的 tag 而不是固定为 "TODO"
function M.insert_code_tag_above(bufnr, row, id, tag)
	-- 自动获取注释前缀（支持 //, --, #, <!--, /* 等）
	local prefix = M.get_comment_prefix(bufnr)

	-- 构造标记行，使用传入的 tag
	local tag_line = string.format("%s %s:ref:%s", prefix, tag, id)

	-- 在 row-1 的位置插入新行（上一行）
	vim.api.nvim_buf_set_lines(bufnr, row - 1, row - 1, false, { tag_line })
end

-- 检查是否在 TODO 浮动窗口中
---------------------------------------------------------------------
function M.is_todo_floating_window(win_id)
	win_id = win_id or vim.api.nvim_get_current_win()

	if not vim.api.nvim_win_is_valid(win_id) then
		return false
	end

	local win_config = vim.api.nvim_win_get_config(win_id)
	local is_float = win_config.relative ~= ""

	if not is_float then
		return false
	end

	-- 检查buffer是否是TODO文件
	local bufnr = vim.api.nvim_win_get_buf(win_id)
	local bufname = vim.api.nvim_buf_get_name(bufnr)

	return bufname:match("%.todo%.md$") or bufname:match("todo")
end

return M
