-- lua/todo2/ai/selector/fzf.lua
-- 两级选择：先选后端类型，再选模型配置

local M = {}

---------------------------------------------------------------------
-- 工具：获取当前文件所在目录
---------------------------------------------------------------------
local function get_base_dir()
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	return src:match("(.*/)")
end

---------------------------------------------------------------------
-- 自动扫描模型配置（从 models 目录）
---------------------------------------------------------------------
local function scan_model_configs()
	local configs = {}
	local config_dir = get_base_dir() .. "../models"

	local files = vim.fn.glob(config_dir .. "/*.lua", false, true)

	for _, file in ipairs(files) do
		local name = file:match("models/(.+)%.lua$")
		if name then
			local ok, cfg = pcall(require, "todo2.ai.models." .. name)
			if ok and type(cfg) == "table" and cfg.backend and cfg.display_name then
				table.insert(configs, cfg)
			end
		end
	end

	return configs
end

---------------------------------------------------------------------
-- 获取居中窗口位置
---------------------------------------------------------------------
local function get_centered_winopts(width, height)
	local screen_width = vim.o.columns
	local screen_height = vim.o.lines

	local col = math.floor((screen_width - width) / 2)
	local row = math.floor((screen_height - height) / 2)

	return {
		height = height,
		width = width,
		row = row,
		col = col,
		border = "rounded",
	}
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

	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("请安装 fzf-lua 插件", vim.log.levels.ERROR)
		return
	end

	fzf.fzf_exec(choices, {
		prompt = "选择后端 > ",
		winopts = get_centered_winopts(50, 12),
		actions = {
			["default"] = function(selected)
				if selected and #selected > 0 then
					callback(selected[1])
				end
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

	if #models == 0 then
		vim.notify("后端 " .. backend .. " 没有可用的模型配置", vim.log.levels.WARN)
		return
	end

	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("请安装 fzf-lua 插件", vim.log.levels.ERROR)
		return
	end

	fzf.fzf_exec(models, {
		prompt = "选择模型 (" .. backend .. ") > ",
		winopts = get_centered_winopts(60, 15),
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then
					return
				end
				local name = selected[1]
				for _, cfg in ipairs(configs) do
					if cfg.display_name == name then
						local state = require("todo2.ai.state")
						if state.save then
							state.save(cfg)
						end
						local ai = require("todo2.ai")
						ai.set_model(cfg)
						vim.notify("已切换到模型：" .. cfg.display_name, vim.log.levels.INFO)
						if callback then
							callback(cfg)
						end
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
		vim.notify(
			"未找到任何模型配置文件\n请在 lua/todo2/ai/models/ 目录下创建配置文件",
			vim.log.levels.ERROR
		)
		return
	end

	select_backend(configs, function(backend)
		select_model_for_backend(configs, backend, callback)
	end)
end

return M
