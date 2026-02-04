-- lua/todo2/core/utils.lua
--- @module todo2.core.utils
--- @brief 统一的工具函数模块

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 公共常量
---------------------------------------------------------------------
local TASK_PATTERN = "^%s*%-%s*%[%s*%]%s*(.*)"
local DONE_PATTERN = "^%s*%-%s*%[x%]%s*(.*)"
local ID_PATTERN = "{#([%w%-]+)}"

---------------------------------------------------------------------
-- 任务行格式化（保留，这是真正的工具函数）
---------------------------------------------------------------------

--- 格式化任务行
--- @param options table 任务选项
--- @return string 格式化后的任务行
function M.format_task_line(options)
	local opts = vim.tbl_extend("force", {
		indent = "",
		checkbox = "[ ]",
		id = nil,
		tag = nil, -- 新增：标签参数
		content = "",
	}, options or {})

	local parts = { opts.indent, "- ", opts.checkbox }

	-- ⭐ 修改：如果有标签和ID，格式为 标签{#id}
	if opts.tag and opts.id then
		table.insert(parts, " ")
		table.insert(parts, opts.tag .. "{#" .. opts.id .. "}")
	elseif opts.id then
		-- 如果没有标签，只有ID
		table.insert(parts, " {#" .. opts.id .. "}")
	end

	-- 添加内容（应该是纯文本，不包含标签）
	if opts.content and opts.content ~= "" then
		-- 先清理内容中可能存在的标签前缀
		local clean_content = opts.content
		-- 移除 [TAG] 或 TAG: 前缀
		if opts.tag then
			clean_content = clean_content:gsub("^%[" .. opts.tag .. "%]%s*", "")
			clean_content = clean_content:gsub("^" .. opts.tag .. ":%s*", "")
			clean_content = clean_content:gsub("^" .. opts.tag .. "%s+", "")
		end

		if clean_content ~= "" then
			table.insert(parts, " ")
			table.insert(parts, clean_content)
		end
	end

	return table.concat(parts, "")
end

---------------------------------------------------------------------
-- 任务ID处理（保留）
---------------------------------------------------------------------

--- 确保任务有ID
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @param task table 任务对象（可选）
--- @return string|nil 任务ID
function M.ensure_task_id(bufnr, lnum, task)
	-- 如果传入了任务对象，且已有ID，直接返回
	if task and task.id then
		return task.id
	end

	-- 否则获取解析器解析当前行
	local parser = module.get("core.parser")
	if not parser then
		vim.notify("无法获取 parser 模块", vim.log.levels.ERROR)
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	local parsed_task = parser.parse_task_line(line)

	if not parsed_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return nil
	end

	if parsed_task.id then
		return parsed_task.id
	end

	-- 生成新ID
	local link_module = module.get("link")
	if not link_module then
		vim.notify("无法获取 link 模块", vim.log.levels.ERROR)
		return nil
	end

	local new_id = link_module.generate_id()
	if not new_id then
		vim.notify("无法生成任务ID", vim.log.levels.ERROR)
		return nil
	end

	return new_id
end

---------------------------------------------------------------------
-- 从任务内容提取标签（保留）
---------------------------------------------------------------------

--- 从TODO内容提取标签
--- @param content string 任务内容
--- @return string 标签
function M.extract_tag_from_content(content)
	local tag = content:match("^%[([A-Z]+)%]") or content:match("^([A-Z]+):") or content:match("^([A-Z]+)%s")
	return tag or "TODO"
end

---------------------------------------------------------------------
-- 获取任务状态（保留）
---------------------------------------------------------------------

--- 获取任务状态
--- @param task table 任务对象
--- @return string, boolean 状态图标, 是否完成
function M.get_task_status(task)
	if not task then
		return nil
	end
	return task.is_done and "✓" or "☐", task.is_done
end

---------------------------------------------------------------------
-- 获取任务文本（带截断）（保留）
---------------------------------------------------------------------

--- 获取任务文本
--- @param task table 任务对象
--- @param max_len number 最大长度（可选）
--- @return string|nil 任务文本
function M.get_task_text(task, max_len)
	if not task then
		return nil
	end

	local text = task.content or ""
	max_len = max_len or 40

	-- 去除首尾空白
	text = text:gsub("^%s+", ""):gsub("%s+$", "")

	-- 计算 UTF-8 字符长度
	local char_len = vim.str_utfindex(text)

	-- 如果长度在限制内，直接返回
	if char_len <= max_len then
		return text
	end

	-- 计算截断位置（留出3个字符给省略号）
	local byte_index = vim.str_byteindex(text, max_len - 3, true)

	-- 安全截断并添加省略号
	return text:sub(1, byte_index or #text) .. "..."
end

---------------------------------------------------------------------
-- 获取任务进度（保留）
---------------------------------------------------------------------

--- 获取任务进度
--- @param task table 任务对象
--- @return table|nil 进度信息
function M.get_task_progress(task)
	if not task or not task.children or #task.children == 0 then
		return nil
	end

	local done, total = 0, 0

	for _, child in ipairs(task.children) do
		if child.is_done ~= nil then
			total = total + 1
			if child.is_done then
				done = done + 1
			end
		end
	end

	if total == 0 then
		return nil
	end

	return {
		done = done,
		total = total,
		percent = math.floor(done / total * 100),
	}
end

---------------------------------------------------------------------
-- 通用工具函数（简化）
---------------------------------------------------------------------

--- 获取行缩进
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @return string 缩进字符串
function M.get_line_indent(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return line:match("^(%s*)") or ""
end

--- 获取当前行的任务信息
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @return table|nil 任务信息
function M.get_task_at_line(bufnr, lnum)
	local parser = module.get("core.parser")
	if not parser then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return parser.parse_task_line(line)
end

return M
