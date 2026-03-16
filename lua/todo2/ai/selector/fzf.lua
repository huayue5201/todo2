-- lua/todo2/ai/selector/fzf.lua
-- 两级选择：先选适配器 backend，再选模型 model

local M = {}

---------------------------------------------------------------------
-- 工具：获取当前文件所在目录
---------------------------------------------------------------------
local function get_base_dir()
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	return src:match("(.*/)")
end

---------------------------------------------------------------------
-- 自动扫描 model_config 目录
---------------------------------------------------------------------
local function scan_model_configs()
	local configs = {}
	local base_dir = get_base_dir()
	local config_dir = base_dir .. "../adapters/model_config"

	local files = vim.fn.glob(config_dir .. "/*.lua", false, true)

	for _, file in ipairs(files) do
		local name = file:match("model_config/(.+)%.lua$")
		if name then
			local ok, cfg = pcall(require, "todo2.ai.adapters.model_config." .. name)
			if ok and type(cfg) == "table" and cfg.backend and cfg.display_name then
				table.insert(configs, cfg)
			end
		end
	end

	return configs
end

---------------------------------------------------------------------
-- 一级选择：选择后端
---------------------------------------------------------------------
local function select_backend(configs, callback)
	local backends = {}

	for _, cfg in ipairs(configs) do
		backends[cfg.backend] = true
	end

	local choices = vim.tbl_keys(backends)

	require("fzf-lua").fzf_exec(choices, {
		prompt = "选择后端 > ",
		winopts = {
			height = 0.6,
			width = 0.5,
			row = 0.2,
			col = 0.25,
			border = "rounded",
		},
		actions = {
			["default"] = function(selected)
				callback(selected[1])
			end,
		},
	})
end

---------------------------------------------------------------------
-- 二级选择：选择模型
---------------------------------------------------------------------
local function select_model_for_backend(configs, backend, callback)
	local models = {}

	for _, cfg in ipairs(configs) do
		if cfg.backend == backend then
			table.insert(models, cfg.display_name)
		end
	end

	require("fzf-lua").fzf_exec(models, {
		prompt = "选择模型 (" .. backend .. ") > ",
		winopts = {
			height = 0.7,
			width = 0.55,
			row = 0.15,
			col = 0.22,
			border = "rounded",
		},
		actions = {
			["default"] = function(selected)
				local name = selected[1]
				for _, cfg in ipairs(configs) do
					if cfg.display_name == name then
						require("todo2.ai.state").save(cfg)
						callback(cfg)
						return
					end
				end
			end,
		},
	})
end

---------------------------------------------------------------------
-- 对外接口：两级选择
---------------------------------------------------------------------
function M.select_model(callback)
	local configs = scan_model_configs()

	if #configs == 0 then
		vim.notify("未找到任何模型配置文件", vim.log.levels.ERROR)
		return
	end

	select_backend(configs, function(backend)
		select_model_for_backend(configs, backend, callback)
	end)
end

return M
