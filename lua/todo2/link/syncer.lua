--- File: /Users/lijia/todo2/lua/todo2/link/syncer.lua ---
-- lua/todo2/link/syncer.lua
--- @module todo2.link.syncer
--- @brief 专业版：只负责同步链接，不直接刷新 UI / code

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- ⭐ 标签管理器
---------------------------------------------------------------------
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- ⭐ 导入存储类型常量（用于状态解析）
---------------------------------------------------------------------
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 工具函数：扫描文件中的链接（支持 TAG）
---------------------------------------------------------------------
local function scan_code_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local tag = tag_manager.extract_from_code_line(line)
		local id = line:match(":ref:(%w+)")
		if id then
			found[id] = {
				line = i,
				tag = tag,
				content = line,
			}
		end
	end
	return found
end

-- ⭐ 修复：扫描 TODO 链接时解析状态
local function scan_todo_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local id = line:match("{#(%w+)}")
		if id then
			local tag = tag_manager.extract_from_task_content(line)
			local cleaned_content = tag_manager.clean_content(line, tag)

			-- ✅ 从行内容解析状态
			local status = types.STATUS.NORMAL -- 默认
			if line:match("%[!%]") then
				status = types.STATUS.URGENT
			elseif line:match("%[%?%]") then
				status = types.STATUS.WAITING
			elseif line:match("%[x%]") then
				status = types.STATUS.COMPLETED
			elseif line:match("%[>%]") then
				status = types.STATUS.ARCHIVED
			end

			found[id] = {
				line = i,
				content = line,
				cleaned_content = cleaned_content,
				tag = tag,
				status = status, -- ✅ 添加状态字段
			}
		end
	end
	return found
end

local function get_context_triplet(lines, lnum)
	local prev = lines[lnum - 1] or ""
	local curr = lines[lnum] or ""
	local next = lines[lnum + 1] or ""
	return prev, curr, next
end

---------------------------------------------------------------------
-- 确保上下文是新格式
---------------------------------------------------------------------
local function ensure_context_format(ctx)
	if not ctx then
		return nil
	end
	if ctx.raw and ctx.fingerprint then
		return ctx
	end
	local context_mod = module.get("store.context")
	if not context_mod then
		return nil
	end
	if ctx.fingerprint and not ctx.raw then
		local fp = ctx.fingerprint
		return context_mod.build(fp.n_prev or "", fp.n_curr or "", fp.n_next or "")
	end
	if ctx.n_curr then
		return context_mod.build(ctx.n_prev or "", ctx.n_curr or "", ctx.n_next or "")
	end
	return context_mod.build("", "", "")
end

---------------------------------------------------------------------
-- ⭐ 同步：代码文件（代码 → TODO）
---------------------------------------------------------------------
function M.sync_code_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = scan_code_links(lines)

	local store_index = require("todo2.store.index")
	local store_link = module.get("store.link")
	local context_mod = module.get("store.context")

	if not store_index or not store_link or not context_mod then
		vim.notify("同步模块未找到", vim.log.levels.ERROR)
		return
	end

	local existing = store_index.find_code_links_by_file(path)

	-----------------------------------------------------------------
	-- 1. 删除文件中已不存在的 code_link
	-----------------------------------------------------------------
	for _, link in ipairs(existing) do
		if not found[link.id] then
			store_link.delete_code(link.id)
		end
	end

	-----------------------------------------------------------------
	-- 2. 写入 / 更新 code_link
	-----------------------------------------------------------------
	for id, info in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, info.line)
		local ctx = context_mod.build(prev, curr, next)
		ctx = ensure_context_format(ctx)

		local old = store_link.get_code(id, { verify_line = false })
		local cleaned_content = tag_manager.clean_content(info.content, info.tag)

		if old then
			if old.context then
				old.context = ensure_context_format(old.context)
			end

			local need_update = false
			if not old.context then
				need_update = true
			else
				need_update = old.line ~= info.line or not context_mod.match(old.context, ctx)
			end
			if old.tag ~= info.tag then
				need_update = true
			end

			if need_update then
				-- ✅ 关键修复：保留原有状态，防止被重置为 normal
				store_link.add_code(id, {
					path = path,
					line = info.line,
					content = cleaned_content,
					tag = info.tag,
					status = old.status, -- ⭐ 保留状态
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			-- 新链接：使用默认状态 normal（代码链接状态由 TODO 链接决定）
			store_link.add_code(id, {
				path = path,
				line = info.line,
				content = cleaned_content,
				tag = info.tag,
				status = types.STATUS.NORMAL,
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- 3. 触发事件
	-----------------------------------------------------------------
	local events = module.get("core.events")
	if not events then
		return
	end

	local ids = {}
	for id, _ in pairs(found) do
		table.insert(ids, id)
	end

	local event_data = {
		source = "sync_code_links",
		file = path,
		bufnr = bufnr,
		ids = ids,
	}
	if not events.is_event_processing(event_data) then
		events.on_state_changed(event_data)
	end
end

---------------------------------------------------------------------
-- ⭐ 同步：TODO 文件（TODO → 代码）
---------------------------------------------------------------------
function M.sync_todo_links()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
	if path == "" then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if #lines == 0 then
		return
	end

	local store_index = require("todo2.store.index")
	local store_link = module.get("store.link")
	local context_mod = module.get("store.context")

	if not store_index or not store_link or not context_mod then
		vim.notify("同步模块未找到", vim.log.levels.ERROR)
		return
	end

	-----------------------------------------------------------------
	-- 1. 扫描当前文件中的 {#id}
	-----------------------------------------------------------------
	local found = scan_todo_links(lines)

	-----------------------------------------------------------------
	-- 2. 清理：删除 store 中指向本文件、但已不存在的 todo_link
	-----------------------------------------------------------------
	local existing_links = store_index.find_todo_links_by_file(path)
	for _, link in ipairs(existing_links) do
		if not found[link.id] then
			store_link.delete_todo(link.id)
		end
	end

	-----------------------------------------------------------------
	-- 3. 写入 / 更新 todo_link
	-----------------------------------------------------------------
	for id, info in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, info.line)
		local ctx = context_mod.build(prev, curr, next)
		ctx = ensure_context_format(ctx)

		local old = store_link.get_todo(id, { verify_line = false })
		local cleaned_content = info.cleaned_content

		if old then
			if old.context then
				old.context = ensure_context_format(old.context)
			end

			local need_update = false
			if not old.context then
				need_update = true
			else
				need_update = old.line ~= info.line or old.path ~= path or not context_mod.match(old.context, ctx)
			end
			if old.tag ~= info.tag then
				need_update = true
			end
			if old.content ~= cleaned_content then
				need_update = true
			end

			if need_update then
				-- ✅ 关键修复：保留原有状态
				store_link.add_todo(id, {
					path = path,
					line = info.line,
					content = cleaned_content,
					tag = info.tag,
					status = old.status, -- ⭐ 保留状态
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			-- ✅ 新建链接：使用从文件解析的状态
			store_link.add_todo(id, {
				path = path,
				line = info.line,
				content = cleaned_content,
				tag = info.tag,
				status = info.status or types.STATUS.NORMAL, -- ⭐ 解析状态
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- 4. 触发事件
	-----------------------------------------------------------------
	local events = module.get("core.events")
	if not events then
		return
	end

	local ids = {}
	for id, _ in pairs(found) do
		table.insert(ids, id)
	end

	events.on_state_changed({
		source = "sync_todo_links",
		file = path,
		bufnr = bufnr,
		ids = ids,
	})
end

return M
