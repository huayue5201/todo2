-- lua/todo2/hover.lua
-- hover.nvim provider：光标停在任务上（代码标记行 / TODO 任务行）时，把该任务的
-- 上下文作为 hover 来源显示 —— 复用你已有的 `K`（hover.open），不额外占键位。
--
-- 启用：把 "todo2.hover" 加进 hover.nvim 的 providers 列表，例如
--   require("hover").setup({
--     providers = {
--       "hover.providers.lsp",
--       "hover.providers.diagnostic",
--       "todo2.hover",            -- ← 加这一行
--     },
--   })
-- 想改优先级/名字：{ module = "todo2.hover", priority = 900, name = "Task" }

local ctx = require("todo2.ai")
local cursor = require("todo2.task.cursor")

--- 光标处的任务 id（兼容 TODO 文件与代码标记行）。
---@param bufnr integer
---@param lnum integer
---@return string|nil
local function id_at(bufnr, lnum)
	return cursor.get_id(bufnr, lnum)
end

---@type table
return {
	name = "todo2",
	-- 高于内置（lsp=1000, diagnostic=1001, dap=1002, fold_preview=1003），
	-- 这样在任务上按 K 会先显示任务，再用 [s/]s 切到 LSP。
	priority = 1005,

	---@param bufnr integer
	---@param opts? { pos?: integer[] }
	---@return boolean
	enabled = function(bufnr, opts)
		local pos = (opts and opts.pos) or vim.api.nvim_win_get_cursor(0)
		return id_at(bufnr, pos[1]) ~= nil
	end,

	---@param params { bufnr: integer, pos: integer[] }
	---@param done fun(result?: false|table)
	execute = function(params, done)
		local id = id_at(params.bufnr, params.pos[1])
		if not id then
			done(false)
			return
		end

		local bundle = ctx.build(id, { include_code = false })
		if not bundle then
			done(false)
			return
		end

		done({
			lines = vim.fn.split(ctx.to_markdown(bundle), "\n", true),
			filetype = "markdown",
		})
	end,
}
