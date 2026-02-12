-- lua/todo2/ui/conceal.lua
local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format") -- ⭐ 直接使用 format 模块

-- 模块常量
local CONCEAL_NS_ID = vim.api.nvim_create_namespace("todo2_conceal")

-- 获取任务ID图标
local function get_task_id_icon(task_line)
	-- ⭐ 直接调用 format.extract_tag 提取标签
	local tag = format.extract_tag(task_line)
	local tags_config = config.get("tags") or {}
	local tag_config = tags_config[tag]

	if tag_config and tag_config.id_icon then
		return tag_config.id_icon
	end

	local conceal_symbols = config.get("conceal_symbols") or {}
	return conceal_symbols.id
end

-- 清理指定缓冲区的所有隐藏
function M.cleanup_buffer(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, CONCEAL_NS_ID, 0, -1)
	end
	return true
end

-- 清理所有缓冲区的隐藏
function M.cleanup_all()
	local bufs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufs) do
		M.cleanup_buffer(bufnr)
	end
	return true
end

-- 应用单行隐藏
function M.apply_line_conceal(bufnr, lnum)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	-- 清理该行旧隐藏
	vim.api.nvim_buf_clear_namespace(bufnr, CONCEAL_NS_ID, lnum - 1, lnum)

	local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
	if #lines == 0 then
		return false
	end

	local line = lines[1]
	local conceal_symbols = config.get("conceal_symbols") or {}

	-- 1. 复选框隐藏（支持 todo / done / archived）
	if line:match("%[%s%]") then
		local start_col, end_col = line:find("%[%s%]")
		if start_col and conceal_symbols.todo then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = conceal_symbols.todo,
				hl_group = "TodoCheckboxTodo",
			})
		end
	elseif line:match("%[[xX]%]") then
		local start_col, end_col = line:find("%[[xX]%]")
		if start_col and conceal_symbols.done then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = conceal_symbols.done,
				hl_group = "TodoCheckboxDone",
			})
		end
	elseif line:match("%[>%]") then
		local start_col, end_col = line:find("%[>%]")
		if start_col then
			local icon = conceal_symbols.archived or "📁"
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = icon,
				hl_group = "TodoCheckboxArchived",
			})
		end
	end

	-- 2. 任务ID隐藏
	local id_match = line:match("{#(%w+)}")
	if id_match and conceal_symbols.id then
		local start_col, end_col = line:find("{#" .. id_match .. "}")
		if start_col then
			local icon = get_task_id_icon(line) -- ⭐ 不再传入 tag_manager
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = icon or conceal_symbols.id,
				hl_group = "TodoIdIcon",
			})
		end
	end

	return true
end

-- 应用范围隐藏
function M.apply_range_conceal(bufnr, start_lnum, end_lnum)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return 0
	end

	local count = 0
	for lnum = start_lnum, end_lnum do
		if M.apply_line_conceal(bufnr, lnum) then
			count = count + 1
		end
	end
	return count
end

-- 智能应用隐藏
function M.apply_smart_conceal(bufnr, changed_lines)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return 0
	end

	if changed_lines and #changed_lines > 0 then
		local count = 0
		for _, lnum in ipairs(changed_lines) do
			if M.apply_line_conceal(bufnr, lnum) then
				count = count + 1
			end
		end
		return count
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return M.apply_range_conceal(bufnr, 1, line_count)
end

-- 应用整个缓冲区隐藏
function M.apply_buffer_conceal(bufnr)
	M.cleanup_buffer(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	return M.apply_range_conceal(bufnr, 1, line_count)
end

-- 设置窗口的conceal选项
function M.setup_window_conceal(bufnr)
	local win = vim.fn.bufwinid(bufnr)
	if win == -1 then
		return false
	end

	vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
	vim.api.nvim_set_option_value("concealcursor", "nv", { win = win })
	return true
end

-- 切换隐藏开关
function M.toggle_conceal(bufnr)
	local current_enable = config.get("conceal_enable")
	local new_enable = not current_enable

	config.update("conceal_enable", new_enable)

	local win = vim.fn.bufwinid(bufnr)
	if win ~= -1 then
		if new_enable then
			M.setup_window_conceal(bufnr)
			M.apply_buffer_conceal(bufnr)
		else
			vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
			M.cleanup_buffer(bufnr)
		end
	end

	return new_enable
end

-- 刷新指定行的隐藏
function M.refresh_line_conceal(bufnr, lnum)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return false
	end
	return M.apply_line_conceal(bufnr, lnum)
end

-- 应用隐藏的主要入口函数
function M.apply_smart_conceal(bufnr)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return false
	end

	M.setup_window_conceal(bufnr)
	return M.apply_buffer_conceal(bufnr) > 0
end

-- 获取缓存统计信息（保持向后兼容，返回空）
function M.get_cache_stats()
	return { buffers = 0, entries = 0 }
end

-- 增加高亮组定义
vim.api.nvim_set_hl(0, "TodoCheckboxArchived", { link = "Comment", default = true })

return M
