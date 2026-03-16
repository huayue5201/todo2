-- lua/todo2/ai/executor.lua
-- 执行链（流式执行 + 错误反馈）

local M = {}

local context = require("todo2.ai.context")
local prompt = require("todo2.ai.prompt")
local apply_stream = require("todo2.ai.stream.engine")
local core = require("todo2.store.link.core")
local ai = require("todo2.ai")
local events = require("todo2.core.events")
local error_handler = require("todo2.ai.stream.error_handler")

local function task_to_todo_link(task)
	if not task or not task.locations.todo then
		return nil
	end
	return {
		id = task.id,
		path = task.locations.todo.path,
		line = task.locations.todo.line,
		content = task.core.content,
		tag = task.core.tags[1],
		status = task.core.status,
		ai_executable = task.core.ai_executable,
	}
end

local function task_to_code_link(task)
	if not task or not task.locations.code then
		return nil
	end
	return {
		id = task.id,
		path = task.locations.code.path,
		line = task.locations.code.line,
		content = task.core.content,
		tag = task.core.tags[1],
		status = task.core.status,
		ai_executable = task.core.ai_executable,
		context = task.locations.code.context,
	}
end

function M.run_stream(id, opts)
	opts = opts or {}

	-----------------------------------------------------------------
	-- 1. 获取任务
	-----------------------------------------------------------------
	local task = core.get_task(id)
	if not task then
		return { ok = false, error = "找不到任务：" .. id }
	end

	local todo = task_to_todo_link(task)
	local code_link = task_to_code_link(task)

	if not todo then
		return { ok = false, error = "找不到 TODO 位置：" .. id }
	end
	if not code_link then
		return { ok = false, error = "找不到 CODE 位置：" .. id }
	end

	-----------------------------------------------------------------
	-- 2. 收集代码上下文
	-----------------------------------------------------------------
	local ctx = context.collect(code_link)
	if not ctx then
		return { ok = false, error = "无法收集上下文" }
	end

	-----------------------------------------------------------------
	-- 3. 构建 Prompt（使用新协议）
	-----------------------------------------------------------------
	local p = prompt.build({
		task_id = id,
		task_content = todo.content or "",
		file_path = code_link.path,
		code_context = ctx.code or "",
		replace_start = ctx.start_line,
		replace_end = ctx.end_line,
	})

	-----------------------------------------------------------------
	-- 4. 初始化流式应用器
	-- ⭐ 修复：engine.start() 返回 (ok, task_id, err) 但第三个参数可能为空
	-----------------------------------------------------------------
	local ok_init, task_id, err_init = apply_stream.start({
		path = code_link.path,
		ctx = ctx,
		code_link = code_link,
		todo = todo,
	})

	if not ok_init then
		return { ok = false, error = "流式应用初始化失败：" .. tostring(err_init or "未知错误") }
	end

	-- 确保 task_id 存在
	if not task_id then
		return { ok = false, error = "流式应用未返回任务ID" }
	end

	-----------------------------------------------------------------
	-- 5. 完成回调
	-----------------------------------------------------------------
	local function on_done()
		vim.schedule(function()
			-- ⭐ 修复：engine.finish() 返回 (ok, err, final_ctx)
			local ok_finish, err_finish, final_ctx = apply_stream.finish(task_id)

			if not ok_finish then
				local msg = error_handler.format(err_finish or "未知错误")
				vim.notify("AI 流式执行失败：" .. msg, vim.log.levels.ERROR)

				events.on_state_changed({
					source = "ai_task_complete",
					ids = { id },
					data = { success = false, error = msg },
				})

				if opts.on_done then
					opts.on_done(id, false)
				end
				return
			end

			-- 成功：处理行号偏移
			local old_line = code_link.line
			local new_line = (final_ctx and final_ctx.start_line) or ctx.start_line
			local offset = new_line - old_line

			if offset ~= 0 then
				local link = require("todo2.store.link")
				link.shift_lines(code_link.path, old_line, offset)
			end

			vim.notify("AI 已完成流式生成 ✓", vim.log.levels.INFO)

			events.on_state_changed({
				source = "ai_task_complete",
				ids = { id },
				data = { success = true },
			})

			if opts.on_done then
				opts.on_done(id, true)
			end
		end)
	end

	-----------------------------------------------------------------
	-- 6. chunk 处理
	-----------------------------------------------------------------
	local function on_chunk(chunk)
		-- 修复：确保传入 task_id
		if chunk and chunk ~= "" then
			apply_stream.on_chunk(task_id, chunk)
		end
	end

	-----------------------------------------------------------------
	-- 7. 调用 AI 流式生成
	-----------------------------------------------------------------
	local ok_stream, err_stream = ai.generate_stream(p, on_chunk, on_done)

	if not ok_stream then
		-- 启动失败，清理任务
		apply_stream.abort(task_id)
		local msg = error_handler.format(err_stream or "未知错误")

		events.on_state_changed({
			source = "ai_task_complete",
			ids = { id },
			data = { success = false, error = msg },
		})

		if opts.on_done then
			opts.on_done(id, false)
		end

		return { ok = false, error = "AI 流式生成启动失败：" .. msg }
	end

	return { ok = true, async = true, task_id = task_id }
end

return M
