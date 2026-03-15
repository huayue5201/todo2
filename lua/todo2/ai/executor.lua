-- lua/todo2/ai/executor.lua
-- 执行链（流式执行 + 任务链语义增强）

local M = {}

local context = require("todo2.ai.context")
local prompt = require("todo2.ai.prompt")

-- ⭐ 已迁移：使用新的策略化流式引擎
local apply_stream = require("todo2.ai.stream.engine")

local core = require("todo2.store.link.core")
local ai = require("todo2.ai")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 从任务构造兼容的 link 对象
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 流式执行：边生成边写入（不阻塞 UI）
---------------------------------------------------------------------
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
	-- 3. 构建 Prompt
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
	-- 4. 初始化流式应用器（使用新 engine）
	-----------------------------------------------------------------
	local ok_init, err_init = apply_stream.start({
		path = code_link.path,
		ctx = ctx,
		code_link = code_link,
		todo = todo,
	})
	if not ok_init then
		return { ok = false, error = "流式应用初始化失败：" .. tostring(err_init) }
	end

	-----------------------------------------------------------------
	-- 5. 完成回调
	-----------------------------------------------------------------
	local function on_done()
		vim.schedule(function()
			local success = false

			local ok_finish, err_finish, final_ctx = apply_stream.finish()

			if not ok_finish then
				vim.notify("流式补丁应用失败：" .. tostring(err_finish), vim.log.levels.ERROR)
			else
				success = true

				-- 更新行号（shift）
				local old_line = code_link.line
				local new_line = (final_ctx and final_ctx.start_line) or (ctx.start_line or old_line)
				local offset = new_line - old_line
				if offset ~= 0 then
					local link = require("todo2.store.link")
					link.shift_lines(code_link.path, old_line, offset)
				end

				vim.notify("AI 已完成流式生成 ✓", vim.log.levels.INFO)
			end

			events.on_state_changed({
				source = "ai_task_complete",
				ids = { id },
				data = { success = success },
			})

			if opts.on_done then
				opts.on_done(id, success)
			end
		end)
	end

	-----------------------------------------------------------------
	-- 6. chunk 处理
	-----------------------------------------------------------------
	local function on_chunk(chunk)
		apply_stream.on_chunk(chunk)
	end

	-----------------------------------------------------------------
	-- 7. 调用 AI 流式生成
	-----------------------------------------------------------------
	local ok_stream, err_stream = ai.generate_stream(p, on_chunk, on_done)

	if not ok_stream then
		apply_stream.abort()

		events.on_state_changed({
			source = "ai_task_complete",
			ids = { id },
			data = { success = false, error = err_stream },
		})

		if opts.on_done then
			opts.on_done(id, false)
		end

		return { ok = false, error = "AI 流式生成启动失败：" .. tostring(err_stream) }
	end

	return { ok = true, async = true }
end

return M
