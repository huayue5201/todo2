-- lua/todo2/creation/service.lua
--- @module todo2.link.service
--- @brief 统一的链接创建和管理服务（适配新版store API）
--- ⭐ 增强：添加上下文指纹支持 + 行号精准校验 + 内容锚定兜底

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local format = require("todo2.utils.format")
local store = require("todo2.store")
local events = require("todo2.core.events")
local autosave = require("todo2.core.autosave")
local link_utils = require("todo2.link.utils")

---------------------------------------------------------------------
-- 内部工具函数
---------------------------------------------------------------------

--- 通过 ref:id 反向查找真实行号（内容锚定兜底）
--- @param bufnr number 缓冲区编号
--- @param id string 链接ID
--- @param tag string 标签
--- @return number|nil 1-based真实行号
local function find_real_line_by_ref(bufnr, id, tag)
	if not bufnr or not id or not tag or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local pattern = tag .. ":ref:" .. id
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for lnum, line_content in ipairs(lines) do
		if line_content:find(pattern, 1, true) then -- 纯字符串匹配，避免正则转义
			return lnum
		end
	end
	return nil
end

--- 校验行号有效性
--- @param bufnr number 缓冲区编号
--- @param line number 1-based行号
--- @return boolean 是否有效
local function validate_line_number(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local total_lines = vim.api.nvim_buf_line_count(bufnr)
	return line and line >= 1 and line <= total_lines
end

--- ⭐ 修复：提取上下文信息（确保文件路径正确传递 + 内容锚定）
local function extract_context(bufnr, line, id, tag)
	-- 优先使用内容锚定获取上下文（最精准）
	local context_module = require("todo2.store.context")
	local pattern = tag and id and (tag .. ":ref:" .. id) or nil
	if pattern then
		local ctx = context_module.build_from_pattern(bufnr, pattern, vim.api.nvim_buf_get_name(bufnr))
		if ctx then
			return ctx
		end
	end

	-- 兼容原有逻辑（无标记时）
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prev = line > 1 and lines[line - 2] or ""
	local curr = lines[line - 1] or ""
	local next = line < #lines and lines[line] or ""
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local ctx = context_module.build(prev, curr, next, filepath, line)

	return ctx
end

--- 从代码行中提取标签
--- @param code_line string 代码行
--- @return string 标签名
local function extract_tag_from_code_line(code_line)
	if not code_line then
		return "TODO"
	end

	-- 匹配标签格式：FIX:ref:561470 -> FIX
	local tag = code_line:match("([A-Z][A-Z0-9]+):ref:")
	return tag or "TODO"
end

--- 格式化任务行（直接使用 format 模块）
local function format_task_line(options)
	return format.format_task_line(options)
end

---------------------------------------------------------------------
-- ⭐ 立即刷新代码文件 conceal
---------------------------------------------------------------------
local function refresh_code_conceal_immediate(bufnr, line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local success, result = pcall(function()
		local conceal = require("todo2.ui.conceal")
		if not conceal then
			return false
		end

		if line then
			conceal.apply_line_conceal(bufnr, line)
		else
			conceal.apply_buffer_conceal(bufnr)
		end
		conceal.setup_window_conceal(bufnr)
		return true
	end)

	if not success then
		vim.notify("刷新代码文件 conceal 失败: " .. tostring(result), vim.log.levels.DEBUG)
		return false
	end
	return true
end

---------------------------------------------------------------------
-- 核心服务函数（适配新版store API + 行号精准校验）
---------------------------------------------------------------------

--- 创建代码链接
--- @param bufnr number 缓冲区编号
--- @param line number 行号
--- @param id string 链接ID
--- @param content string 内容
--- @param tag string 标签
--- @return boolean 是否成功
function M.create_code_link(bufnr, line, id, content, tag)
	-- 1. 基础参数校验
	if not bufnr or not line or not id then
		vim.notify("创建代码链接失败：缺少必要参数", vim.log.levels.ERROR)
		return false
	end

	-- 2. 缓冲区有效性校验
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		vim.notify("创建代码链接失败：buffer没有文件路径", vim.log.levels.ERROR)
		return false
	end

	-- 3. 行号有效性校验（核心修复）
	if not validate_line_number(bufnr, line) then
		vim.notify(
			string.format(
				"行号%d无效！缓冲区%d总行数：%d，尝试内容锚定...",
				line,
				bufnr,
				vim.api.nvim_buf_line_count(bufnr)
			),
			vim.log.levels.WARN
		)
		-- 内容锚定兜底：通过ref:id查找真实行号
		local real_line = find_real_line_by_ref(bufnr, id, tag)
		if not real_line then
			vim.notify("内容锚定失败：未找到标记 " .. (tag or "") .. ":ref:" .. id, vim.log.levels.ERROR)
			return false
		end
		line = real_line -- 替换为真实有效行号
	end

	-- 4. 获取代码行内容
	local code_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	content = content or code_line

	-- 5. 从代码行提取标签，如果有传入tag则优先使用
	local extracted_tag = extract_tag_from_code_line(code_line)
	local final_tag = tag or extracted_tag or "TODO"

	-- 6. 提取上下文指纹（支持内容锚定）
	local context = extract_context(bufnr, line, id, final_tag)

	-- 7. 使用新的存储API
	if not store or not store.link then
		vim.notify("创建代码链接失败：无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	-- 8. 清理内容：移除标签前缀
	local cleaned_content = content
	cleaned_content = format.clean_content(content, final_tag)

	-- 9. 存储链接（使用校准后的行号）
	local success = store.link.add_code(id, {
		path = path,
		line = line, -- 已校准的有效行号
		content = cleaned_content,
		tag = final_tag,
		created_at = os.time(),
		context = context, -- 保存上下文指纹
		context_updated_at = os.time(),
	})

	if not success then
		vim.notify("创建代码链接失败：存储操作失败", vim.log.levels.ERROR)
		return false
	end

	-- 10. 立即刷新当前代码行的 conceal
	vim.defer_fn(function()
		refresh_code_conceal_immediate(bufnr, line)
	end, 10)

	-- 11. 触发事件
	if events then
		local event_data = {
			source = "create_code_link",
			file = path,
			bufnr = bufnr,
			ids = { id },
		}

		if not events.is_event_processing(event_data) then
			events.on_state_changed(event_data)
		end
	end

	-- 12. 自动保存
	if autosave then
		autosave.request_save(bufnr)
	end

	return true
end

--- 创建TODO链接
--- @param path string 文件路径
--- @param line number 行号
--- @param id string 链接ID
--- @param content string 内容
--- @param tag string 标签
--- @return boolean 是否成功
function M.create_todo_link(path, line, id, content, tag)
	if not path or not line or not id then
		vim.notify("创建TODO链接失败：缺少必要参数", vim.log.levels.ERROR)
		return false
	end

	content = content or "新任务"

	if not store or not store.link then
		vim.notify("创建TODO链接失败：无法获取存储模块", vim.log.levels.ERROR)
		return false
	end

	local cleaned_content = content
	cleaned_content = format.clean_content(content, tag or "TODO")

	local success = store.link.add_todo(id, {
		path = path,
		line = line,
		content = cleaned_content,
		tag = tag or "TODO",
		created_at = os.time(),
	})

	return success
end

--- 插入任务行
--- @param bufnr number 缓冲区编号
--- @param lnum number 行号
--- @param options table 选项
--- @return number|nil 新行号
function M.insert_task_line(bufnr, lnum, options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		tag = nil,
		content = "",
		update_store = true,
		trigger_event = true,
		autosave = true,
		event_source = "insert_task_line",
	}, options or {})

	local line_content = format_task_line({
		indent = opts.indent,
		checkbox = opts.checkbox,
		id = opts.id,
		tag = opts.tag,
		content = opts.content,
	})

	-- 插入新行
	vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { line_content })
	local new_line_num = lnum + 1

	-- ⭐ 核心修复：调用存储层的行号偏移功能
	-- 插入点之后的所有任务行号 +1
	if store.link and store.link.handle_line_shift then
		store.link.handle_line_shift(bufnr, new_line_num, 1)
	end

	-- 原有的存储创建逻辑
	if opts.update_store and opts.id then
		local path = vim.api.nvim_buf_get_name(bufnr)
		if path ~= "" then
			M.create_todo_link(path, new_line_num, opts.id, opts.content, opts.tag)
		end
	end

	-- 触发事件
	if opts.trigger_event and opts.id then
		if events then
			local event_data = {
				source = opts.event_source,
				file = vim.api.nvim_buf_get_name(bufnr),
				bufnr = bufnr,
				ids = { opts.id },
			}

			if not events.is_event_processing(event_data) then
				events.on_state_changed(event_data)
			end
		end
	end

	-- 自动保存
	if opts.autosave then
		if autosave then
			autosave.request_save(bufnr)
		end
	end

	return new_line_num, line_content
end

--- 插入TODO任务到文件
--- @param todo_path string TODO文件路径
--- @param id string 链接ID
--- @param task_content string 任务内容
--- @return number|nil 新行号
function M.insert_task_to_todo_file(todo_path, id, task_content)
	todo_path = vim.fn.fnamemodify(todo_path, ":p")

	local bufnr = vim.fn.bufnr(todo_path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(todo_path)
		vim.fn.bufload(bufnr)
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("无法加载 TODO 文件: " .. todo_path, vim.log.levels.ERROR)
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local insert_line = link_utils.find_task_insert_position(lines)

	local content = task_content or "新任务"
	local new_line_num = M.insert_task_line(bufnr, insert_line - 1, {
		indent = "",
		checkbox = "[ ]",
		id = id,
		content = content,
		autosave = true,
	})

	return new_line_num
end

--- 创建子任务
--- @param parent_bufnr number 父任务缓冲区编号
--- @param parent_task table 父任务对象
--- @param child_id string 子任务ID
--- @param content string 子任务内容
--- @param tag string 标签
--- @return number|nil 子任务行号
function M.create_child_task(parent_bufnr, parent_task, child_id, content, tag)
	content = content or "新任务"
	local parent_indent = string.rep("  ", parent_task.level or 0)
	local child_indent = parent_indent .. "  "

	return M.insert_task_line(parent_bufnr, parent_task.line_num, {
		indent = child_indent,
		id = child_id,
		tag = tag,
		content = content,
		event_source = "create_child_task",
	})
end

return M
