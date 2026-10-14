-- lua/todo2/core/parser.lua
-- 最终版：解析器只负责结构，不解析状态，不写入状态

local M = {}

local config = require("todo2.config")
local format = require("todo2.utils.format")
local utils = require("todo2.core.archive_utils")
local description = require("todo2.core.description")
local tree = require("todo2.core.tree")

local INDENT_WIDTH = config.get("parser.indent_width")

---------------------------------------------------------------------
-- 计算层级
---------------------------------------------------------------------
local function compute_level(indent)
	local spaces = type(indent) == "string" and #indent or (indent or 0)
	return math.floor((spaces + INDENT_WIDTH / 2) / INDENT_WIDTH)
end

---------------------------------------------------------------------
-- ⭐ 解析单行任务（不解析状态）
---------------------------------------------------------------------
local function parse_task_line(line, opts)
	opts = opts or {}
	local parsed = format.parse_task_line(line)
	if type(parsed) ~= "table" then
		return nil
	end

	parsed.indent_cols = #(parsed.indent or "")
	parsed.level = compute_level(parsed.indent)

	-- ❗ 不解析状态（status 完全由存储决定）
	parsed.status = nil

	-- 清理非法 ID
	if parsed.id and not parsed.id:match("^[a-zA-Z0-9_][a-zA-Z0-9_-]*$") then
		parsed.id = parsed.id:gsub("[^a-zA-Z0-9_-]", "_")
	end

	-- 上下文指纹（可选）
	if opts.context_fingerprint then
		parsed.context_fingerprint = opts.context_fingerprint
	end

	parsed.context_lines = {}
	parsed.context_before = {}
	parsed.context_after = {}

	return parsed
end

---------------------------------------------------------------------
-- 归档区域检测
---------------------------------------------------------------------
local function detect_archive_sections(lines)
	local sections = {}
	local current_section = nil

	for i, line in ipairs(lines) do
		if utils.is_archive_section_line(line) then
			if current_section then
				current_section.end_line = i - 1
				table.insert(sections, current_section)
			end
			current_section = {
				type = "archive",
				start_line = i,
				title = line,
				month = os.date("%Y-%m"),
				end_line = nil,
			}
		elseif current_section and line:match("^## ") and not utils.is_archive_section_line(line) then
			current_section.end_line = i - 1
			table.insert(sections, current_section)
			current_section = nil
		end
	end

	if current_section then
		current_section.end_line = #lines
		table.insert(sections, current_section)
	end

	return sections
end

---------------------------------------------------------------------
-- 主区域检测
---------------------------------------------------------------------
local function detect_main_regions(lines, empty_line_threshold)
	local regions = {}
	local current_region_start = 1
	local consecutive_empty = 0

	for i = 1, #lines do
		local line = lines[i]
		local is_empty = line:match("^%s*$") ~= nil

		if is_empty then
			consecutive_empty = consecutive_empty + 1
		else
			if consecutive_empty >= (empty_line_threshold or 2) then
				if current_region_start <= i - consecutive_empty - 1 then
					table.insert(regions, {
						type = "main",
						start_line = current_region_start,
						end_line = i - consecutive_empty - 1,
					})
				end
				current_region_start = i
			end
			consecutive_empty = 0
		end
	end

	if current_region_start <= #lines then
		table.insert(regions, {
			type = "main",
			start_line = current_region_start,
			end_line = #lines,
		})
	end

	return regions
end

---------------------------------------------------------------------
-- 构建任务树（不解析状态）
---------------------------------------------------------------------
local function build_task_tree_in_region(lines, path, region_start, region_type)
	local tasks = {}
	local roots = {}
	local stack = {}
	local id_to_task = {}

	for i, line in ipairs(lines) do
		local global_line_num = i + (region_start or 1) - 1

		if format.is_task_line(line) then
			local task = parse_task_line(line, { context_fingerprint = path .. ":" .. global_line_num })
			if task then
				task.line_num = global_line_num
				task.path = path
				task.children = {}
				task.region_type = region_type

				-- 父子关系：只认真实缩进。父节点必须是「最近前驱中缩进恰好少一级」的那个，
				-- 否则标记为显式 orphan，绝不静默挂到最近的更浅前驱（历史漂移根因之一）。
				while #stack > 0 and stack[#stack].indent_cols >= task.indent_cols do
					table.remove(stack)
				end

				local parent = nil
				if task.indent_cols > 0 then
					local top = stack[#stack]
					if top and top.indent_cols + INDENT_WIDTH == task.indent_cols then
						parent = top
					end
				end

				if parent then
					task.parent = parent
					task.orphan = false
					table.insert(parent.children, task)
				else
					task.parent = nil
					task.orphan = task.indent_cols > 0
					table.insert(roots, task)
				end

				table.insert(stack, task)

				table.insert(tasks, task)
				if task.id then
					id_to_task[task.id] = task
				end
			end
		end
	end

	return tasks, roots, id_to_task
end

---------------------------------------------------------------------
-- 主解析入口
---------------------------------------------------------------------
function M.parse_lines(path, lines)
	local cfg = {
		empty_line_reset = config.get("parser.empty_line_reset"),
		context_split = config.get("parser.context_split"),
	}

	local archive_sections = detect_archive_sections(lines)

	-- 主区域行
	local main_lines = {}
	local main_line_mapping = {}
	local in_archive = false
	local current_archive_end = 0

	for i = 1, #lines do
		for _, section in ipairs(archive_sections) do
			if i >= section.start_line and i <= section.end_line then
				in_archive = true
				current_archive_end = section.end_line
				break
			end
		end

		if not in_archive then
			table.insert(main_lines, lines[i])
			main_line_mapping[#main_lines] = i
		end

		if in_archive and i == current_archive_end then
			in_archive = false
		end
	end

	local main_regions = detect_main_regions(main_lines, cfg.empty_line_reset)

	local all_tasks = {}
	local all_roots = {}
	local id_to_task = {}

	for _, region in ipairs(main_regions) do
		local region_lines = {}
		for i = region.start_line, region.end_line do
			table.insert(region_lines, main_lines[i])
		end

		local tasks, roots, id_map =
			build_task_tree_in_region(region_lines, path, main_line_mapping[region.start_line], "main")

		vim.list_extend(all_tasks, tasks)
		vim.list_extend(all_roots, roots)
		for id, t in pairs(id_map) do
			id_to_task[id] = t
		end
	end

	-- 归档区域
	local archive_trees = {}
	for _, section in ipairs(archive_sections) do
		local section_lines = {}
		for i = section.start_line + 1, section.end_line do
			if lines[i] and not lines[i]:match("^%s*$") then
				table.insert(section_lines, lines[i])
			end
		end

		local tasks, roots, id_map = build_task_tree_in_region(section_lines, path, section.start_line + 1, "archive")

		archive_trees[section.month or tostring(section.start_line)] = {
			tasks = tasks,
			roots = roots,
			id_to_task = id_map,
			start_line = section.start_line,
			end_line = section.end_line,
			title = section.title,
		}

		for id, t in pairs(id_map) do
			id_to_task[id] = t
		end
	end

	-- 任务正文（缩进续行）：独立扫描整个文件，按行号挂到对应任务。
	-- 独立于 region/archive 切分，这样跨空行的多段正文也能完整收全。
	local blocks = description.scan(lines)
	for _, task in ipairs(all_tasks) do
		local block = blocks[task.line_num]
		if block then
			task.description = block.text
			task.description_lines = {}
			for j = block.start_line, block.end_line do
				task.description_lines[#task.description_lines + 1] = lines[j]
			end
		end
	end

	return all_tasks, all_roots, id_to_task, archive_trees
end

--- 解析文件为不可变森林（结构层入口）
---@param path string
---@param lines string[]
---@return todo2.Forest
function M.parse(path, lines)
	local tasks, roots, id_to_task, archive_trees = M.parse_lines(path, lines)
	return tree.from_parser(path, lines, {
		tasks = tasks,
		roots = roots,
		id_to_task = id_to_task,
		archive_trees = archive_trees,
	})
end

return M
