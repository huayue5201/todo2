-- lua/todo2/render/scheduler.lua（修复版）
-- 渲染调度器：协调各渲染模块，避免重复工作
-- ⚠️ 注意：此模块只做调度，不直接依赖具体渲染模块

local M = {}

-- 不再直接 require 渲染模块，改为动态加载
-- 这样避免循环依赖

-- 状态跟踪
local rendering = {} -- 正在渲染的buffer
local pending = {} -- 等待渲染的buffer
local DEBOUNCE = 10

-- 共享解析缓存（所有模块共用）
local parse_cache = {}
local CACHE_TTL = 5000 -- 5秒缓存

-- 模块引用（延迟加载）
local parser = nil

--- 统一获取解析树
--- @param path string 文件路径
--- @param force_refresh boolean 是否强制刷新
--- @return table tasks, table roots, table id_to_task
function M.get_parse_tree(path, force_refresh)
	if not path or path == "" then
		return {}, {}, {}
	end

	-- 延迟加载 parser
	if not parser then
		parser = require("todo2.core.parser")
	end

	local now = vim.loop.now()
	local cached = parse_cache[path]

	-- 缓存有效且不强制刷新时直接返回
	if not force_refresh and cached and (now - cached.time) < CACHE_TTL then
		return cached.tasks, cached.roots, cached.id_to_task
	end

	-- 真正解析
	local tasks, roots, id_to_task = parser.parse_file(path, force_refresh)

	-- 缓存结果
	parse_cache[path] = {
		tasks = tasks or {},
		roots = roots or {},
		id_to_task = id_to_task or {},
		time = now,
	}

	return tasks, roots, id_to_task
end

--- 使缓存失效
--- @param path string|nil 文件路径，nil时清空所有缓存
function M.invalidate_cache(path)
	if path then
		parse_cache[path] = nil
	else
		parse_cache = {}
	end
end

--- 统一刷新入口
--- @param bufnr number 缓冲区号
--- @param opts table|nil 选项 { force_refresh = boolean }
--- @return number 渲染的任务数
function M.refresh(bufnr, opts)
	opts = opts or {}

	-- 参数验证
	if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end

	-- 防重入：避免循环渲染
	if rendering[bufnr] then
		-- 不重复渲染，但记录待处理
		pending[bufnr] = opts
		return 0
	end

	rendering[bufnr] = true

	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		rendering[bufnr] = nil
		return 0
	end

	local is_todo = path:match("%.todo%.md$")
	local result

	-- 预加载缓存：如果是TODO文件且需要刷新，先获取解析树
	if is_todo and (opts.force_refresh or not parse_cache[path]) then
		M.get_parse_tree(path, opts.force_refresh)
	end

	-- ⭐ 动态加载渲染模块，避免循环依赖
	if is_todo then
		-- TODO文件：先渲染再应用隐藏
		local ui_render = require("todo2.ui.render")
		local conceal = require("todo2.ui.conceal")

		result = ui_render.render(bufnr, opts)
		conceal.apply_smart_conceal(bufnr)
	else
		-- 代码文件
		local code_render = require("todo2.task.renderer")
		result = code_render.render_code_status(bufnr)
	end

	-- 清理渲染状态
	rendering[bufnr] = nil

	-- 处理等待中的渲染请求
	if pending[bufnr] then
		local next_opts = pending[bufnr]
		pending[bufnr] = nil
		vim.defer_fn(function()
			M.refresh(bufnr, next_opts)
		end, DEBOUNCE)
	end

	return result or 0
end

--- 批量刷新所有已加载的缓冲区
--- @param opts table|nil
function M.refresh_all(opts)
	local bufs = vim.api.nvim_list_bufs()
	for _, bufnr in ipairs(bufs) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			M.refresh(bufnr, opts)
		end
	end
end

--- 清空所有状态（主要用于测试）
function M.clear()
	rendering = {}
	pending = {}
	parse_cache = {}
end

return M
