-- lua/todo2/ui/conceal.lua
local M = {}

local config = require("todo2.config")
local module = require("todo2.module")

-- 获取标签管理器用于提取标签
local function get_tag_manager()
	return module.get("todo2.utils.tag_manager")
end

-- 获取高亮模块
local function get_highlights()
	return module.get("ui.highlights")
end

function M.setup_conceal_syntax(bufnr)
	-- 修改点：使用新的配置访问方式
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return
	end

	local conceal_symbols = config.get("conceal_symbols")
	if not conceal_symbols then
		return
	end

	-- 构建语法命令
	local syntax_commands = {
		string.format("buffer %d", bufnr),
		-- 隐藏复选框
		string.format("syntax match markdownTodo /\\[\\s\\]/ conceal cchar=%s", conceal_symbols.todo),
		string.format("syntax match markdownTodoDone /\\[[xX]\\]/ conceal cchar=%s", conceal_symbols.done),
		"highlight default link markdownTodo Conceal",
		"highlight default link markdownTodoDone Conceal",
	}

	-- 如果配置了隐藏任务ID，添加对应的语法
	if conceal_symbols.id then
		table.insert(
			syntax_commands,
			string.format("syntax match markdownTodoId /{#\\w\\+}/ conceal cchar=%s", conceal_symbols.id)
		)
		table.insert(syntax_commands, "highlight default link markdownTodoId Conceal")
	end

	-- 执行所有语法命令
	vim.cmd(table.concat(syntax_commands, "\n"))
end

-- ⭐ 新增：获取任务ID的隐藏图标
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

-- ⭐ 新增：动态隐藏任务ID（使用extmark实现，更灵活）
function M.conceal_task_ids(bufnr)
	local conceal_enable = config.get("conceal_enable")
	local conceal_symbols = config.get("conceal_symbols") or {}

	if not conceal_enable or not conceal_symbols.id then
		return
	end

	-- 获取标签管理器
	local tag_manager = get_tag_manager()

	-- 创建命名空间
	local ns_id = vim.api.nvim_create_namespace("todo2_conceal_id")

	-- 获取所有行
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i, line in ipairs(lines) do
		local id_match = line:match("{#(%w+)}")
		if id_match then
			-- 查找ID在行中的位置
			local start_col, end_col = line:find("{#" .. id_match .. "}")
			if start_col then
				-- 获取该任务对应的图标
				local icon = get_task_id_icon(line, tag_manager) or conceal_symbols.id

				-- 使用extmark隐藏ID并显示图标
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, start_col - 1, {
					end_col = end_col,
					conceal = icon,
					priority = 100,
				})
			end
		end
	end
end

function M.apply_conceal(bufnr)
	-- 修改点：使用新的配置访问方式
	local conceal_enable = config.get("conceal_enable")
	if not conceal_enable then
		return
	end

	local win = vim.fn.bufwinid(bufnr)
	if win == -1 then
		return
	end

	-- 修改点：使用硬编码的默认值，因为新配置中没有 level 和 cursor 配置
	local conceal_level = 2 -- 默认值
	local conceal_cursor = "nv" -- 默认值

	vim.api.nvim_set_option_value("conceallevel", conceal_level, { win = win })
	vim.api.nvim_set_option_value("concealcursor", conceal_cursor, { win = win })

	M.setup_conceal_syntax(bufnr)

	-- ⭐ 新增：应用任务ID隐藏
	M.conceal_task_ids(bufnr)
end

function M.toggle_conceal(bufnr)
	-- 修改点：使用新的配置访问方式
	local current_enable = config.get("conceal_enable")
	local new_enable = not current_enable

	-- 更新配置
	config.update("conceal_enable", new_enable)

	-- 重新应用当前缓冲区
	local win = vim.fn.bufwinid(bufnr)
	if win ~= -1 then
		if new_enable then
			M.apply_conceal(bufnr)
		else
			-- 关闭 conceal
			vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
			-- 清理ID隐藏的extmark
			local ns_id = vim.api.nvim_create_namespace("todo2_conceal_id")
			vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
		end
	end

	return new_enable
end

-- ⭐ 新增：刷新单个任务行的ID隐藏
function M.refresh_task_id_conceal(bufnr, lnum)
	local conceal_enable = config.get("conceal_enable")
	local conceal_symbols = config.get("conceal_symbols") or {}

	if not conceal_enable or not conceal_symbols.id then
		return
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return
	end

	local tag_manager = get_tag_manager()
	local ns_id = vim.api.nvim_create_namespace("todo2_conceal_id")

	-- 清除该行的现有隐藏
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, lnum - 1, lnum)

	local id_match = line:match("{#(%w+)}")
	if id_match then
		local start_col, end_col = line:find("{#" .. id_match .. "}")
		if start_col then
			local icon = get_task_id_icon(line, tag_manager) or conceal_symbols.id
			vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, start_col - 1, {
				end_col = end_col,
				conceal = icon,
				priority = 100,
			})
		end
	end
end

-- ⭐ 新增：简单的图标高亮函数
function M.highlight_icon(bufnr, lnum, start_col, end_col, priority)
	local highlights = get_highlights()
	if not highlights then
		return false
	end

	-- 获取对应的高亮组
	local hl_group = highlights.get_priority_highlight(priority)
	if not hl_group then
		return false
	end

	-- 创建命名空间
	local ns_id = vim.api.nvim_create_namespace("todo2_icon_highlight")

	-- 设置高亮extmark
	vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, start_col - 1, {
		end_col = end_col,
		hl_group = hl_group,
		priority = 50, -- 中等优先级
	})

	return true
end

-- ⭐ 新增：清除图标高亮
function M.clear_icon_highlights(bufnr)
	local ns_id = vim.api.nvim_create_namespace("todo2_icon_highlight")
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
end

return M
