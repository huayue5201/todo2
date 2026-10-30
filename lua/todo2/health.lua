-- lua/todo2/health.lua
-- `:checkhealth todo2` —— 一次性把「装没装对」查清楚：
-- 版本、依赖、存储目录、TODO 文件规则、Treesitter parser、LSP、AI/MCP 状态。
-- 只读，不改任何状态。

local M = {}

local TREESITTER_LANGS = { "lua", "go", "python", "rust", "javascript", "typescript", "c", "cpp" }

---当前安装路径（用于在报错时告诉用户加载的是哪一份代码）
---@return string
local function plugin_root()
	local info = debug.getinfo(1, "S")
	local source = info and info.source or ""
	local path = source:gsub("^@", "")
	return (path:gsub("/lua/todo2/health%.lua$", ""))
end

---目录是否可写（不存在则尝试创建）
---@param dir string
---@return boolean, string|nil
local function dir_writable(dir)
	if vim.fn.isdirectory(dir) == 0 then
		local ok = pcall(vim.fn.mkdir, dir, "p")
		if not ok then
			return false, "cannot create directory"
		end
	end
	local probe = dir .. "/.todo2-write-test"
	local fd, err = io.open(probe, "w")
	if not fd then
		return false, err
	end
	fd:close()
	os.remove(probe)
	return true, nil
end

function M.check()
	local health = vim.health
	local ok_health = health and health.start ~= nil
	if not ok_health then
		vim.notify("todo2: this Neovim has no vim.health API", vim.log.levels.ERROR)
		return
	end

	local ok_config, config = pcall(require, "todo2.config")

	health.start("todo2")

	---------------------------------------------------------------------
	-- 1) Neovim 版本 / vim.async
	---------------------------------------------------------------------
	if vim.fn.has("nvim-0.13") == 1 and vim.async ~= nil then
		health.ok(("Neovim %s with vim.async"):format(vim.version().major .. "." .. vim.version().minor))
	else
		health.error("todo2 requires Neovim 0.13+ (vim.async is missing)", {
			"Upgrade Neovim: https://github.com/neovim/neovim/releases",
			"Current: " .. tostring(vim.version()),
		})
	end

	---------------------------------------------------------------------
	-- 2) 必需依赖 nvim-store3
	---------------------------------------------------------------------
	local ok_store, store = pcall(require, "nvim-store3")
	if ok_store and type(store) == "table" then
		local info = debug.getinfo(store.init or store.global or function() end, "S")
		local where = info and info.source and info.source:gsub("^@", "") or "?"
		health.ok("nvim-store3 is available (" .. where:gsub("/lua/nvim%-store3/.*$", "") .. ")")
	else
		health.error("nvim-store3 is missing — todo2 cannot persist anything without it", {
			"Add it as a dependency: dependencies = { \"huayue5201/nvim-store3\" }",
			"https://github.com/huayue5201/nvim-store3",
		})
	end

	---------------------------------------------------------------------
	-- 3) 代码加载位置（避免「改了没生效」的困惑）
	---------------------------------------------------------------------
	health.info("loaded from: " .. plugin_root())

	---------------------------------------------------------------------
	-- 4) 存储目录可写
	---------------------------------------------------------------------
	local data_dir = vim.fn.stdpath("data") .. "/nvim-store"
	local writable, err = dir_writable(data_dir)
	if writable then
		health.ok("store directory is writable: " .. data_dir)
	else
		health.error("store directory is not writable: " .. data_dir, { tostring(err) })
	end

	---------------------------------------------------------------------
	-- 5) 配置：TODO 文件识别规则
	---------------------------------------------------------------------
	if not ok_config then
		health.error("todo2.config failed to load")
	else
		local setups = config.get("todo_files") or {}
		local exts = setups.extensions or {}
		local globs = setups.globs or {}
		if #exts == 0 and #(setups.filenames or {}) == 0 then
			health.warn("todo_files.extensions and todo_files.filenames are both empty — no TODO file will be detected")
		else
			health.ok(("TODO files: extensions=%s, globs=%d pattern(s)"):format(table.concat(exts, " "), #globs))
		end

		if config.get("conceal_due") == false then
			health.info("conceal_due = false (the inline @date stays visible)")
		end

		local ai_enabled = config.get("ai.enabled") == true
		local state = ai_enabled and "published at startup" or "off (set ai = { enabled = true } to publish the MCP endpoint)"
		health.info("AI/MCP: " .. state)
	end

	---------------------------------------------------------------------
	-- 6) Treesitter parser（只影响锚点精度，不影响可用性）
	---------------------------------------------------------------------
	local available, missing = {}, {}
	for _, lang in ipairs(TREESITTER_LANGS) do
		local ok_lang = pcall(vim.treesitter.language.add, lang)
		if ok_lang then
			table.insert(available, lang)
		else
			table.insert(missing, lang)
		end
	end
	if #available > 0 then
		health.ok("Treesitter parsers: " .. table.concat(available, " "))
	else
		health.warn("no Treesitter parser found — code anchors fall back to LSP/indent granularity", {
			"Install a parser, e.g. :TSInstall lua go",
		})
	end
	if #missing > 0 then
		health.info("missing parsers (fine if you do not work in these languages): " .. table.concat(missing, " "))
	end

	---------------------------------------------------------------------
	-- 7) LSP（锚点的第二级降级来源）
	---------------------------------------------------------------------
	local clients = vim.lsp.get_clients and vim.lsp.get_clients({}) or {}
	local named = {}
	for _, c in ipairs(clients) do
		table.insert(named, c.name)
	end
	if #named > 0 then
		health.ok("LSP clients: " .. table.concat(named, " "))
	else
		health.info("no LSP client is running in this session (LSP block detection is unavailable until one attaches)")
	end
end

return M
