-- lua/todo2/init.lua
--- @brief 主入口模块

local M = {}

-- setup 是否已执行（供惰性入口 plugin/todo2.lua 判断）
M._setup_done = false

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local config = require("todo2.config")
local dependencies = require("todo2.dependencies")
local keymaps = require("todo2.keymaps")
local autocmds = require("todo2.autocmds")
local highlights = require("todo2.render.highlights")

---------------------------------------------------------------------
-- 插件初始化
---------------------------------------------------------------------
function M.setup(user_config)
	-- 幂等：重复调用只生效一次，避免重复注册定时任务 / 自动命令
	if M._setup_done then
		return
	end

	-- 依赖 vim.async（Neovim 0.13+）
	if not vim.async then
		vim.notify("todo2 requires Neovim 0.13+ (depends on vim.async)", vim.log.levels.ERROR)
		return
	end

	-- 初始化配置模块
	config.setup(user_config)

	-----------------------------------------------------------------
	-- 1. 检查并初始化依赖
	-----------------------------------------------------------------
	local deps_ok, deps_error = M.check_and_init_dependencies()
	if not deps_ok then
		vim.notify("Dependency init failed: " .. deps_error, vim.log.levels.ERROR)
		return
	end

	-----------------------------------------------------------------
	-- 2. 初始化高亮系统
	-----------------------------------------------------------------
	M.setup_highlights()

	-----------------------------------------------------------------
	-- 3. 设置 TODO 文件核心映射
	-----------------------------------------------------------------
	M.setup_keymaps()

	-----------------------------------------------------------------
	-- 4. 设置自动命令
	-----------------------------------------------------------------
	M.setup_autocmds()

	-----------------------------------------------------------------
	-- 5. 自动归档（可选，config.archive.auto_after_days > 0 时生效）
	-----------------------------------------------------------------
	vim.schedule(function()
		local ok, n = pcall(function()
			return require("todo2.store.archive").auto_archive()
		end)
		if ok and type(n) == "number" and n > 0 then
			vim.notify(string.format("📦 Auto-archived %d task group(s)", n), vim.log.levels.INFO)
		end
	end)

	-----------------------------------------------------------------
	-- 5.5 存储命名空间硬切：清掉旧 todo.* 键
	--     不迁移数据；任务会由下面的 reconcile 从 TODO 文件重建。
	-----------------------------------------------------------------
	vim.schedule(function()
		pcall(function()
			require("todo2.store.namespace").purge_legacy()
		end)
		-- 只标记数据形状版本（老数据由 store.schema 在读取边界逐条归一，这里不转换）
		pcall(function()
			require("todo2.store.schema").stamp()
		end)
	end)

	-----------------------------------------------------------------
	-- 6. 启动对账 + 孤儿回收
	--    文件是真源：先对全项目 TODO 文件做一次全量对账（自愈机会式同步漏事件
	--    造成的漂移），再清理插件外被删除的 TODO 文件留下的孤儿任务。
	-----------------------------------------------------------------
	vim.schedule(function()
		local sync_cfg = config.get("sync") or {}
		if sync_cfg.reconcile_on_start then
			local ok, res = pcall(function()
				return require("todo2.core.reconcile").run()
			end)
			if ok and type(res) == "table" then
				local n = res.added + res.removed + res.changed
				if n > 0 then
					vim.notify(
						string.format(
							"🔄 Reconcile: %d file(s), %d added, %d removed, %d changed",
							res.files,
							res.added,
							res.removed,
							res.changed
						),
						vim.log.levels.INFO
					)
				end
			end
		end

		-- 孤儿回收（config.orphan.enabled，清理插件外被删除的 TODO 文件留下的任务）
		local ok_o, res_o = pcall(function()
			return require("todo2.store.orphan").sweep()
		end)
		if ok_o and type(res_o) == "table" then
			local n = res_o.quarantined + res_o.restored + res_o.purged
			if n > 0 then
				vim.notify(
					string.format(
						"🧹 Orphans: %d quarantined, %d restored, %d purged",
						res_o.quarantined,
						res_o.restored,
						res_o.purged
					),
					vim.log.levels.INFO
				)
			end
		end
	end)

	-- 发布本实例的 RPC 地址，供 MCP 桥（mcp/todo2-mcp.lua）连接。
	-- 默认关闭：不用 AI 接入的环境不产生任何文件和 socket。
	if config.get("ai.enabled") == true then
		pcall(function()
			require("todo2.mcp").publish()
		end)
	end

	M._setup_done = true
end

--- 是否已完成初始化（惰性入口据此避免重复 setup）
function M.is_setup()
	return M._setup_done
end

---------------------------------------------------------------------
-- 高亮系统初始化
---------------------------------------------------------------------
function M.setup_highlights()
	if highlights and highlights.setup then
		local ok, err = pcall(function()
			highlights.setup()
		end)

		if not ok then
			vim.notify("Highlight system init failed: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

---------------------------------------------------------------------
-- 依赖检查与初始化
---------------------------------------------------------------------
function M.check_and_init_dependencies()
	return dependencies.check_and_init()
end

---------------------------------------------------------------------
-- TODO 文件核心映射
---------------------------------------------------------------------
function M.setup_keymaps()
	if keymaps and keymaps.setup then
		keymaps.setup()
	end
end

---------------------------------------------------------------------
-- 自动命令设置
---------------------------------------------------------------------
function M.setup_autocmds()
	if autocmds and autocmds.setup then
		autocmds.setup()
	end
end

return M
