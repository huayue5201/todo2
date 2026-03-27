-- lua/todo2/ai/executor.lua
-- 执行链：收集上下文 → 构建 Prompt → 流式执行 → 写入代码

local M = {}

local context = require("todo2.ai.context")
local prompt = require("todo2.ai.prompt")
local stream = require("todo2.ai.stream.engine")
local core = require("todo2.store.link.core")
local ai = require("todo2.ai")
local events = require("todo2.core.events")
local error_handler = require("todo2.ai.stream.error_handler")
-- ✅ 不再需要 link 模块

--- 从任务构建 TODO 链接
--- @param task table
--- @return table|nil
local function to_todo_link(task)
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

--- 从任务构建代码链接
--- @param task table
--- @return table|nil
local function to_code_link(task)
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

--- 执行 AI 流式任务
--- @param id string 任务 ID
--- @param opts table 选项 { debug = boolean, on_done = function, max_children = number, max_semantic = number }
--- @return table { ok = boolean, error = string, async = boolean, task_id = string }
function M.run_stream(id, opts)
	opts = opts or {}

	-- 1. 获取任务
	local task = core.get_task(id)
	if not task then
		return { ok = false, error = "找不到任务：" .. id }
	end

	-- 2. 验证代码位置
	if not task.locations.code then
		return {
			ok = false,
			error = string.format(
				"任务 %s 没有代码标记！\n请在代码文件中添加：\n// TODO2 %s <任务描述>",
				id,
				id
			),
		}
	end

	local todo = to_todo_link(task)
	local code_link = to_code_link(task)

	if not todo then
		return { ok = false, error = "找不到 TODO 位置：" .. id }
	end
	if not code_link then
		return { ok = false, error = "找不到 CODE 位置：" .. id }
	end

	-- 3. 收集增强上下文
	local ctx = context.collect_enhanced(code_link, id, {
		max_children = opts.max_children or 5,
		max_semantic = opts.max_semantic or 3,
		include_code = true,
	})

	if not ctx then
		return { ok = false, error = "无法收集增强上下文" }
	end

	-- 4. 构建 Prompt
	local prompt_text = prompt.build_from_context(ctx, {
		task_id = id,
		task_content = todo.content or "",
		file_path = code_link.path,
	})
	print("🪚 prompt_text: " .. tostring(prompt_text))

	if opts.debug then
		print("=== AI Prompt ===\n" .. prompt_text .. "\n=== End ===")
	end

	-- 5. 初始化流式引擎
	local ok, stream_id, err = stream.start({
		path = code_link.path,
		ctx = { start_line = ctx.start_line, end_line = ctx.end_line },
		code_link = code_link,
		todo = todo,
	})

	if not ok then
		return { ok = false, error = "流式引擎初始化失败：" .. tostring(err or "未知错误") }
	end

	-- 6. 完成回调
	local function on_done()
		vim.schedule(function()
			local ok_finish, err_finish, final_ctx = stream.finish(stream_id)

			if not ok_finish then
				local msg = error_handler.format(err_finish or "未知错误")
				vim.notify("AI 执行失败：" .. msg, vim.log.levels.ERROR)

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

			-- ✅ 不需要行号偏移！签名哈希定位会处理
			vim.notify("AI 已完成生成 ✓", vim.log.levels.INFO)

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

	-- 7. 流式回调
	local function on_chunk(chunk)
		if chunk and chunk ~= "" then
			stream.on_chunk(stream_id, chunk)
		end
	end

	-- 8. 调用 AI 生成
	local ok_stream, err_stream = ai.generate_stream(prompt_text, on_chunk, on_done)

	if opts.debug then
		print("AI Stream Start: " .. tostring(ok_stream))
		if err_stream then
			print("AI Stream Error: " .. tostring(err_stream))
		end
	end

	if not ok_stream then
		stream.abort(stream_id)
		local msg = error_handler.format(err_stream or "未知错误")

		events.on_state_changed({
			source = "ai_task_complete",
			ids = { id },
			data = { success = false, error = msg },
		})

		if opts.on_done then
			opts.on_done(id, false)
		end

		return { ok = false, error = "AI 生成启动失败：" .. msg }
	end

	return { ok = true, async = true, task_id = stream_id }
end

return M
