local CONFIG = {
    TRANSLATE_DELAY = 0.2,
    NOTIFICATION_DURATION = 3,
    BATCH_PROCESS_SIZE = 50,
    API_URL = "https://uapis.cn/api/v1/ai/translate",
    TARGET_LANG = "zh",
    STYLE = "casual",
    CONTEXT = "entertainment",
    PRESERVE_FORMAT = true,
    API_TIMEOUT = 5,
    MAX_CONCURRENT = 3
}

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- 本地字典（完整保留，此处省略展示，实际使用时请包含完整字典）
local Translations = {
}

-- 缓存与队列
local ApiCache, Pending, Queue = {}, {}, {}
local Active, Timer = 0, nil
local Translated = setmetatable({}, {__mode = "k"})

-- 可见性判断
local function isElementVisible(element)
    if not element.Visible then return false end
    local size = element.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then return false end
    local parent = element.Parent
    while parent do
        if parent.Visible == false then return false end
        parent = parent.Parent
    end
    return true
end

-- 更新 UI 中所有匹配原文的可见控件
local function updateUI(original, translated)
    if not original or not translated then return end
    local containers = {CoreGui}
    local ok, pg = pcall(function() return LocalPlayer.PlayerGui end)
    if ok then table.insert(containers, pg) end
    pcall(function() table.insert(containers, StarterGui) end)

    for _, c in ipairs(containers) do
        if c then
            for _, obj in ipairs(c:GetDescendants()) do
                if (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) 
                    and obj.Text == original and isElementVisible(obj) then
                    obj.Text = translated
                    Translated[obj] = true
                end
            end
        end
    end
end

-- API 调用（不变）
local function callAPI(text, cb)
    if not HttpService then cb(nil, "No HttpService"); return end
    if not text or text == "" then cb(nil, "Empty"); return end
    local body, encOk = pcall(HttpService.JSONEncode, HttpService, {
        text = text, source_lang = "auto", target_lang = CONFIG.TARGET_LANG,
        style = CONFIG.STYLE, context = CONFIG.CONTEXT, preserve_format = CONFIG.PRESERVE_FORMAT
    })
    if not encOk then cb(nil, "JSON error"); return end
    local ok, res = pcall(HttpService.RequestAsync, HttpService, {
        Url = CONFIG.API_URL, Method = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body = body, Timeout = CONFIG.API_TIMEOUT
    })
    if not ok then cb(nil, "Request failed"); return end
    if res.Success and res.StatusCode == 200 then
        local decOk, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
        if decOk and data and data.data and data.data.translated_text then
            cb(data.data.translated_text, nil)
        else
            cb(nil, "Invalid response")
        end
    else
        cb(nil, "HTTP " .. tostring(res.StatusCode))
    end
end

-- 队列处理（不变）
local function processQueue()
    if Timer then return end
    Timer = task.spawn(function()
        while #Queue > 0 and Active < CONFIG.MAX_CONCURRENT do
            local req = table.remove(Queue, 1)
            if req then
                Active = Active + 1
                callAPI(req.text, function(translated, err)
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
                        warn("[翻译] 失败: ", req.text, " 原因: ", err)
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

local function translate(text)
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
    if HttpService then requestTranslate(s, function() end) end
    return text
end

local function notify(msg)
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

-- 翻译单个元素（仅可见）
local function translateElem(elem)
    if Translated[elem] then return false end
    if not isElementVisible(elem) then
        Translated[elem] = true
        return false
    end
    local ok, orig = pcall(function() return elem.Text end)
    if not ok or not orig or orig == "" then Translated[elem] = true; return false end
    local trans = translate(orig)
    if trans ~= orig then
        local setOk = pcall(function() elem.Text = trans end)
        if setOk then Translated[elem] = true; return true end
    end
    Translated[elem] = true
    return false
end

-- 扫描容器（仅可见）
local function scanContainer(container)
    if not container then return 0 end
    local list = {}
    for _, d in ipairs(container:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) 
            and not Translated[d] and isElementVisible(d) then
            table.insert(list, d)
        end
    end
    local count = 0
    for i = 1, #list, CONFIG.BATCH_PROCESS_SIZE do
        local e = math.min(i + CONFIG.BATCH_PROCESS_SIZE - 1, #list)
        for j = i, e do
            if translateElem(list[j]) then count = count + 1 end
        end
        if e < #list then RunService.Heartbeat:Wait() end
    end
    return count
end

-- 监听文本变化（仅可见时处理）
local function listenTextChange(elem)
    if not elem:IsA("TextLabel") and not elem:IsA("TextButton") and not elem:IsA("TextBox") then return end
    local conn
    conn = elem:GetPropertyChangedSignal("Text"):Connect(function()
        if not elem or not elem.Parent then if conn then conn:Disconnect() end; return end
        if not isElementVisible(elem) then return end
        pcall(function()
            local cur = elem.Text
            if cur and cur ~= "" then
                local trans = translate(cur)
                if trans ~= cur then elem.Text = trans end
            end
        end)
    end)
end

-- 监听可见性变化（变为可见时立即翻译）
local function listenVisibilityChange(elem)
    if not elem:IsA("TextLabel") and not elem:IsA("TextButton") and not elem:IsA("TextBox") then return end
    elem:GetPropertyChangedSignal("Visible"):Connect(function()
        if elem.Visible and not Translated[elem] then
            translateElem(elem)
        end
    end)
end

local function listenContainer(container)
    if not container then return end
    container.DescendantAdded:Connect(function(d)
        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
            translateElem(d)
            listenTextChange(d)
            listenVisibilityChange(d)
        end
    end)
end

local function hijackMetatable()
    return pcall(function()
        local mt = getrawmetatable(game)
        if not mt then return false end
        local old = mt.__newindex
        if not old then return false end
        setreadonly(mt, false)
        mt.__newindex = newcclosure(function(t, k, v)
            if (t:IsA("TextLabel") or t:IsA("TextButton") or t:IsA("TextBox")) and k == "Text" then
                local orig = tostring(v)
                local trans = translate(orig)
                if orig ~= trans then v = trans end
            end
            return old(t, k, v)
        end)
        setreadonly(mt, true)
        return true
    end)
end

local function setup()
    local total = 0
    local hijacked = hijackMetatable()
    local containers = {CoreGui}
    local ok, pg = pcall(function() return LocalPlayer.PlayerGui end)
    if ok then table.insert(containers, pg) end
    pcall(function() table.insert(containers, StarterGui) end)

    for _, c in ipairs(containers) do
        if c then total = total + scanContainer(c) end
    end
    for _, c in ipairs(containers) do
        if c then
            listenContainer(c)
            for _, d in ipairs(c:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                    listenTextChange(d)
                    listenVisibilityChange(d)
                end
            end
        end
    end
    if not hijacked then warn("[翻译] 元表劫持失败，使用扫描方案") end
    return total
end

task.wait(CONFIG.TRANSLATE_DELAY)
local start = os.clock()
local ok, cnt = pcall(setup)
local elapsed = os.clock() - start
if ok then
    notify(string.format("AI翻译引擎 已启动（仅显示文本）\n口语化 | 娱乐场景\n翻译 %d 项 | 耗时 %.2f 秒", cnt or 0, elapsed))
    print(string.format("[翻译] 成功启动 | 仅翻译可见文本 | 共 %d 项 | %.2f 秒", cnt or 0, elapsed))
else
    notify("AI翻译引擎 启动失败: " .. tostring(cnt))
    warn("[翻译] 启动失败: ", cnt)
end
