-- lua/todo2/link/syncer.lua
--- @module todo2.link.syncer
--- @brief 专业版：只负责同步链接，不直接刷新 UI / code

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- ⭐ 标签管理器（新增）
---------------------------------------------------------------------
local tag_manager = module.get("todo2.utils.tag_manager")

---------------------------------------------------------------------
-- 工具函数：扫描文件中的链接（支持 TAG）
---------------------------------------------------------------------
local function scan_code_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		-- ⭐ 修改：使用tag_manager提取标签
		local tag = tag_manager.extract_from_code_line(line)
		local id = line:match(":ref:(%w+)")
		if id then
			found[id] = {
				line = i,
				tag = tag, -- 保存标签
				content = line, -- 保存完整行
			}
		end
	end
	return found
end

local function scan_todo_links(lines)
	local found = {}
	for i, line in ipairs(lines) do
		local id = line:match("{#(%w+)}")
		if id then
			-- ⭐ 修改：使用tag_manager提取任务内容标签
			local tag = tag_manager.extract_from_task_content(line)

			-- ⭐ 修改：清理内容，移除标签和ID部分
			local cleaned_content = tag_manager.clean_content(line, tag)

			found[id] = {
				line = i,
				content = line, -- 原始行
				cleaned_content = cleaned_content, -- 清理后的内容
				tag = tag, -- 保存标签
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
-- ⭐ 核心修复：确保上下文是新格式
---------------------------------------------------------------------
local function ensure_context_format(ctx)
	if not ctx then
		return nil
	end

	-- 如果已经是新格式（有 raw 和 fingerprint），直接返回
	if ctx.raw and ctx.fingerprint then
		return ctx
	end

	-- ⭐ 修复：使用 context 模块构建上下文
	local context_mod = module.get("store.context")
	if not context_mod then
		return nil
	end

	-- 旧格式1：只有 fingerprint 字段
	if ctx.fingerprint and not ctx.raw then
		local fp = ctx.fingerprint
		return context_mod.build(fp.n_prev or "", fp.n_curr or "", fp.n_next or "")
	end

	-- 旧格式2：直接是 fingerprint 对象
	if ctx.n_curr then
		return context_mod.build(ctx.n_prev or "", ctx.n_curr or "", ctx.n_next or "")
	end

	-- 无法识别的格式，返回空上下文
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

	-- ⭐ 修复：使用正确的模块
	local store_index = require("todo2.store.index")
	local store_link = module.get("store.link")
	local context_mod = module.get("store.context")

	if not store_index or not store_link or not context_mod then
		vim.notify("同步模块未找到", vim.log.levels.ERROR)
		return
	end

	-- ⭐ 修复：使用正确的函数
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
	-- 2. 写入 / 更新 code_link（确保使用新格式）
	-----------------------------------------------------------------
	for id, info in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, info.line)
		local ctx = context_mod.build(prev, curr, next)

		-- 确保上下文是新格式
		ctx = ensure_context_format(ctx)

		local old = store_link.get_code(id, { verify_line = false })

		-- ⭐ 修改：获取清理后的内容
		local cleaned_content = tag_manager.clean_content(info.content, info.tag)

		if old then
			-- ⭐ 关键修复：确保 old.context 也是新格式
			if old.context then
				old.context = ensure_context_format(old.context)
			end

			local need_update = false

			-- 如果 old.context 不存在，需要更新
			if not old.context then
				need_update = true
			else
				-- ⭐ 修复：使用 context_mod.match 比较上下文
				need_update = old.line ~= info.line or not context_mod.match(old.context, ctx)
			end

			-- ⭐ 检查标签是否变化
			if old.tag ~= info.tag then
				need_update = true
			end

			if need_update then
				store_link.add_code(id, {
					path = path,
					line = info.line,
					content = cleaned_content, -- 使用清理后的内容
					tag = info.tag, -- 传递标签
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			store_link.add_code(id, {
				path = path,
				line = info.line,
				content = cleaned_content, -- 使用清理后的内容
				tag = info.tag, -- 传递标签
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- ⭐ 3. 触发事件（不直接刷新） - 修改版
	-----------------------------------------------------------------
	local events = module.get("core.events")
	if not events then
		return
	end

	local ids = {}
	for id, _ in pairs(found) do
		table.insert(ids, id)
	end

	-- 构建事件数据
	local event_data = {
		source = "sync_code_links",
		file = path,
		bufnr = bufnr,
		ids = ids,
	}

	-- 检查是否已经有相同的事件在处理中
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

	-- ⭐ 修复：使用正确的模块
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
	-- 3. 写入 / 更新 todo_link（确保使用新格式）
	-----------------------------------------------------------------
	for id, info in pairs(found) do
		local prev, curr, next = get_context_triplet(lines, info.line)
		local ctx = context_mod.build(prev, curr, next)

		-- 确保上下文是新格式
		ctx = ensure_context_format(ctx)

		local old = store_link.get_todo(id, { verify_line = false })

		-- ⭐ 修改：使用清理后的内容存储（移除标签和ID）
		local cleaned_content = info.cleaned_content

		if old then
			-- ⭐ 关键修复：确保 old.context 也是新格式
			if old.context then
				old.context = ensure_context_format(old.context)
			end

			local need_update = false

			-- 如果 old.context 不存在，需要更新
			if not old.context then
				need_update = true
			else
				-- ⭐ 修复：使用 context_mod.match 比较上下文
				need_update = old.line ~= info.line or old.path ~= path or not context_mod.match(old.context, ctx)
			end

			-- ⭐ 检查标签是否变化
			if old.tag ~= info.tag then
				need_update = true
			end

			-- ⭐ 检查内容是否变化（使用清理后的内容比较）
			if old.content ~= cleaned_content then
				need_update = true
			end

			if need_update then
				store_link.add_todo(id, {
					path = path,
					line = info.line,
					content = cleaned_content, -- 使用清理后的内容
					tag = info.tag, -- 传递标签
					created_at = old.created_at or os.time(),
					context = ctx,
				})
			end
		else
			store_link.add_todo(id, {
				path = path,
				line = info.line,
				content = cleaned_content, -- 使用清理后的内容
				tag = info.tag, -- 传递标签
				created_at = os.time(),
				context = ctx,
			})
		end
	end

	-----------------------------------------------------------------
	-- ⭐ 4. 触发事件（不直接刷新）
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
