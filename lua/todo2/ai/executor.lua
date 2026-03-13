-- lua/todo2/ai/executor.lua
-- AI 执行器：根据任务内容生成代码并写回 CODE 标记

local M = {}

local link = require("todo2.store.link")
local prompt = require("todo2.ai.prompt")
local ai = require("todo2.ai") -- 模型适配层（ai.generate）
local apply = require("todo2.ai.apply")

--- 执行一个任务（根据 ID）
--- @param id string 任务 ID
--- @return table { ok = boolean, code = string|nil, error = string|nil }
function M.execute(id)
	-- 1. 获取任务
	local todo = link.get_todo(id, { force_relocate = true })
	if not todo then
		return { ok = false, error = "任务不存在" }
	end

	-- 2. 判断是否 AI 可执行
	if not todo.ai_executable then
		return { ok = false, error = "任务未标记为 AI 可执行" }
	end

	-- 3. 构建提示词
	local p = prompt.build(todo)

	-- 4. 调用 AI 生成代码
	local code = ai.generate(p)
	if not code or code == "" then
		return { ok = false, error = "AI 未生成代码" }
	end

	-- 5. 写回 CODE 标记
	-- TODO:ref:cd2b5e
	local ok, err = apply.write_code(id, code)
	if not ok then
		return { ok = false, error = err }
	end

	return { ok = true, code = code }
end

return M
