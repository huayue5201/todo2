-- lua/todo2/ai/state.lua
-- 统一持久化管理（模型选择、后端选择、未来更多状态）

local M = {}

local state_path = vim.fn.stdpath("data") .. "/todo2_ai_state.json"

---------------------------------------------------------------------
-- 保存状态（公共接口）
---------------------------------------------------------------------
function M.save(cfg)
	local json = vim.fn.json_encode({
		backend = cfg.backend,
		model = cfg.model,
	})
	vim.fn.writefile({ json }, state_path)
end

---------------------------------------------------------------------
-- 读取状态（公共接口）
---------------------------------------------------------------------
function M.load()
	if vim.fn.filereadable(state_path) == 0 then
		return nil
	end

	local content = table.concat(vim.fn.readfile(state_path), "\n")
	local ok, data = pcall(vim.fn.json_decode, content)
	if not ok or not data.backend or not data.model then
		return nil
	end

	return data
end

return M
