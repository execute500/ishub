local CONFIG = {
    TRANSLATE_DELAY = 0.2,
    NOTIFICATION_DURATION = 3,
    GUI_SCAN_DELAY = 0.02,
    BATCH_PROCESS_SIZE = 50,
    API_URL = "https://uapis.cn/api/v1/translate/text",
    TARGET_LANG = "zh",
    API_TIMEOUT = 12,
    API_RETRY_DELAY = 1,
    MAX_CONCURRENT_REQUESTS = 3,
    CACHE_FILE = "Qcumber_translate_cache.json",
    SHOW_PROGRESS = true,
    PROGRESS_POSITION = UDim2.new(0.5, -200, 0.85, 0)
}

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

-- ========== 本地字典（请粘贴完整） ==========
local Translations = {
}

-- ========== 中文检测函数（核心新增） ==========
local function isChinese(text)
    if not text or text == "" then return false end
    -- 检测中文字符的 UTF-8 编码范围
    -- 常用汉字范围：0x4E00-0x9FFF (E4 B8 80 到 E9 BF BF)
    return text:match("[\228-\234][\128-\191][\128-\191]") ~= nil
end

-- ========== 磁盘缓存支持 ==========
local function supportsFileIO()
    return pcall(function() return writefile and readfile end)
end

local function loadCacheFromFile()
    if not supportsFileIO() then return {} end
    local success, data = pcall(function()
        return readfile(CONFIG.CACHE_FILE)
    end)
    if not success or not data or data == "" then
        return {}
    end
    local decoded = HttpService:JSONDecode(data)
    if type(decoded) == "table" then
        return decoded
    else
        return {}
    end
end

local function saveCacheToFile(cacheTable)
    if not supportsFileIO() then return false end
    local success, json = pcall(function()
        return HttpService:JSONEncode(cacheTable)
    end)
    if not success then return false end
    pcall(function()
        writefile(CONFIG.CACHE_FILE, json)
    end)
    return true
end

-- ========== 全局缓存 ==========
local ApiCache = loadCacheFromFile()
local PendingRequests = {}
local RequestQueue = {}
local ActiveRequests = 0
local RequestTimer = nil
local TranslatedObjects = setmetatable({}, {__mode = "k"})

local function addToCache(original, translated)
    if not original or not translated then return end
    ApiCache[original] = translated
    task.spawn(function()
        saveCacheToFile(ApiCache)
    end)
end

-- ========== 进度条相关 ==========
local progressGui = nil
local progressText = nil
local progressBar = nil

local function createProgressBar()
    if not CONFIG.SHOW_PROGRESS then return end
    pcall(function()
        progressGui = Instance.new("ScreenGui")
        progressGui.Name = "TranslationProgress"
        progressGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        progressGui.Parent = CoreGui
        progressGui.ResetOnSpawn = false

        local mainFrame = Instance.new("Frame")
        mainFrame.Size = UDim2.new(0, 400, 0, 60)
        mainFrame.Position = CONFIG.PROGRESS_POSITION
        mainFrame.BackgroundColor3 = Color3.new(0.1, 0.1, 0.1)
        mainFrame.BorderColor3 = Color3.new(0.3, 0.3, 0.3)
        mainFrame.BorderSizePixel = 2
        mainFrame.Parent = progressGui

        progressText = Instance.new("TextLabel")
        progressText.Size = UDim2.new(1, 0, 0.4, 0)
        progressText.Position = UDim2.new(0, 0, 0, 0)
        progressText.BackgroundTransparency = 1
        progressText.Text = "初始化翻译引擎..."
        progressText.TextColor3 = Color3.new(1, 1, 1)
        progressText.TextScaled = true
        progressText.Parent = mainFrame

        local barBg = Instance.new("Frame")
        barBg.Size = UDim2.new(0.9, 0, 0.3, 0)
        barBg.Position = UDim2.new(0.05, 0, 0.55, 0)
        barBg.BackgroundColor3 = Color3.new(0.3, 0.3, 0.3)
        barBg.BorderSizePixel = 0
        barBg.Parent = mainFrame

        progressBar = Instance.new("Frame")
        progressBar.Size = UDim2.new(0, 0, 1, 0)
        progressBar.BackgroundColor3 = Color3.new(0.2, 0.8, 0.2)
        progressBar.BorderSizePixel = 0
        progressBar.Parent = barBg
    end)
end

local function updateProgress(text, percent)
    if not progressGui then return end
    pcall(function()
        if progressText then progressText.Text = text end
        if progressBar then
            progressBar.Size = UDim2.new(math.clamp(percent, 0, 1), 0, 1, 0)
        end
    end)
end

local function destroyProgressBar()
    if progressGui then
        pcall(function() progressGui:Destroy() end)
        progressGui = nil
    end
end

-- ========== UI 更新函数 ==========
local function updateAllUIForText(originalText, translatedText)
    if not originalText or not translatedText then return end
    local containers = { CoreGui }
    local success, playerGui = pcall(function() return LocalPlayer.PlayerGui end)
    if success then table.insert(containers, playerGui) end
    pcall(function() table.insert(containers, StarterGui) end)

    for _, container in ipairs(containers) do
        if container then
            for _, obj in ipairs(container:GetDescendants()) do
                if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                    if obj.Text == originalText then
                        obj.Text = translatedText
                        TranslatedObjects[obj] = true
                    end
                end
            end
        end
    end
end

-- ========== API 请求与队列 ==========
local function callTranslateAPI(text, callback)
    -- 额外安全：如果真的传入了中文，不请求 API
    if isChinese(text) then
        callback(text, nil)
        return
    end
    
    local requestBody = { text = text }
    local jsonBody = HttpService:JSONEncode(requestBody)

    local success, result = pcall(function()
        return HttpService:RequestAsync({
            Url = CONFIG.API_URL .. "?to_lang=" .. CONFIG.TARGET_LANG,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = jsonBody,
            Timeout = CONFIG.API_TIMEOUT
        })
    end)

    if not success then
        warn("API 请求失败: ", result)
        callback(nil, "Network error")
        return
    end

    local response = result
    if response.Success and response.StatusCode == 200 then
        local decoded = HttpService:JSONDecode(response.Body)
        if decoded and decoded.translate then
            callback(decoded.translate, nil)
            return
        else
            warn("API 返回缺少 'translate' 字段: ", response.Body)
            callback(nil, "Invalid response")
        end
    else
        warn("API 错误状态码: ", response.StatusCode, " Body: ", response.Body)
        callback(nil, "HTTP " .. tostring(response.StatusCode))
    end
end

local function processRequestQueue()
    if RequestTimer then return end
    RequestTimer = task.spawn(function()
        while #RequestQueue > 0 and ActiveRequests < CONFIG.MAX_CONCURRENT_REQUESTS do
            local nextRequest = table.remove(RequestQueue, 1)
            if nextRequest then
                ActiveRequests = ActiveRequests + 1
                callTranslateAPI(nextRequest.text, function(translated, err)
                    ActiveRequests = ActiveRequests - 1
                    if translated and translated ~= nextRequest.text then
                        addToCache(nextRequest.text, translated)
                        if PendingRequests[nextRequest.text] then
                            for _, cb in ipairs(PendingRequests[nextRequest.text]) do
                                cb(translated)
                            end
                            PendingRequests[nextRequest.text] = nil
                        end
                        task.spawn(function()
                            updateAllUIForText(nextRequest.text, translated)
                        end)
                    else
                        if PendingRequests[nextRequest.text] then
                            for _, cb in ipairs(PendingRequests[nextRequest.text]) do
                                cb(nil)
                            end
                            PendingRequests[nextRequest.text] = nil
                        end
                    end
                end)
            end
            if ActiveRequests >= CONFIG.MAX_CONCURRENT_REQUESTS then break end
            task.wait(0.05)
        end
        RequestTimer = nil
        if #RequestQueue > 0 then processRequestQueue() end
    end)
end

local function requestTranslate(text, callback)
    if not text or text == "" then
        if callback then callback(nil) end
        return
    end
    -- 如果是中文，不发起请求
    if isChinese(text) then
        if callback then callback(text) end
        return
    end
    if ApiCache[text] then
        if callback then callback(ApiCache[text]) end
        return
    end
    if PendingRequests[text] then
        if callback then table.insert(PendingRequests[text], callback) end
        return
    end
    PendingRequests[text] = callback and {callback} or {}
    table.insert(RequestQueue, { text = text })
    processRequestQueue()
end

-- ========== 核心翻译函数（带中文检测） ==========
local function translateText(text)
    if not text or type(text) ~= "string" or text == "" then
        return text
    end
    local processedText = text:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- 【关键】如果已经是中文，直接返回原文，不进行任何翻译
    if isChinese(processedText) then
        return text
    end

    -- 1. 本地字典精确匹配
    for en, cn in pairs(Translations) do
        if processedText == en or processedText == en .. ":" then
            return cn
        end
    end

    -- 2. API 缓存
    if ApiCache[processedText] then
        return ApiCache[processedText]
    end

    -- 3. 发起后台翻译请求，当前返回原文
    requestTranslate(processedText, nil)
    return text
end

-- ========== GUI 处理函数 ==========
local function showNotification(message)
    pcall(function()
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
        CloseButton.MouseButton1Click:Connect(function() ScreenGui:Destroy() end)
        task.delay(CONFIG.NOTIFICATION_DURATION, function()
            if ScreenGui and ScreenGui.Parent then ScreenGui:Destroy() end
        end)
    end)
end

local function translateGuiElementImmediately(gui)
    if TranslatedObjects[gui] then return false end
    local success, originalText = pcall(function() return gui.Text end)
    if not success or not originalText or originalText == "" then
        TranslatedObjects[gui] = true
        return false
    end
    local translated = translateText(originalText)
    if translated ~= originalText then
        local ok = pcall(function() gui.Text = translated end)
        if ok then
            TranslatedObjects[gui] = true
            return true
        end
    end
    TranslatedObjects[gui] = true
    return false
end

-- 带进度条的批量翻译
local function batchTranslateWithProgress(containers)
    local allElements = {}
    for _, container in ipairs(containers) do
        if container then
            for _, d in ipairs(container:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and not TranslatedObjects[d] then
                    table.insert(allElements, d)
                end
            end
        end
    end
    local total = #allElements
    if total == 0 then return 0 end
    
    updateProgress(string.format("扫描到 %d 个文本控件，开始翻译...", total), 0)
    task.wait(0.1)
    
    local translatedCount = 0
    for i = 1, total, CONFIG.BATCH_PROCESS_SIZE do
        local endIdx = math.min(i + CONFIG.BATCH_PROCESS_SIZE - 1, total)
        for j = i, endIdx do
            if translateGuiElementImmediately(allElements[j]) then
                translatedCount = translatedCount + 1
            end
        end
        local percent = endIdx / total
        updateProgress(string.format("翻译控件中: %d / %d", endIdx, total), percent)
        if endIdx < total then
            RunService.Heartbeat:Wait()
        end
    end
    return translatedCount
end

local function setupTextChangeListener(gui)
    if not gui:IsA("TextLabel") and not gui:IsA("TextButton") and not gui:IsA("TextBox") then return end
    local conn
    conn = gui:GetPropertyChangedSignal("Text"):Connect(function()
        if not gui or not gui.Parent then
            if conn then conn:Disconnect() end
            return
        end
        local current = gui.Text
        if current and current ~= "" then
            -- 新增：如果已经是中文，不做处理
            if isChinese(current) then return end
            local translated = translateText(current)
            if translated ~= current then
                gui.Text = translated
            end
        end
    end)
end

local function setupContainerListener(container)
    if not container then return end
    container.DescendantAdded:Connect(function(child)
        if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
            translateGuiElementImmediately(child)
            setupTextChangeListener(child)
        end
    end)
end

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
                -- 新增：如果已经是中文，跳过翻译
                if not isChinese(original) then
                    local translated = translateText(original)
                    if original ~= translated then v = translated end
                end
            end
            return oldNewIndex(t, k, v)
        end)
        setreadonly(mt, true)
        return true
    end)
end

local function setupTranslationEngine()
    createProgressBar()
    updateProgress("正在初始化翻译引擎...", 0.1)
    task.wait(0.1)
    
    setupEnhancedMetatableHijack()
    
    local containers = { CoreGui }
    local ok, pg = pcall(function() return LocalPlayer.PlayerGui end)
    if ok then table.insert(containers, pg) end
    pcall(function() table.insert(containers, StarterGui) end)
    
    local totalTranslated = batchTranslateWithProgress(containers)
    
    updateProgress("正在设置监听器...", 0.95)
    for _, c in ipairs(containers) do
        if c then
            setupContainerListener(c)
            for _, d in ipairs(c:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                    setupTextChangeListener(d)
                end
            end
        end
    end
    
    updateProgress("完成！", 1)
    task.wait(0.3)
    destroyProgressBar()
    
    return totalTranslated
end

local function main()
    task.wait(CONFIG.TRANSLATE_DELAY)
    local start = os.clock()
    local ok, count = pcall(setupTranslationEngine)
    local elapsed = os.clock() - start
    if ok then
        local cacheSize = 0
        for _ in pairs(ApiCache) do cacheSize = cacheSize + 1 end
        showNotification(string.format("翻译引擎加载完成（中文保护+API缓存）\n已翻译 %d 个文本元素\n磁盘缓存 %d 条\n耗时: %.2f 秒", count, cacheSize, elapsed))
        print("=================================")
        print("翻译引擎加载成功 (已启用中文保护)")
        print("翻译了", count, "个元素，磁盘缓存", cacheSize, "条")
        print("耗时", string.format("%.2f", elapsed), "秒")
        print("=================================")
    else
        destroyProgressBar()
        showNotification("翻译引擎加载失败")
        warn("加载失败:", count)
    end
end

main()