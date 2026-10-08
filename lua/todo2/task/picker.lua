-- lua/todo2/task/picker.lua
-- 代码端「同一锚点多任务」的统一二次选择：0 个不处理，1 个直取，多个弹 vim.ui.select。

local M = {}

local core = require("todo2.store.task.core")
local index = require("todo2.store.index")
local hierarchy = require("todo2.store.task.hierarchy")
local checkbox = require("todo2.render.checkbox")
local file = require("todo2.utils.file")
local id_utils = require("todo2.utils.id")

--- 收集指定代码行上的候选任务（排除已失联锚点，与渲染一致）。
---@param path string
---@param lnum number
---@return table[]
function M.candidates(path, lnum)
	local result = {}
	for _, task in ipairs(index.find_code_links_by_file(path)) do
		local loc = task.locations and task.locations.code
		if loc and loc.line == lnum and not core.is_anchor_lost(task) then
			result[#result + 1] = task
		end
	end
	return result
end

--- 选择项显示标签：层级缩进 + 复选框图标 + 内容 + 状态。
---@param entry { task: table, depth: number }
---@return string
local function format_item(entry)
	local task, depth = entry.task, entry.depth or 0
	local content = task.core.content ~= "" and task.core.content or task.id
	return string.format(
		"%s%s%s  [%s]",
		string.rep("  ", depth),
		depth > 0 and "└ " or "",
		checkbox.get(task.core.status) .. " " .. content,
		task.core.status
	)
end

--- 弹选择并回调（仅候选非空时回调）。
---@param candidates table[]
---@param cb fun(task: table)
---@param prompt? string
---@return boolean handled
function M.select(candidates, cb, prompt)
	if #candidates == 0 then
		return false
	elseif #candidates == 1 then
		cb(candidates[1])
		return true
	end
	vim.ui.select(hierarchy.build(candidates), {
		prompt = prompt or "Multiple tasks on this line; choose:",
		format_item = format_item,
	}, function(entry)
		if entry then
			cb(entry.task)
		end
	end)
	return true
end

--- 统一入口：解析光标处任务，代码文件多锚点时二次选择。
--- `none_msg` 为 false 时不提示；为字符串时用作提示文案。
---@param opts? { bufnr?: number, lnum?: number, prompt?: string, none_msg?: string|false }
---@param cb fun(task: table)
---@return boolean handled
function M.pick(opts, cb)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local lnum = opts.lnum or vim.fn.line(".")
	local path = vim.api.nvim_buf_get_name(bufnr)

	local candidates
	if file.is_todo_file(path) then
		local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
		local id = id_utils.extract_id_from_line(line)
		local task = id and core.get_task(id)
		candidates = task and { task } or {}
	else
		candidates = path ~= "" and M.candidates(path, lnum) or {}
	end

	if #candidates == 0 then
		if opts.none_msg ~= false then
			vim.notify(opts.none_msg or "No linked task on the current line", vim.log.levels.WARN)
		end
		return false
	end
	return M.select(candidates, cb, opts.prompt)
end

return M
