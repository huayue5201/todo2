-- lua/todo2/ai/gateway.lua
--
-- Industrial Grade AI Gateway (Upgraded)
--
-- 功能：
--   1. 管理 Rust interaction-layer 进程
--   2. NDJSON(stdin/stdout) 通信
--   3. 支持流式 chunk、metadata、patch
--   4. 多任务并发
--   5. 稳定 timeout、错误与进程崩溃处理
--   6. 支持 signature / range / fallback patch
--
-- 特性：
--   • stdout 分片安全
--   • 流式 token 自动刷新 timeout
--   • 进程退出或崩溃安全
--   • 多任务并行
--   • UI 线程安全
--   • patch metadata 支持 start_line, end_line, signature_text

local M = {}

---------------------------------------------------------------------
-- 状态
---------------------------------------------------------------------

local job_id = nil
local stdout_buffer = ""
local callbacks = {}

---------------------------------------------------------------------
-- 项目路径
---------------------------------------------------------------------

local function get_project_root()
	local src = debug.getinfo(1, "S").source:gsub("^@", "")
	return src:match("(.*/todo2)/lua/todo2/")
end

local project_root = get_project_root()
local service_path = project_root and (project_root .. "/interaction-layer/target/release/interaction-layer") or nil

---------------------------------------------------------------------
-- 安全回调
---------------------------------------------------------------------

local function safe_call(fn, ...)
	if not fn then
		return
	end

	local args = { ... }
	vim.schedule(function()
		pcall(fn, unpack(args))
	end)
end

---------------------------------------------------------------------
-- 清理请求
---------------------------------------------------------------------

local function clear_request(request_id)
	local cb = callbacks[request_id]
	if not cb then
		return
	end

	if cb.timer then
		cb.timer:stop()
		cb.timer:close()
	end

	callbacks[request_id] = nil
end

---------------------------------------------------------------------
-- 重置 timeout
---------------------------------------------------------------------

local function refresh_timeout(cb)
	if not cb or not cb.timer then
		return
	end

	cb.timer:stop()
	cb.timer:start(cb.timeout * 1000, 0, function()
		local current = callbacks[cb.request_id]

		if current then
			-- 超时：先调用 on_error
			safe_call(current.on_error, {
				message = "AI 请求超时",
				request_id = current.request_id,
			})

			-- 调用 on_complete（空内容）
			safe_call(current.on_complete, {
				status = "complete",
				request_id = current.request_id,
				content = "",
				total_chars = 0,
				duration_ms = cb.timeout * 1000,
			})

			clear_request(cb.request_id)
		end
	end)
end

---------------------------------------------------------------------
-- Patch 工具（工业级）
---------------------------------------------------------------------

local function apply_patch(code, meta)
	-- 如果没有代码内容，不执行 patch
	if not code or code == "" then
		return
	end

	-- signature 优先（修正字段名）
	if meta.signature_text and meta.signature_text ~= "" then
		-- 这里调用你已有的 signature patch 函数
		if vim.fn.exists(":TodoAIPatchSignature") == 2 then
			vim.cmd(string.format("TodoAIPatchSignature %s", meta.signature_text))
			return
		end
	end

	-- start_line/end_line
	if meta.start_line and meta.end_line then
		-- 行范围 patch
		if vim.fn.exists(":TodoAIPatchRange") == 2 then
			vim.cmd(string.format("TodoAIPatchRange %d %d", meta.start_line, meta.end_line))
			return
		end
	end

	-- fallback：替换 selection 或当前 buffer
	if vim.fn.exists(":TodoAIPatchFallback") == 2 then
		vim.cmd("TodoAIPatchFallback")
	end
end

---------------------------------------------------------------------
-- stdout 处理
---------------------------------------------------------------------

local function process_stdout(data)
	for _, chunk in ipairs(data) do
		if chunk and chunk ~= "" then
			stdout_buffer = stdout_buffer .. chunk
		end
	end

	while true do
		local newline = stdout_buffer:find("\n", 1, true)
		if not newline then
			break
		end

		local line = stdout_buffer:sub(1, newline - 1)
		stdout_buffer = stdout_buffer:sub(newline + 1)

		if line ~= "" then
			local ok, resp = pcall(vim.json.decode, line)
			if ok and resp and resp.request_id then
				local cb = callbacks[resp.request_id]
				if cb then
					if resp.status == "chunk" then
						refresh_timeout(cb)
						safe_call(cb.on_chunk, resp.content)
					elseif resp.status == "complete" then
						-- 构建 patch metadata
						local meta = {
							start_line = resp.start_line,
							end_line = resp.end_line,
							signature_text = resp.signature_text,
						}

						-- 应用 patch（如果用户没有提供自定义处理）
						if not cb.skip_auto_patch then
							apply_patch(resp.content, meta)
						end

						-- 调用用户回调，传递完整响应
						safe_call(cb.on_complete, {
							status = "complete",
							request_id = resp.request_id,
							content = resp.content,
							total_chars = resp.total_chars,
							duration_ms = resp.duration_ms,
							start_line = resp.start_line,
							end_line = resp.end_line,
							signature_text = resp.signature_text,
						})
						clear_request(resp.request_id)
					elseif resp.status == "error" then
						safe_call(cb.on_error, {
							message = resp.message,
							code = resp.code,
							request_id = resp.request_id,
						})
						clear_request(resp.request_id)
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------
-- 启动 Rust 服务
---------------------------------------------------------------------

local function start_service()
	if job_id then
		return true
	end

	if not service_path then
		vim.notify("无法确定 interaction-layer 服务路径", vim.log.levels.ERROR)
		return false
	end

	if vim.fn.filereadable(service_path) == 0 then
		vim.notify(
			string.format(
				"interaction-layer 未编译\n请执行:\ncd %s/interaction-layer && cargo build --release",
				project_root
			),
			vim.log.levels.ERROR
		)
		return false
	end

	job_id = vim.fn.jobstart({ service_path }, {
		stdin = "pipe",
		stdout_buffered = false,
		stderr_buffered = false,

		on_stdout = function(_, data)
			process_stdout(data)
		end,

		on_stderr = function(_, data)
			for _, line in ipairs(data) do
				if line and line ~= "" then
					vim.schedule(function()
						vim.notify("[interaction-layer] " .. line, vim.log.levels.WARN)
					end)
				end
			end
		end,

		on_exit = function()
			job_id = nil
			stdout_buffer = ""
			-- 所有进行中任务失败
			for request_id, cb in pairs(callbacks) do
				safe_call(cb.on_error, {
					message = "AI 服务进程已退出",
					request_id = request_id,
				})
				clear_request(request_id)
			end
			-- 自动重启
			vim.defer_fn(function()
				if not job_id then
					vim.notify("[interaction-layer] 服务已退出，正在重启...", vim.log.levels.WARN)
					start_service()
				end
			end, 1000)
		end,
	})

	if job_id <= 0 then
		job_id = nil
		vim.notify("无法启动 interaction-layer 服务", vim.log.levels.ERROR)
		return false
	end

	return true
end

---------------------------------------------------------------------
-- 发送请求
---------------------------------------------------------------------

function M.send(opts)
	if not start_service() then
		return false, "AI 服务未启动"
	end

	local ai = require("todo2.ai")
	local config = ai.current_config
	if not config then
		return false, "未选择模型配置，请执行 :TodoAISelectModel"
	end

	local request_id = tostring(vim.loop.hrtime()) .. "_" .. math.random(1000, 9999)
	local timeout = (opts.options and opts.options.timeout) or config.timeout or 60
	local timer = vim.loop.new_timer()

	local cb = {
		request_id = request_id,
		timeout = timeout,
		timer = timer,
		skip_auto_patch = opts.skip_auto_patch or false, -- 可选：跳过自动 patch
		on_chunk = opts.on_chunk or function() end,
		on_complete = opts.on_complete or function() end,
		on_error = opts.on_error or function(err)
			vim.notify(err.message or "AI 请求失败", vim.log.levels.ERROR)
		end,
	}

	callbacks[request_id] = cb
	refresh_timeout(cb)

	local url = config.url or string.format("%s:%d/api/chat", config.host or "http://127.0.0.1", config.port or 11434)

	local request = {
		request_id = request_id,
		model = {
			name = config.display_name or config.model,
			api_type = config.backend,
			api_key = config.api_key or "",
			url = url,
			model_name = config.model,
		},
		messages = opts.messages or {},
		options = {
			stream = opts.options and opts.options.stream ~= false,
			temperature = opts.options and opts.options.temperature or config.temperature,
			max_tokens = opts.options and opts.options.max_tokens or config.max_tokens,
			timeout_seconds = timeout,
		},
	}

	local json = vim.json.encode(request) .. "\n"
	local result = vim.fn.chansend(job_id, json)

	if result == 0 then
		clear_request(request_id)
		return false, "发送请求失败"
	end

	return true, nil
end

---------------------------------------------------------------------
-- 停止服务
---------------------------------------------------------------------

function M.stop_all()
	if job_id then
		vim.fn.jobstop(job_id)
		job_id = nil
	end

	stdout_buffer = ""
	for request_id, _ in pairs(callbacks) do
		clear_request(request_id)
	end
	callbacks = {}
end

---------------------------------------------------------------------
-- 设置路径
---------------------------------------------------------------------

function M.setup(opts)
	if opts and opts.service_path then
		service_path = opts.service_path
	end
end

return M
