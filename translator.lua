local CONFIG = {
    TRANSLATE_DELAY = 0.2,
    NOTIFICATION_DURATION = 3,
    BATCH_PROCESS_SIZE = 50,
    API_URL = "https://uapis.cn/api/v1/ai/translate",
    TARGET_LANG = "zh",
    STYLE = "casual",
    CONTEXT = "entertainment",
    PRESERVE_FORMAT = true,
    API_TIMEOUT = 8,
    MAX_CONCURRENT = 2,
    MAX_RETRIES = 3,
    RETRY_DELAY = 1.5,
    API_KEY = getgenv().api_key  -- 如需鉴权请填写
}

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- 本地字典（请保留完整内容，此处仅示例结构）
local Translations = {
    ["General"] = "主页",
    ["Player"] = "玩家",
    -- ... 所有原有条目 ...
    ["Quietness"] = "Qcumber100汉化",
    ["HOLD"] = "长按",
    ["Reach"] = "互动",
    ["Ignore"] = "忽略",
}

-- 状态变量
local apiDisabled = false
local consecutiveFails = 0
local MAX_CONSECUTIVE_FAILS = 5
local ApiCache, Pending, Queue = {}, {}, {}
local Active, Timer = 0, nil
local Translated = setmetatable({}, {__mode = "k"})

-- ========== 安全更新 UI ==========
local function updateUI(original, translated)
    if not original or not translated then return end
    local containers = {CoreGui}
    local ok, pg = pcall(function() return LocalPlayer.PlayerGui end)
    if ok and pg then table.insert(containers, pg) end
    pcall(function() table.insert(containers, StarterGui) end)

    for _, c in ipairs(containers) do
        if c and c.Parent then
            local success, descendants = pcall(function() return c:GetDescendants() end)
            if success then
                for _, obj in ipairs(descendants) do
                    if obj and obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                        local cur = obj.Text
                        if cur == original and cur ~= translated then
                            pcall(function() obj.Text = translated end)
                            Translated[obj] = true
                        end
                    end
                end
            end
        end
    end
end

-- ========== API 调用（带重试） ==========
local function callAPIWithRetry(text, callback, retryCount)
    retryCount = retryCount or 0
    if apiDisabled then
        callback(nil, "API disabled")
        return
    end
    if not HttpService then
        callback(nil, "No HttpService")
        return
    end

    local requestBody = {
        text = text,
        source_lang = "auto",
        target_lang = CONFIG.TARGET_LANG,
        style = CONFIG.STYLE,
        context = CONFIG.CONTEXT,
        preserve_format = CONFIG.PRESERVE_FORMAT
    }
    local body, encErr = pcall(HttpService.JSONEncode, HttpService, requestBody)
    if not encErr then
        callback(nil, "JSON error")
        return
    end

    local headers = {["Content-Type"] = "application/json"}
    if CONFIG.API_KEY then headers["Authorization"] = "Bearer " .. CONFIG.API_KEY end

    local ok, response = pcall(function()
        return HttpService:RequestAsync({
            Url = CONFIG.API_URL,
            Method = "POST",
            Headers = headers,
            Body = body,
            Timeout = CONFIG.API_TIMEOUT
        })
    end)

    if not ok then
        if retryCount < CONFIG.MAX_RETRIES then
            task.wait(CONFIG.RETRY_DELAY)
            callAPIWithRetry(text, callback, retryCount+1)
        else
            consecutiveFails = consecutiveFails + 1
            if consecutiveFails >= MAX_CONSECUTIVE_FAILS then apiDisabled = true end
            callback(nil, "Network error")
        end
        return
    end

    if response.Success and response.StatusCode == 200 then
        local decOk, data = pcall(HttpService.JSONDecode, HttpService, response.Body)
        if decOk and data and data.data and data.data.translated_text then
            consecutiveFails = 0
            callback(data.data.translated_text, nil)
            return
        end
    end
    -- 非200或解析失败
    if retryCount < CONFIG.MAX_RETRIES then
        task.wait(CONFIG.RETRY_DELAY)
        callAPIWithRetry(text, callback, retryCount+1)
    else
        consecutiveFails = consecutiveFails + 1
        if consecutiveFails >= MAX_CONSECUTIVE_FAILS then apiDisabled = true end
        callback(nil, "API error")
    end
end

-- ========== 请求队列 ==========
local function processQueue()
    if Timer then return end
    Timer = task.spawn(function()
        while #Queue > 0 and Active < CONFIG.MAX_CONCURRENT do
            local req = table.remove(Queue, 1)
            if req then
                Active = Active + 1
                callAPIWithRetry(req.text, function(translated, err)
                    Active = Active - 1
                    if translated then
                        ApiCache[req.text] = translated
                        if Pending[req.text] then
                            for _, cb in ipairs(Pending[req.text]) do
                                if cb then pcall(cb, translated) end
                            end
                            Pending[req.text] = nil
                        end
                        task.spawn(updateUI, req.text, translated)
                    else
                        if Pending[req.text] then
                            for _, cb in ipairs(Pending[req.text]) do
                                if cb then pcall(cb, nil) end
                            end
                            Pending[req.text] = nil
                        end
                    end
                end)
            end
            if Active >= CONFIG.MAX_CONCURRENT then break end
            task.wait(0.05)
        end
        Timer = nil
        if #Queue > 0 then processQueue() end
    end)
end

local function requestTranslate(text, callback)
    if not text or text == "" then if callback then callback(nil) end; return end
    if ApiCache[text] then if callback then callback(ApiCache[text]) end; return end
    if Pending[text] then if callback then table.insert(Pending[text], callback) end; return end
    Pending[text] = callback and {callback} or {}
    table.insert(Queue, {text = text})
    processQueue()
end

-- ========== 核心翻译 ==========
local function translateText(text)
    if type(text) ~= "string" or text == "" then return text end
    local s = text:match("^%s*(.-)%s*$")
    for en, cn in pairs(Translations) do
        if s == en or s == en .. ":" then return cn end
    end
    for en, cn in pairs(Translations) do
        if s:lower():find(en:lower(), 1, true) then
            local esc = en:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
            local res = s:gsub(esc, cn, 1)
            if res ~= s then return res end
        end
    end
    if ApiCache[s] then return ApiCache[s] end
    if not apiDisabled and HttpService then
        requestTranslate(s, function() end)
    end
    return text
end

-- ========== GUI 处理（安全版本） ==========
local function translateElement(elem)
    if not elem or Translated[elem] then return false end
    local ok, orig = pcall(function() return elem.Text end)
    if not ok or not orig or orig == "" then
        Translated[elem] = true
        return false
    end
    local trans = translateText(orig)
    if trans and trans ~= orig then
        local setOk = pcall(function() elem.Text = trans end)
        if setOk then
            Translated[elem] = true
            return true
        end
    end
    Translated[elem] = true
    return false
end

local function scanContainer(container)
    if not container then return 0 end
    local list = {}
    local ok, descendants = pcall(function() return container:GetDescendants() end)
    if not ok then return 0 end
    for _, d in ipairs(descendants) do
        if d and (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and not Translated[d] then
            table.insert(list, d)
        end
    end
    local count = 0
    for i = 1, #list, CONFIG.BATCH_PROCESS_SIZE do
        local e = math.min(i + CONFIG.BATCH_PROCESS_SIZE - 1, #list)
        for j = i, e do
            if translateElement(list[j]) then count = count + 1 end
        end
        if e < #list then RunService.Heartbeat:Wait() end
    end
    return count
end

local function setupTextListener(elem)
    if not elem or not (elem:IsA("TextLabel") or elem:IsA("TextButton") or elem:IsA("TextBox")) then return end
    local conn
    conn = elem:GetPropertyChangedSignal("Text"):Connect(function()
        if not elem or not elem.Parent then if conn then conn:Disconnect() end; return end
        pcall(function()
            local cur = elem.Text
            if cur and cur ~= "" then
                local trans = translateText(cur)
                if trans and trans ~= cur then
                    elem.Text = trans
                end
            end
        end)
    end)
end

local function setupContainerListener(container)
    if not container then return end
    container.DescendantAdded:Connect(function(d)
        if d and (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) then
            translateElement(d)
            setupTextListener(d)
        end
    end)
end

-- 元表劫持（仅拦截 Text 设置，并增加类型校验）
local function hijackMetatable()
    local success, mt = pcall(getrawmetatable, game)
    if not success or not mt then return false end
    local oldNewIndex = mt.__newindex
    if not oldNewIndex then return false end
    local setreadonly_ok, _ = pcall(setreadonly, mt, false)
    if not setreadonly_ok then return false end
    mt.__newindex = newcclosure(function(t, k, v)
        if k == "Text" and (t:IsA("TextLabel") or t:IsA("TextButton") or t:IsA("TextBox")) then
            local original = tostring(v)
            local translated = translateText(original)
            if original ~= translated then
                v = translated
            end
        end
        return oldNewIndex(t, k, v)
    end)
    pcall(setreadonly, mt, true)
    return true
end

-- ========== 主引擎 ==========
local function setupEngine()
    local total = 0
    hijackMetatable()
    local containers = {CoreGui}
    local ok, pg = pcall(function() return LocalPlayer.PlayerGui end)
    if ok and pg then table.insert(containers, pg) end
    pcall(function() table.insert(containers, StarterGui) end)

    for _, c in ipairs(containers) do
        if c then
            total = total + scanContainer(c)
        end
    end
    for _, c in ipairs(containers) do
        if c then
            setupContainerListener(c)
            local ok, descendants = pcall(function() return c:GetDescendants() end)
            if ok then
                for _, d in ipairs(descendants) do
                    if d and (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) then
                        setupTextListener(d)
                    end
                end
            end
        end
    end
    return total
end

-- ========== 通知 ==========
local function showNotify(msg)
    pcall(function()
        local gui = Instance.new("ScreenGui")
        gui.Name = "TransNotify"
        gui.Parent = CoreGui
        gui.ResetOnSpawn = false
        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(0, 300, 0, 100)
        frame.Position = UDim2.new(0.5, -150, 0.5, -50)
        frame.BackgroundColor3 = Color3.new(0.1, 0.1, 0.1)
        frame.BorderColor3 = Color3.new(0.3, 0.3, 0.3)
        frame.BorderSizePixel = 2
        frame.Active = true
        frame.Draggable = true
        frame.Parent = gui
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 0.8, 0)
        label.BackgroundTransparency = 1
        label.Text = msg
        label.TextColor3 = Color3.new(1,1,1)
        label.TextScaled = true
        label.Parent = frame
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0.2, 0)
        btn.Position = UDim2.new(0, 0, 0.8, 0)
        btn.BackgroundColor3 = Color3.new(0.2,0.2,0.2)
        btn.Text = "关闭"
        btn.TextColor3 = Color3.new(1,1,1)
        btn.Parent = frame
        btn.MouseButton1Click:Connect(function() gui:Destroy() end)
        task.delay(CONFIG.NOTIFICATION_DURATION, function()
            if gui and gui.Parent then gui:Destroy() end
        end)
    end)
end

-- ========== 启动 ==========
task.wait(CONFIG.TRANSLATE_DELAY)
local startTime = os.clock()
local success, result = pcall(setupEngine)
local elapsed = os.clock() - startTime

if success then
    local cnt = result or 0
    showNotify(string.format("AI翻译引擎 已启动\n口语化 | 娱乐场景\n翻译 %d 项 | %.2f 秒", cnt, elapsed))
    print(string.format("[翻译] 成功启动 | 翻译 %d 项 | %.2f 秒", cnt, elapsed))
else
    showNotify("翻译引擎启动失败: " .. tostring(result))
    warn("[翻译] 启动失败: ", result)
end
