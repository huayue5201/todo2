-- lua/todo2/ai/executor.lua
-- 执行链（仅流式）

local M = {}

local context = require("todo2.ai.context")
local prompt = require("todo2.ai.prompt")
local apply_stream = require("todo2.ai.apply_stream")
local link = require("todo2.store.link")
local ai = require("todo2.ai")

---------------------------------------------------------------------
-- 流式执行：边生成边写入（不阻塞UI）
---------------------------------------------------------------------
--- @param id string
--- @return table { ok = boolean, error = string|nil, async = boolean }
function M.run_stream(id)
	-- 1. 获取任务和代码链接
	local todo = link.get_todo(id)
	local code_link = link.get_code(id)

	if not todo then
		return { ok = false, error = "找不到 TODO 链接：" .. id }
	end
	if not code_link then
		return { ok = false, error = "找不到 CODE 链接：" .. id }
	end

	-- 2. 收集上下文
	local ctx = context.collect(code_link)
	if not ctx then
		return { ok = false, error = "无法收集上下文" }
	end

	-- 3. 构建 Prompt
	local p = prompt.build(todo, code_link, ctx)

	-- 4. 初始化流式应用器
	local ok_init, err_init = apply_stream.start({
		path = code_link.path,
		ctx = ctx,
		code_link = code_link,
		todo = todo,
	})
	if not ok_init then
		return { ok = false, error = "流式应用初始化失败：" .. tostring(err_init) }
	end

	-- 5. 定义完成回调
	local function on_done()
		vim.schedule(function()
			-- 结束流式应用
			local ok_finish, err_finish, final_ctx = apply_stream.finish()

			if not ok_finish then
				vim.notify("流式补丁应用失败：" .. tostring(err_finish), vim.log.levels.ERROR)
				return
			end

			-- 更新行号
			local old_line = code_link.line
			local new_line = (final_ctx and final_ctx.start_line) or (ctx.start_line or old_line)
			local offset = new_line - old_line
			if offset ~= 0 then
				link.shift_lines(code_link.path, old_line, offset)
			end

			-- 触发事件刷新
			local events = require("todo2.core.events")
			events.on_state_changed({
				source = "ai_execute_stream",
				ids = { id },
			})

			vim.notify("AI已完成流式生成 ✓", vim.log.levels.INFO)
		end)
	end

	-- 6. 定义chunk处理函数
	local function on_chunk(chunk)
		apply_stream.on_chunk(chunk)
	end

	-- 7. 调用AI流式生成（非阻塞）
	local ok_stream, err_stream = ai.generate_stream(p, on_chunk, on_done)

	if not ok_stream then
		apply_stream.abort()
		return { ok = false, error = "AI流式生成启动失败：" .. tostring(err_stream) }
	end

	-- 返回成功，表示流程已启动
	return { ok = true, async = true }
end

return M
