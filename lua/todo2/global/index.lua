-- lua/todo2/global/index.lua
-- 全局任务索引：只读扫描 vault 下所有项目的 TODO 文件。
--
-- 为什么直接解析文件而不是读 store：
--   * store 绑定 cwd（nvim_store 按项目隔离），跨项目读取等于绕过隔离边界；
--   * 文件本来就是唯一真源，parser 不依赖 store，扫描结果天然与磁盘一致。
-- 代价是每次扫描都要读盘（几十个项目、毫秒级），换来的是一条干净的边界：
-- 全局层永不写别人的项目。

local M = {}

local project_utils = require("todo2.utils.project")
local file_utils = require("todo2.utils.file")
local parser = require("todo2.core.parser")
local types = require("todo2.store.types")
local ref_utils = require("todo2.global.ref")

---项目目录下的全部 TODO 文件（去重、排序，保证渲染顺序稳定）
---@param dir string
---@return string[]
local function todo_files(dir)
	local seen, list = {}, {}
	for _, glob in ipairs(file_utils.todo_globs()) do
		for _, path in ipairs(vim.fn.globpath(dir, glob, false, true)) do
			if not seen[path] then
				seen[path] = true
				list[#list + 1] = path
			end
		end
	end
	table.sort(list)
	return list
end

---任务是否已结束（完成 / 归档）
---@param status string|nil
---@return boolean
function M.is_done(status)
	return types.is_completed_status(status)
end

---扫描全部项目。
---@return { projects: table[], entries: table[], by_qref: table<string, table> }
function M.scan()
	local projects = project_utils.list_projects()
	local entries, by_qref = {}, {}

	for _, proj in ipairs(projects) do
		for _, path in ipairs(todo_files(proj.dir)) do
			local lines = file_utils.read_lines_smart(path)
			if lines then
				local tasks, _, _, archive_trees = parser.parse_lines(path, lines)
				local function add(raw)
					if not raw.id then
						return
					end
					local entry = {
						project = proj.name,
						label = proj.label or proj.name,
						root = proj.root,
						id = raw.id,
						content = raw.content,
						status = raw.status,
						tags = raw.tags or {},
						start = raw.start,
						due = raw.due,
						rels = raw.rels or {},
						path = path,
						line = raw.line_num,
						outgoing = {},
						incoming = {},
						blocked = 0,
						dangling = 0,
					}
					entries[#entries + 1] = entry
					by_qref[ref_utils.qref(proj.name, raw.id)] = entry
				end

				for _, raw in ipairs(tasks) do
					add(raw)
				end
				for _, section in pairs(archive_trees or {}) do
					for _, raw in ipairs(section.tasks or {}) do
						add(raw)
					end
				end
			end
		end
	end

	-- 第二遍：解析关系，建立反向边。
	-- 反向边只存在于内存视图里——对方的文件不该被我们改写。
	for _, entry in ipairs(entries) do
		for _, token in ipairs(entry.rels) do
			local r = ref_utils.parse(token)
			local target = r and by_qref[ref_utils.qref(r.project, r.id)] or nil
			entry.outgoing[#entry.outgoing + 1] = { kind = r.kind, target = target, token = token }
			if target then
				target.incoming[#target.incoming + 1] = { kind = r.kind, source = entry, token = token }
			else
				entry.dangling = entry.dangling + 1
			end
		end
	end

	-- 派生：被多少个**未完成**的上游任务阻塞
	for _, entry in ipairs(entries) do
		entry.active = not M.is_done(entry.status)
		for _, edge in ipairs(entry.incoming) do
			if edge.kind == "blocks" and not M.is_done(edge.source.status) then
				entry.blocked = entry.blocked + 1
			end
		end
	end

	table.sort(projects, function(a, b)
		return (a.label or a.name):lower() < (b.label or b.name):lower()
	end)

	return { projects = projects, entries = entries, by_qref = by_qref }
end

---渲染全局视图的文本行 + 标题 + 行号→条目映射。
---项目标题行在映射里是 `{ project_header = true }`，其余行是任务条目。
---@param data table M.scan() 的结果
---@param opts? { mark?: fun(entry: table): string } `mark` 返回任务行的前导两列（默认两个空格）
---@return string header
---@return string[] lines
---@return table<integer, table> row_entry
function M.render_lines(data, opts)
	local mark = opts and opts.mark
	local groups = {}
	for _, entry in ipairs(data.entries) do
		groups[entry.project] = groups[entry.project] or { entries = {}, done = 0 }
		local g = groups[entry.project]
		if entry.active then
			g.entries[#g.entries + 1] = entry
		else
			g.done = g.done + 1
		end
	end

	local label_count = {}
	for _, proj in ipairs(data.projects) do
		local label = proj.label or proj.name
		label_count[label] = (label_count[label] or 0) + 1
	end

	local lines, row_entry = {}, {}
	local active_total, group_count = 0, 0

	for _, proj in ipairs(data.projects) do
		local g = groups[proj.name]
		if g and #g.entries > 0 then
			local label = proj.label or proj.name
			-- 同名目录（basename 相同、identity 不同）必须靠项目名区分，否则 :TodoRel 无解
			if label_count[label] > 1 then
				label = ("%s (%s)"):format(label, proj.name)
			end
			table.sort(g.entries, function(a, b)
				if a.blocked ~= b.blocked then
					return a.blocked > b.blocked
				end
				if (a.due or "") ~= (b.due or "") then
					return (a.due or "9999-99-99") < (b.due or "9999-99-99")
				end
				return a.id < b.id
			end)

			local done_note = g.done > 0 and ("  (%d done)"):format(g.done) or ""
			lines[#lines + 1] = ("%s  %d"):format(label, #g.entries) .. done_note
			row_entry[#lines] = { project_header = true }
			active_total = active_total + #g.entries
			group_count = group_count + 1

			for _, entry in ipairs(g.entries) do
				local marks = {}
				if entry.blocked > 0 then
					marks[#marks + 1] = ("blocked×%d"):format(entry.blocked)
				end
				if entry.dangling > 0 then
					marks[#marks + 1] = ("dangling×%d"):format(entry.dangling)
				end
				local rel_n = #entry.outgoing + #entry.incoming
				if rel_n > 0 then
					marks[#marks + 1] = ("rel×%d"):format(rel_n)
				end

				local parts = { (mark and mark(entry) or "  ") .. entry.id, entry.content or "" }
				if #entry.tags > 0 then
					parts[#parts + 1] = "#" .. table.concat(entry.tags, " #")
				end
				if entry.due then
					parts[#parts + 1] = entry.due
				end
				if #marks > 0 then
					parts[#parts + 1] = table.concat(marks, " ")
				end
				lines[#lines + 1] = table.concat(parts, "  ")
				row_entry[#lines] = entry
			end

			lines[#lines + 1] = ""
			lines[#lines + 1] = ""
		end
	end

	-- 去掉末尾多余空行（空行本来就没有行号映射，不要顺手把上一行的映射删掉）
	while lines[#lines] == "" do
		table.remove(lines)
	end

	local header = ("todo2 · global · %d active task(s) in %d project(s)"):format(active_total, group_count)
	return header, lines, row_entry
end

return M
