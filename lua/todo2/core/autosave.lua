-- lua/todo2/core/autosave.lua
--- @brief 纯净的异步自动保存模块（使用 libuv 异步文件操作，支持完成回调）

local M = {}

local DEFAULT_DELAY = 200
local timers = {}
local pending_saves = {} -- 跟踪进行中的异步保存操作
local save_callbacks = {} -- 存储每个 buffer 的回调函数
local global_callbacks = {} -- 全局完成回调

local function safe_buf(bufnr)
	if type(bufnr) ~= "number" then
		return false
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return false
	end
	return true
end

-- 获取缓冲区内容
local function get_buf_content(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(lines, "\n")
	return content
end

-- 异步写入文件
local function async_write_file(filename, content, callback)
	-- 打开文件（异步）
	local function open_file()
		-- 修复：fs_open 只接受3个参数 (path, flags, mode, callback)
		-- 但 callback 是第4个参数？实际上 fs_open 的签名是 fs_open(path, flags, mode, callback)
		-- 需要确认正确的参数数量。根据 libuv 文档，fs_open 接受 path, flags, mode, callback 共4个参数
		-- 但警告说最多3个参数，说明这里的 API 可能不同。改为使用 uv.fs_open 的标准用法
		vim.uv.fs_open(filename, "w", 438, function(err, fd)
			if err then
				callback(false, "打开文件失败: " .. err)
				return
			end

			-- 写入文件（异步）
			vim.uv.fs_write(fd, content, -1, function(write_err, written)
				if write_err then
					-- 写入失败，关闭文件
					vim.uv.fs_close(fd, function()
						callback(false, "写入文件失败: " .. write_err)
					end)
					return
				end

				-- 关闭文件（异步）
				vim.uv.fs_close(fd, function(close_err)
					if close_err then
						callback(false, "关闭文件失败: " .. close_err)
					else
						callback(true, nil, written)
					end
				end)
			end)
		end)
	end

	-- 启动异步文件操作
	open_file()
end

-- 注册全局保存完成回调
function M.on_save_complete(callback)
	table.insert(global_callbacks, callback)
end

-- ⭐ 真正的异步保存，不触发任何 autocmd
function M.request_save(bufnr, opts, callback)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	opts = opts or {}
	callback = callback or function() end

	if not safe_buf(bufnr) then
		callback(false, "buffer无效")
		return false, "buffer无效"
	end

	-- 如果已经有保存操作在进行中，取消旧的定时器但保留进行中的异步写入
	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	local timer = vim.uv.new_timer()
	timers[bufnr] = timer

	local delay = opts.delay or DEFAULT_DELAY

	timer:start(delay, 0, function()
		vim.schedule(function()
			if not safe_buf(bufnr) then
				timers[bufnr] = nil
				callback(false, "buffer无效")
				return
			end

			-- 修复：使用 nvim_get_option_value 替代已弃用的 nvim_buf_get_option
			if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
				timers[bufnr] = nil
				callback(false, "buffer未修改")
				return
			end

			-- 直接调用 flush，flush 会处理回调
			M.flush(bufnr, callback)
		end)
	end)

	return true
end

-- 立即保存（使用异步方式，支持回调）
function M.flush(bufnr, callback)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	callback = callback or function() end

	-- 取消定时器
	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
	end

	if not safe_buf(bufnr) then
		callback(false, "buffer无效")
		return false, "buffer无效"
	end

	-- 修复：使用 nvim_get_option_value 替代已弃用的 nvim_buf_get_option
	if not vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
		callback(false, "buffer未修改")
		return false, "buffer未修改"
	end

	-- 检查是否已有进行中的保存
	if pending_saves[bufnr] then
		-- 将回调添加到队列，而不是直接返回失败
		if not save_callbacks[bufnr] then
			save_callbacks[bufnr] = {}
		end
		table.insert(save_callbacks[bufnr], callback)
		return true, "加入保存队列"
	end

	-- 获取文件名
	local filename = vim.api.nvim_buf_get_name(bufnr)
	if filename == "" then
		callback(false, "缓冲区没有关联的文件名")
		return false, "缓冲区没有关联的文件名"
	end

	-- 获取缓冲区内容
	local content = get_buf_content(bufnr)

	-- 标记进行中的保存
	pending_saves[bufnr] = true
	save_callbacks[bufnr] = { callback } -- 存储回调

	-- 执行异步保存
	async_write_file(filename, content, function(success, err_msg, written)
		vim.schedule(function()
			-- 获取该 buffer 的所有回调
			local callbacks = save_callbacks[bufnr] or {}

			-- 清除进行中标记和回调
			pending_saves[bufnr] = nil
			save_callbacks[bufnr] = nil

			if not success then
				vim.notify("保存失败: " .. err_msg, vim.log.levels.ERROR)
				-- 调用所有回调，传入失败信息
				for _, cb in ipairs(callbacks) do
					pcall(cb, false, err_msg)
				end
				-- 触发全局回调（失败）
				for _, cb in ipairs(global_callbacks) do
					pcall(cb, {
						success = false,
						bufnr = bufnr,
						filename = filename,
						error = err_msg,
					})
				end
			else
				if safe_buf(bufnr) then
					-- 重置modified标记，但不触发事件
					-- 修复：使用 nvim_set_option_value 替代 nvim_buf_set_option
					vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
				end

				local result = {
					success = true,
					bufnr = bufnr,
					filename = filename,
					written = written,
				}

				-- 调用 buffer 特定的回调
				for _, cb in ipairs(callbacks) do
					pcall(cb, true, nil, result)
				end

				-- 触发全局回调
				for _, cb in ipairs(global_callbacks) do
					pcall(cb, result)
				end
			end
		end)
	end)

	return true, "保存已启动"
end

-- 刷新所有缓冲区的保存
function M.flush_all()
	for bufnr, timer in pairs(timers) do
		timer:stop()
		timer:close()
		timers[bufnr] = nil

		if safe_buf(bufnr) and vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
			-- 触发异步保存
			M.flush(bufnr)
		end
	end
end

-- 等待所有进行中的保存完成
function M.wait_for_pending_saves(timeout_ms)
	timeout_ms = timeout_ms or 5000 -- 默认等待5秒

	local start_time = vim.uv.hrtime() / 1e6 -- 转换为毫秒

	while next(pending_saves) ~= nil do
		-- 检查超时
		local current_time = vim.uv.hrtime() / 1e6
		if current_time - start_time > timeout_ms then
			return false, "等待保存超时"
		end

		-- 让出事件循环
		vim.wait(10)
	end

	return true, "所有保存完成"
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		-- 触发所有保存
		M.flush_all()

		-- 等待保存完成（最多3秒）
		local ok, msg = M.wait_for_pending_saves(3000)
		if not ok then
			vim.notify("退出时等待保存: " .. msg, vim.log.levels.WARN)
		end
	end,
})

return M
