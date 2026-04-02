-- lua/todo2/ai/executor.lua
-- 执行链：上下文 → Prompt → 行为类型 → request_id → gateway → stream

local M = {}

local context = require("todo2.ai.context")
local prompt = require("todo2.ai.prompt")
local stream = require("todo2.ai.stream.engine")
local core = require("todo2.store.link.core")
local gateway = require("todo2.ai.gateway")
local events = require("todo2.core.events")
local error_handler = require("todo2.ai.stream.error_handler")
local registry = require("todo2.ai.prompt.strategy_registry")

---------------------------------------------------------------------
-- 链接构建
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 内容语义兜底
---------------------------------------------------------------------
local function infer_from_content(content)
	if not content or content == "" then
		return nil
	end
	if content:match("修复") or content:match("bug") or content:match("错误") then
		return "patch"
	end
	if content:match("重构") or content:match("优化") or content:match("整理") then
		return "refactor"
	end
	if content:match("注释") or content:match("文档") or content:match("说明") then
		return "comment"
	end
	if content:match("测试") or content:match("用例") or content:match("覆盖") then
		return "test"
	end
	return nil
end

---------------------------------------------------------------------
-- 最终行为推断（基于 strategy_registry）
---------------------------------------------------------------------
local function infer_action_type(ctx, task, strategy_name)
	local strategy = registry.get(strategy_name)
	local content = task.core.content or ""

	-- 1. signature 优先
	if ctx.block and ctx.block.signature then
		return "signature"
	end

	-- 2. 有行范围 → patch/refactor/comment/test
	if ctx.start_line and ctx.end_line then
		if strategy.action_type ~= "completion" then
			return strategy.action_type
		end
		return "patch"
	end

	-- 3. 注释块 → comment
	if ctx.block and ctx.block.type == "comment" then
		return "comment"
	end

	-- 4. 策略行为类型
	if strategy.action_type then
		return strategy.action_type
	end

	-- 5. 内容语义兜底
	local from_content = infer_from_content(content)
	if from_content then
		return from_content
	end

	-- 6. 最终兜底
	return "completion"
end

---------------------------------------------------------------------
-- request_id 生成
---------------------------------------------------------------------
local function generate_request_id(task_id, action_type)
	return string.format("%s:%s:%s", task_id, action_type, vim.loop.hrtime())
end

---------------------------------------------------------------------
-- 执行 AI 流式任务
---------------------------------------------------------------------
function M.run_stream(id, opts)
	opts = opts or {}

	local task = core.get_task(id)
	if not task then
		return { ok = false, error = "找不到任务：" .. id }
	end

	if not task.locations.code then
		return { ok = false, error = "任务没有代码标记：" .. id }
	end

	local todo = to_todo_link(task)
	local code_link = to_code_link(task)
	if not todo or not code_link then
		return { ok = false, error = "任务缺少 TODO 或 CODE 标记：" .. id }
	end

	-- 收集上下文
	local ctx = context.collect_enhanced(code_link, id, {
		max_children = opts.max_children or 5,
		max_semantic = opts.max_semantic or 3,
		include_code = true,
	})
	if not ctx then
		return { ok = false, error = "无法收集上下文" }
	end

	-- Prompt + strategy_name
	local prompt_text, strategy_name = prompt.build_from_context(ctx, {
		task_id = id,
		task_content = todo.content or "",
		file_path = code_link.path,
	})

	-- 初始化流式引擎
	local ok, stream_id, err = stream.start({
		path = code_link.path,
		ctx = { start_line = ctx.start_line, end_line = ctx.end_line },
		code_link = code_link,
		todo = todo,
	})
	if not ok then
		return { ok = false, error = "流式引擎初始化失败：" .. tostring(err) }
	end

	-- 完成回调
	local function on_done()
		vim.schedule(function()
			local ok_finish, err_finish = stream.finish(stream_id)
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

			vim.notify("AI 已完成 ✓", vim.log.levels.INFO)
			events.on_state_changed({ source = "ai_task_complete", ids = { id }, data = { success = true } })
			if opts.on_done then
				opts.on_done(id, true)
			end
		end)
	end

	-- chunk 回调
	local function on_chunk(chunk)
		if chunk and chunk ~= "" then
			stream.on_chunk(stream_id, chunk)
		end
	end

	-- ⭐ 使用 registry 推断行为类型
	local action_type = infer_action_type(ctx, task, strategy_name)
	local request_id = generate_request_id(id, action_type)

	-- 发送请求
	local ok_stream, err_stream = gateway.send({
		task_id = id,
		action_type = action_type,
		request_id = request_id,
		messages = {
			{ role = "system", content = "You are a code assistant. Output code only." },
			{ role = "user", content = prompt_text },
		},
		options = { stream = true },
		on_chunk = on_chunk,
		on_complete = on_done,
		on_error = function(err)
			local msg = err and (err.message or tostring(err)) or "未知错误"
			vim.notify("AI 请求失败：" .. msg, vim.log.levels.ERROR)
			stream.abort(stream_id)
			events.on_state_changed({
				source = "ai_task_complete",
				ids = { id },
				data = { success = false, error = msg },
			})
			if opts.on_done then
				opts.on_done(id, false)
			end
		end,
	})

	if not ok_stream then
		stream.abort(stream_id)
		local msg = error_handler.format(err_stream or "未知错误")
		return { ok = false, error = "AI 启动失败：" .. msg }
	end

	return { ok = true, async = true, task_id = stream_id }
end

return M
