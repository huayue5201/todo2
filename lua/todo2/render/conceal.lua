-- lua/todo2/render/conceal.lua（只增加预加载，不改逻辑）
local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local line_analyzer = require("todo2.utils.line_analyzer")

-- ⭐ 新增：引入调度器用于预加载缓存
local scheduler = require("todo2.render.scheduler")

-- 模块常量
local CONCEAL_NS_ID = vim.api.nvim_create_namespace("todo2_conceal")
local STRIKETHROUGH_NS_ID = vim.api.nvim_create_namespace("todo2_strikethrough")

-- 获取任务ID图标 - 只从标签配置获取
local function get_task_id_icon(task_line)
	local tag = format.extract_tag(task_line)
	local tags_config = config.get("tags") or {}
	local tag_config = tags_config[tag]

	if tag_config and tag_config.id_icon then
		return tag_config.id_icon
	end

	return nil
end

-- 应用删除线到整行
local function apply_strikethrough(bufnr, lnum, line_length)
	vim.api.nvim_buf_set_extmark(bufnr, STRIKETHROUGH_NS_ID, lnum - 1, 0, {
		end_col = line_length,
		hl_group = "TodoCompleted",
		hl_mode = "combine",
		priority = 5,
	})
end

-- 清理指定缓冲区的所有隐藏
function M.cleanup_buffer(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, CONCEAL_NS_ID, 0, -1)
		vim.api.nvim_buf_clear_namespace(bufnr, STRIKETHROUGH_NS_ID, 0, -1)
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

	-- 清理该行旧隐藏和删除线
	vim.api.nvim_buf_clear_namespace(bufnr, CONCEAL_NS_ID, lnum - 1, lnum)
	vim.api.nvim_buf_clear_namespace(bufnr, STRIKETHROUGH_NS_ID, lnum - 1, lnum)

	local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
	if #lines == 0 then
		return false
	end

	local line = lines[1]
	local line_length = #line

	-- 使用统一的复选框图标配置
	local checkbox_icons = config.get("checkbox_icons") or { todo = "◻", done = "✓", archived = "📦" }

	-- 1. 复选框隐藏（支持 todo / done / archived）
	if line:match("%[%s%]") then
		local start_col, end_col = line:find("%[%s%]")
		if start_col then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = checkbox_icons.todo,
				hl_group = "TodoCheckboxTodo",
			})
		end
	elseif line:match("%[[xX]%]") then
		local start_col, end_col = line:find("%[[xX]%]")
		if start_col then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = checkbox_icons.done,
				hl_group = "TodoCheckboxDone",
			})
			-- 为完成任务添加删除线
			apply_strikethrough(bufnr, lnum, line_length)
		end
	elseif line:match("%[>%]") then
		local start_col, end_col = line:find("%[>%]")
		if start_col then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = checkbox_icons.archived,
				hl_group = "TodoCheckboxArchived",
			})
			-- 为归档任务添加删除线
			apply_strikethrough(bufnr, lnum, line_length)
		end
	end

	-- 2. 使用 line_analyzer 分析行来处理 ID 隐藏
	local analysis = line_analyzer.analyze_line(bufnr, lnum)

	-- 如果是代码标记行且有ID
	if analysis.is_code_mark and analysis.id then
		local start_col, end_col = line:find(":ref:" .. analysis.id)
		if start_col then
			local icon = get_task_id_icon(line)
			if icon then
				vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
					end_col = end_col,
					conceal = icon,
					hl_group = "TodoIdIcon",
				})
			end
		end
	elseif analysis.is_todo_mark and analysis.id then
		local start_col, end_col = line:find("{#" .. analysis.id .. "}")
		if start_col then
			local icon = get_task_id_icon(line)
			if icon then
				vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
					end_col = end_col,
					conceal = icon,
					hl_group = "TodoIdIcon",
				})
			end
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

-- 智能应用隐藏（根据变化的行）
function M.apply_smart_conceal(bufnr, changed_lines)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return 0
	end

	-- ⭐ 预加载缓存，但conceal本身不依赖解析结果
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path ~= "" and path:match("%.todo%.md$") then
		scheduler.get_parse_tree(path, false)
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

-- 增加高亮组定义
vim.api.nvim_set_hl(0, "TodoCheckboxArchived", { link = "Comment", default = true })

return M
