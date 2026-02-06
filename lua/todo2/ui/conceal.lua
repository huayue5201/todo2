-- lua/todo2/ui/conceal.lua
local M = {}

local config = require("todo2.config")
local module = require("todo2.module")

-- 模块常量
local CONCEAL_NS_ID = vim.api.nvim_create_namespace("todo2_conceal")
local TASK_ID_NS_ID = vim.api.nvim_create_namespace("todo2_conceal_task_id")

-- 获取标签管理器用于提取标签
local function get_tag_manager()
	return module.get("todo2.utils.tag_manager")
end

-- 缓存任务行和ID的映射，用于快速查找和增量更新
local task_id_cache = {} -- 格式: {bufnr = {lnum = id, ...}, ...}

-- 获取任务ID的隐藏图标
local function get_task_id_icon(task_line, tag_manager)
	if not tag_manager then
		return nil
	end

	-- 提取标签
	local tag = tag_manager.extract_from_task_content(task_line)
	local tags_config = config.get("tags") or {}
	local tag_config = tags_config[tag]

	-- 如果该标签配置了ID图标，使用该图标
	if tag_config and tag_config.id_icon then
		return tag_config.id_icon
	end

	-- 否则使用全局ID图标配置
	local conceal_symbols = config.get("conceal_symbols") or {}
	return conceal_symbols.id
end

-- 清理指定缓冲区的所有隐藏
local function clear_all_conceal(bufnr)
	-- 清理extmark命名空间
	vim.api.nvim_buf_clear_namespace(bufnr, CONCEAL_NS_ID, 0, -1)
	vim.api.nvim_buf_clear_namespace(bufnr, TASK_ID_NS_ID, 0, -1)

	-- 清理缓存
	if task_id_cache[bufnr] then
		task_id_cache[bufnr] = nil
	end
end

-- 清理指定行的隐藏
local function clear_line_conceal(bufnr, lnum)
	-- 清理该行的所有extmark
	vim.api.nvim_buf_clear_namespace(bufnr, CONCEAL_NS_ID, lnum - 1, lnum)
	vim.api.nvim_buf_clear_namespace(bufnr, TASK_ID_NS_ID, lnum - 1, lnum)

	-- 清理缓存
	if task_id_cache[bufnr] then
		task_id_cache[bufnr][lnum] = nil
	end
end

-- 应用单行隐藏（增量的核心）
function M.apply_line_conceal(bufnr, lnum)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return false
	end

	local conceal_symbols = config.get("conceal_symbols") or {}

	-- 获取该行内容
	local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
	if #lines == 0 then
		return false
	end

	local line = lines[1]

	-- 清理该行旧隐藏
	clear_line_conceal(bufnr, lnum)

	-- 设置复选框隐藏
	if line:match("%[%s%]") then -- 未完成复选框
		local start_col, end_col = line:find("%[%s%]")
		if start_col and conceal_symbols.todo then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = conceal_symbols.todo,
				hl_group = "TodoCheckboxTodo",
				priority = 100,
			})
		end
	elseif line:match("%[[xX]%]") then -- 已完成复选框
		local start_col, end_col = line:find("%[[xX]%]")
		if start_col and conceal_symbols.done then
			vim.api.nvim_buf_set_extmark(bufnr, CONCEAL_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = conceal_symbols.done,
				hl_group = "TodoCheckboxDone",
				priority = 100,
			})
		end
	end

	-- 设置任务ID隐藏
	local id_match = line:match("{#(%w+)}")
	if id_match and conceal_symbols.id then
		local start_col, end_col = line:find("{#" .. id_match .. "}")
		if start_col then
			-- 获取标签管理器
			local tag_manager = get_tag_manager()

			-- 获取该任务对应的图标
			local icon = get_task_id_icon(line, tag_manager) or conceal_symbols.id

			-- 设置隐藏extmark
			vim.api.nvim_buf_set_extmark(bufnr, TASK_ID_NS_ID, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = icon,
				hl_group = "TodoIdIcon",
				priority = 100,
			})

			-- 更新缓存
			if not task_id_cache[bufnr] then
				task_id_cache[bufnr] = {}
			end
			task_id_cache[bufnr][lnum] = id_match
		end
	end

	return true
end

-- 应用多行隐藏（批量增量）
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

-- 智能应用隐藏（自动检测变化区域）
function M.apply_smart_conceal(bufnr, changed_lines)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return 0
	end

	-- 如果提供了变化行列表，只更新这些行
	if changed_lines and #changed_lines > 0 then
		local count = 0
		for _, lnum in ipairs(changed_lines) do
			if M.apply_line_conceal(bufnr, lnum) then
				count = count + 1
			end
		end
		return count
	end

	-- 否则检查整个缓冲区的任务ID变化
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local to_update = {}

	if not task_id_cache[bufnr] then
		task_id_cache[bufnr] = {}
	end

	-- 检查每行是否有变化
	for i, line in ipairs(lines) do
		local lnum = i
		local current_id = line:match("{#(%w+)}")
		local cached_id = task_id_cache[bufnr][lnum]

		-- 如果有ID且与缓存不同，或者之前有ID现在没有了
		if current_id ~= cached_id or (cached_id and not current_id) then
			table.insert(to_update, lnum)
		end
	end

	-- 更新变化行
	local count = 0
	for _, lnum in ipairs(to_update) do
		if M.apply_line_conceal(bufnr, lnum) then
			count = count + 1
		end
	end

	return count
end

-- 应用整个缓冲区隐藏（用于初始化）
function M.apply_buffer_conceal(bufnr)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return 0
	end

	-- 清理整个缓冲区的隐藏
	clear_all_conceal(bufnr)

	-- 获取缓冲区行数
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	-- 逐行应用隐藏
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

	-- 更新配置
	config.update("conceal_enable", new_enable)

	-- 重新应用当前缓冲区
	local win = vim.fn.bufwinid(bufnr)
	if win ~= -1 then
		if new_enable then
			M.setup_window_conceal(bufnr)
			M.apply_buffer_conceal(bufnr)
		else
			-- 关闭 conceal
			vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
			-- 清理所有隐藏
			clear_all_conceal(bufnr)
		end
	end

	return new_enable
end

-- 刷新指定行的隐藏（供外部调用）
function M.refresh_line_conceal(bufnr, lnum)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return false
	end

	return M.apply_line_conceal(bufnr, lnum)
end

-- 清理指定缓冲区的所有隐藏（供外部调用）
function M.cleanup_buffer(bufnr)
	clear_all_conceal(bufnr)
	return true
end

-- 清理所有缓冲区的隐藏（插件卸载时使用）
function M.cleanup_all()
	for bufnr, _ in pairs(task_id_cache) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			clear_all_conceal(bufnr)
		end
	end

	-- 清空缓存
	task_id_cache = {}

	return true
end

-- 应用隐藏的主要入口函数（保持向后兼容）
function M.apply_conceal(bufnr)
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return false
	end

	M.setup_window_conceal(bufnr)
	return M.apply_buffer_conceal(bufnr) > 0
end

-- 获取缓存统计信息（调试用）
function M.get_cache_stats()
	local total_buffers = 0
	local total_entries = 0

	for bufnr, cache in pairs(task_id_cache) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			total_buffers = total_buffers + 1
			for _, _ in pairs(cache) do
				total_entries = total_entries + 1
			end
		else
			-- 清理无效缓冲区的缓存
			task_id_cache[bufnr] = nil
		end
	end

	return {
		buffers = total_buffers,
		entries = total_entries,
	}
end

return M
