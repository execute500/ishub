local CONFIG = {
    TRANSLATE_DELAY = 0.2,
    NOTIFICATION_DURATION = 3,
    GUI_SCAN_DELAY = 0.02,
    BATCH_PROCESS_SIZE = 50,
    -- AI API 配置
    API_URL = "https://uapis.cn/api/v1/ai/translate",
    TARGET_LANG = "zh",          -- 目标语言：简体中文
    STYLE = "casual",            -- 随意口语化
    CONTEXT = "entertainment",   -- 娱乐场景
    PRESERVE_FORMAT = true,
    API_TIMEOUT = 5,
    API_RETRY_DELAY = 1,
    MAX_CONCURRENT_REQUESTS = 3
}

-- 必要服务
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

if not HttpService then
    warn("HttpService 不可用，将仅使用本地字典翻译")
end

local LocalPlayer = Players.LocalPlayer

-- ========== 本地字典（快速缓存） ==========
local Translations = {
}

-- ========== AI 翻译缓存和队列管理 ==========
local ApiCache = {}          -- 原文 -> 译文
local PendingRequests = {}   -- 原文 -> {回调函数列表}
local RequestQueue = {}      -- 待发送请求队列
local ActiveRequests = 0
local RequestTimer = nil

-- 辅助函数：延迟
local function wait(seconds)
    local start = os.clock()
    repeat task.wait() until os.clock() - start >= seconds
end

-- 调用 AI 翻译 API (异步)
local function callAITranslateAPI(text, callback)
    local requestBody = {
        text = text,
        source_lang = "auto",      -- 自动检测源语言
        target_lang = CONFIG.TARGET_LANG,
        style = CONFIG.STYLE,
        context = CONFIG.CONTEXT,
        preserve_format = CONFIG.PRESERVE_FORMAT
    }
    local jsonBody = HttpService:JSONEncode(requestBody)
    
    local headers = {
        ["Content-Type"] = "application/json"
    }
    
    local success, result = pcall(function()
        return HttpService:RequestAsync({
            Url = CONFIG.API_URL,
            Method = "POST",
            Headers = headers,
            Body = jsonBody,
            Timeout = CONFIG.API_TIMEOUT
        })
    end)
    
    if not success then
        warn("AI API 请求失败: ", result)
        callback(nil, "Network error")
        return
    end
    
    local response = result
    if response.Success and response.StatusCode == 200 then
        local decoded = HttpService:JSONDecode(response.Body)
        if decoded and decoded.data and decoded.data.translated_text then
            callback(decoded.data.translated_text, nil)
            return
        else
            warn("AI API 返回格式错误: ", response.Body)
            callback(nil, "Invalid response")
        end
    else
        warn("AI API 错误状态码: ", response.StatusCode, " Body: ", response.Body)
        callback(nil, "HTTP " .. tostring(response.StatusCode))
    end
end

-- 处理队列中的下一个请求
local function processRequestQueue()
    if not RequestTimer then
        RequestTimer = task.spawn(function()
            while #RequestQueue > 0 and ActiveRequests < CONFIG.MAX_CONCURRENT_REQUESTS do
                local nextRequest = table.remove(RequestQueue, 1)
                if nextRequest then
                    ActiveRequests = ActiveRequests + 1
                    callAITranslateAPI(nextRequest.text, function(translated, err)
                        ActiveRequests = ActiveRequests - 1
                        if translated then
                            ApiCache[nextRequest.text] = translated
                            if PendingRequests[nextRequest.text] then
                                for _, cb in ipairs(PendingRequests[nextRequest.text]) do
                                    cb(translated)
                                end
                                PendingRequests[nextRequest.text] = nil
                            end
                            -- 更新所有匹配该原文的 UI 控件
                            task.spawn(function()
                                updateAllUIForText(nextRequest.text, translated)
                            end)
                        else
                            warn("AI 翻译失败: ", nextRequest.text, " 原因: ", err)
                            if PendingRequests[nextRequest.text] then
                                for _, cb in ipairs(PendingRequests[nextRequest.text]) do
                                    cb(nil)
                                end
                                PendingRequests[nextRequest.text] = nil
                            end
                        end
                    end)
                end
                if ActiveRequests >= CONFIG.MAX_CONCURRENT_REQUESTS then
                    break
                end
                task.wait(0.05)
            end
            RequestTimer = nil
            if #RequestQueue > 0 then
                processRequestQueue()
            end
        end)
    end
end

-- 发起异步 AI 翻译请求
local function requestTranslate(text, callback)
    if not text or text == "" then
        if callback then callback(nil) end
        return
    end
    -- 查缓存
    if ApiCache[text] then
        if callback then callback(ApiCache[text]) end
        return
    end
    -- 已有 pending
    if PendingRequests[text] then
        if callback then table.insert(PendingRequests[text], callback) end
        return
    end
    PendingRequests[text] = callback and {callback} or {}
    table.insert(RequestQueue, {text = text})
    processRequestQueue()
end

-- 同步翻译函数（优先本地字典，其次 AI 缓存，否则返回原文并触发后台 AI 翻译）
local function translateText(text)
    if not text or type(text) ~= "string" or text == "" then
        return text
    end
    
    local processedText = text:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- 1. 精确匹配本地字典
    for en, cn in pairs(Translations) do
        if processedText == en or processedText == en .. ":" then
            return cn
        end
    end
    
    -- 2. 检查 AI 缓存
    if ApiCache[processedText] then
        return ApiCache[processedText]
    end
    
    -- 3. 未命中任何缓存，发起后台 AI 翻译请求，同时返回原文
    requestTranslate(processedText, function(translated)
        if translated then
            -- 译文会自动更新界面
        end
    end)
    
    return text  -- 暂时显示原文
end

-- 更新所有具有特定原文的 UI 元素
local function updateAllUIForText(originalText, translatedText)
    if not originalText or not translatedText then return end
    local containers = {CoreGui}
    local success, playerGui = pcall(function() return LocalPlayer.PlayerGui end)
    if success then table.insert(containers, playerGui) end
    pcall(function() table.insert(containers, StarterGui) end)
    
    for _, container in ipairs(containers) do
        if container then
            local descendants = container:GetDescendants()
            for _, obj in ipairs(descendants) do
                if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                    if obj.Text == originalText then
                        obj.Text = translatedText
                        if not TranslatedObjects[obj] then
                            TranslatedObjects[obj] = true
                        end
                    end
                end
            end
        end
    end
end

-- 缓存已翻译对象
local TranslatedObjects = setmetatable({}, {__mode = "k"})

-- 通知函数
local function showNotification(message)
    local success, result = pcall(function()
        local ScreenGui = Instance.new("ScreenGui")
        ScreenGui.Name = "TranslationNotification"
        ScreenGui.Parent = CoreGui
        ScreenGui.ResetOnSpawn = false
        local Frame = Instance.new("Frame")
        Frame.Size = UDim2.new(0, 300, 0, 100)
        Frame.Position = UDim2.new(0.5, -150, 0.5, -50)
        Frame.BackgroundColor3 = Color3.new(0.1, 0.1, 0.1)
        Frame.BorderColor3 = Color3.new(0.3, 0.3, 0.3)
        Frame.BorderSizePixel = 2
        Frame.Active = true
        Frame.Draggable = true
        Frame.Parent = ScreenGui
        local TextLabel = Instance.new("TextLabel")
        TextLabel.Size = UDim2.new(1, 0, 0.8, 0)
        TextLabel.Position = UDim2.new(0, 0, 0, 0)
        TextLabel.BackgroundTransparency = 1
        TextLabel.Text = message
        TextLabel.TextColor3 = Color3.new(1, 1, 1)
        TextLabel.TextScaled = true
        TextLabel.Parent = Frame
        local CloseButton = Instance.new("TextButton")
        CloseButton.Size = UDim2.new(1, 0, 0.2, 0)
        CloseButton.Position = UDim2.new(0, 0, 0.8, 0)
        CloseButton.BackgroundColor3 = Color3.new(0.2, 0.2, 0.2)
        CloseButton.Text = "关闭"
        CloseButton.TextColor3 = Color3.new(1, 1, 1)
        CloseButton.Parent = Frame
        CloseButton.MouseButton1Click:Connect(function()
            ScreenGui:Destroy()
        end)
        task.delay(CONFIG.NOTIFICATION_DURATION, function()
            if ScreenGui and ScreenGui.Parent then
                ScreenGui:Destroy()
            end
        end)
        return ScreenGui
    end)
    if not success then
        warn("通知创建失败:", result)
    end
end

-- 立即翻译单个GUI元素（同步部分）
local function translateGuiElementImmediately(gui)
    if TranslatedObjects[gui] then return false end
    local success, originalText = pcall(function() return gui.Text end)
    if not success or not originalText or originalText == "" then
        TranslatedObjects[gui] = true
        return false
    end
    local translatedText = translateText(originalText)
    if translatedText ~= originalText then
        local setSuccess = pcall(function()
            gui.Text = translatedText
        end)
        if setSuccess then
            TranslatedObjects[gui] = true
            return true
        end
    end
    TranslatedObjects[gui] = true
    return false
end

-- 批量立即翻译容器内的所有GUI元素
local function batchTranslateContainerImmediately(container)
    if not container then return 0 end
    local translatedCount = 0
    local elementsToTranslate = {}
    local descendants = container:GetDescendants()
    for _, descendant in ipairs(descendants) do
        if (descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox")) and not TranslatedObjects[descendant] then
            table.insert(elementsToTranslate, descendant)
        end
    end
    for i = 1, #elementsToTranslate, CONFIG.BATCH_PROCESS_SIZE do
        local batchEnd = math.min(i + CONFIG.BATCH_PROCESS_SIZE - 1, #elementsToTranslate)
        for j = i, batchEnd do
            if translateGuiElementImmediately(elementsToTranslate[j]) then
                translatedCount = translatedCount + 1
            end
        end
        if batchEnd < #elementsToTranslate then
            RunService.Heartbeat:Wait()
        end
    end
    return translatedCount
end

-- 设置文本变化监听（立即响应）
local function setupTextChangeListener(gui)
    if not gui:IsA("TextLabel") and not gui:IsA("TextButton") and not gui:IsA("TextBox") then
        return
    end
    local connection
    connection = gui:GetPropertyChangedSignal("Text"):Connect(function()
        if not gui or not gui.Parent then
            if connection then connection:Disconnect() end
            return
        end
        local currentText = gui.Text
        if currentText and currentText ~= "" then
            local translated = translateText(currentText)
            if translated ~= currentText then
                gui.Text = translated
            end
        end
    end)
end

-- 设置容器监听器（新元素立即翻译）
local function setupContainerListener(container)
    if not container then return end
    container.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
            translateGuiElementImmediately(descendant)
            setupTextChangeListener(descendant)
        end
    end)
end

-- 增强的元表劫持（立即生效）
local function setupEnhancedMetatableHijack()
    return pcall(function()
        local mt = getrawmetatable(game)
        if not mt then return false end
        local oldNewIndex = mt.__newindex
        if not oldNewIndex then return false end
        setreadonly(mt, false)
        mt.__newindex = newcclosure(function(t, k, v)
            if (t:IsA("TextLabel") or t:IsA("TextButton") or t:IsA("TextBox")) and k == "Text" then
                local original = tostring(v)
                local translated = translateText(original)
                if original ~= translated then
                    v = translated
                end
            end
            return oldNewIndex(t, k, v)
        end)
        setreadonly(mt, true)
        return true
    end)
end

-- 主翻译引擎
local function setupTranslationEngine()
    local totalTranslated = 0
    local metatableSuccess = setupEnhancedMetatableHijack()
    local containers = {CoreGui}
    local success, playerGui = pcall(function() return LocalPlayer.PlayerGui end)
    if success then table.insert(containers, playerGui) end
    pcall(function() table.insert(containers, StarterGui) end)
    
    for _, container in ipairs(containers) do
        if container then
            local count = batchTranslateContainerImmediately(container)
            totalTranslated = totalTranslated + count
        end
    end
    
    for _, container in ipairs(containers) do
        if container then
            setupContainerListener(container)
            local descendants = container:GetDescendants()
            for _, descendant in ipairs(descendants) do
                if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
                    setupTextChangeListener(descendant)
                end
            end
        end
    end
    
    if not metatableSuccess then
        warn("元表劫持失败，使用GUI扫描方案")
    end
    return totalTranslated
end

-- 主执行流程
local function main()
    task.wait(CONFIG.TRANSLATE_DELAY)
    local startTime = os.clock()
    local success, result = pcall(setupTranslationEngine)
    local elapsed = os.clock() - startTime
    if success then
        local count = result or 0
        showNotification(string.format("AI 翻译引擎加载完成\n风格：口语化 | 场景：娱乐\n已翻译 %d 个文本元素\n耗时: %.2f 秒", count, elapsed))
        print("=================================")
        print("AI 翻译引擎加载成功 v1.0")
        print("翻译风格: 随意口语化 | 场景: 娱乐")
        print("立即翻译了", count, "个文本元素")
        print("耗时:", string.format("%.2f", elapsed), "秒")
        print("未匹配的文本将通过 AI API 自动翻译")
        print("=================================")
    else
        showNotification("AI 翻译引擎加载失败")
        warn("AI 翻译引擎加载失败:", result)
    end
end

main()
