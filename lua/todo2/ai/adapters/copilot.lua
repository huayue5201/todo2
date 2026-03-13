-- lua/todo2/ai/adapters/copilot.lua
-- 默认模型：Copilot

local M = {}

--- 调用 Copilot 生成代码
function M.generate(prompt)
	-- 假设你有一个 copilot-cli 工具
	local result = vim.fn.system({ "copilot-cli", "gen", prompt })

	if vim.v.shell_error ~= 0 then
		return nil
	end

	return result
end

return M
