local uiOpen = false
local previewEntity = 0
local previewModel = 0
local latestPayload = nil
local DEFAULT_BONE_ID = 0
local SAFE_BONE_ID = 57005
local previewCam = 0
local lastAttachBoneIndex = -1
local previewAnimHold = false
local previewAnimDictStored = nil
local previewAnimNameStored = nil
local previewAnimLoopStored = nil
local previewAnimUpperBodyStored = nil
local previewAnimOneShotSeq = 0
local lastBoneId = 0
local debugOutline = true
local debugDrawLine = true
local CAM_DEFAULTS = {
    orbitYaw = 180.0,
    pitch = 8.0,
    distance = 2.2,
    lookZ = 0.55,
    panX = 0.0,
    panY = 0.0,
    fov = 48.0
}
local camState = {
    orbitYaw = CAM_DEFAULTS.orbitYaw,
    pitch = CAM_DEFAULTS.pitch,
    distance = CAM_DEFAULTS.distance,
    lookZ = CAM_DEFAULTS.lookZ,
    panX = CAM_DEFAULTS.panX,
    panY = CAM_DEFAULTS.panY,
    fov = CAM_DEFAULTS.fov
}

local function resetPreviewCamState()
    camState.orbitYaw = CAM_DEFAULTS.orbitYaw
    camState.pitch = CAM_DEFAULTS.pitch
    camState.distance = CAM_DEFAULTS.distance
    camState.lookZ = CAM_DEFAULTS.lookZ
    camState.panX = CAM_DEFAULTS.panX
    camState.panY = CAM_DEFAULTS.panY
    camState.fov = CAM_DEFAULTS.fov
end

local function sendToUi(action, data)
    SendNUIMessage({
        action = action,
        data = data or {}
    })
end

local function setUiOpen(state)
    uiOpen = state
    SetNuiFocus(state, state)
    SetNuiFocusKeepInput(false)
end

local function clearPreviewCam()
    if previewCam ~= 0 and DoesCamExist(previewCam) then
        RenderScriptCams(false, true, 300, true, true)
        DestroyCam(previewCam, false)
    end
    previewCam = 0
end

local function updatePreviewCamPosition()
    if previewCam == 0 or not DoesCamExist(previewCam) then
        return
    end

    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return
    end

    local focus = GetOffsetFromEntityInWorldCoords(ped, camState.panX, camState.panY, camState.lookZ)
    local fwd = GetEntityForwardVector(ped)
    local rightX = -fwd.y
    local rightY = fwd.x
    local rightLen = math.sqrt(rightX * rightX + rightY * rightY)
    if rightLen <= 0.0001 then
        rightX, rightY = 1.0, 0.0
    else
        rightX = rightX / rightLen
        rightY = rightY / rightLen
    end
    local yaw = math.rad(camState.orbitYaw)
    local pitch = math.rad(camState.pitch)
    local cp = math.cos(pitch)
    local sp = math.sin(pitch)
    local d = camState.distance
    local offH = d * cp
    local dirX = (fwd.x * math.cos(yaw)) + (rightX * math.sin(yaw))
    local dirY = (fwd.y * math.cos(yaw)) + (rightY * math.sin(yaw))
    local camX = focus.x + offH * dirX
    local camY = focus.y + offH * dirY
    local camZ = focus.z + d * sp

    SetCamCoord(previewCam, camX, camY, camZ)
    PointCamAtCoord(previewCam, focus.x, focus.y, focus.z)
    SetCamFov(previewCam, camState.fov + 0.0)
end

local function setupPreviewCam()
    clearPreviewCam()

    previewCam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    if previewCam == 0 then
        return
    end

    updatePreviewCamPosition()
    RenderScriptCams(true, true, 300, true, true)
end

local function payloadFloat(v, default)
    if v == nil then
        return default
    end
    if type(v) == "number" and v == v then
        return v + 0.0
    end
    if type(v) == "string" then
        local s = v:gsub(",", ".")
        local n = tonumber(s)
        if n == nil then
            return default
        end
        return n + 0.0
    end
    return default
end

--- Some NUI/JSON paths deliver integers; natives expect float offsets.
local function attachFloat(v, default)
    local x = payloadFloat(v, default)
    return tonumber(string.format("%.6f", x)) or default
end

--- NUI may send { payload = {...} } or a flat table; ignore formattedResult etc.
local MERGE_KEYS = {
    model = true,
    Model = true,
    boneId = true,
    Bone = true,
    bone = true,
    posX = true,
    posY = true,
    posZ = true,
    rawRotX = true,
    rawRotY = true,
    rawRotZ = true,
    snapPos = true,
    snapRot = true,
    animStart = true,
    animEnd = true,
    animLoop = true,
    animUpperBody = true,
    animDict = true,
    animName = true,
    AnimUpperBody = true,
    AnimDict = true,
    AnimName = true,
    theme = true,
    softPin = true,
    rotOrder = true,
    fixRot = true,
    debugOutline = true,
    debugDrawLine = true
}

local function nuiPayloadFrom(data)
    if type(data) ~= "table" then
        return {}
    end
    if type(data.payload) == "string" and data.payload ~= "" then
        local ok, decoded = pcall(json.decode, data.payload)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end
    if type(data.payload) == "table" then
        return data.payload
    end
    if data.model ~= nil or data.Model ~= nil or data.boneId ~= nil or data.posX ~= nil then
        return data
    end
    return {}
end

local function mergeIncomingPayload(data)
    local incoming = nuiPayloadFrom(data)
    if type(incoming) ~= "table" then
        return
    end
    latestPayload = latestPayload or {}
    for k, v in pairs(incoming) do
        if MERGE_KEYS[k] then
            latestPayload[k] = v
        end
    end
end

--- NUI table can have pos on root or only under .payload; merge alone can miss edge cases.
local function syncAttachFieldsFromMessage(data)
    if type(data) ~= "table" then
        return
    end
    local pl = data.payload
    if type(pl) ~= "table" then
        return
    end
    latestPayload = latestPayload or {}
    if pl.posX ~= nil then
        latestPayload.posX = payloadFloat(pl.posX, latestPayload.posX or 0.0)
    end
    if pl.posY ~= nil then
        latestPayload.posY = payloadFloat(pl.posY, latestPayload.posY or 0.0)
    end
    if pl.posZ ~= nil then
        latestPayload.posZ = payloadFloat(pl.posZ, latestPayload.posZ or 0.0)
    end
    if pl.rawRotX ~= nil then
        latestPayload.rawRotX = payloadFloat(pl.rawRotX, latestPayload.rawRotX or 0.0)
    end
    if pl.rawRotY ~= nil then
        latestPayload.rawRotY = payloadFloat(pl.rawRotY, latestPayload.rawRotY or 0.0)
    end
    if pl.rawRotZ ~= nil then
        latestPayload.rawRotZ = payloadFloat(pl.rawRotZ, latestPayload.rawRotZ or 0.0)
    end
    if pl.boneId ~= nil then
        latestPayload.boneId = pl.boneId
    end
    if pl.model ~= nil then
        latestPayload.model = pl.model
    end
    if pl.Model ~= nil then
        latestPayload.Model = pl.Model
    end
    if pl.animDict ~= nil then
        latestPayload.animDict = pl.animDict
    end
    if pl.animName ~= nil then
        latestPayload.animName = pl.animName
    end
    if pl.AnimDict ~= nil then
        latestPayload.AnimDict = pl.AnimDict
    end
    if pl.AnimName ~= nil then
        latestPayload.AnimName = pl.AnimName
    end
    if pl.animLoop ~= nil then
        latestPayload.animLoop = pl.animLoop
    end
    if pl.animUpperBody ~= nil then
        latestPayload.animUpperBody = pl.animUpperBody
    end
    if pl.AnimUpperBody ~= nil then
        latestPayload.AnimUpperBody = pl.AnimUpperBody
    end
end

local function previewAnimDictName()
    if type(latestPayload) ~= "table" then
        return nil, nil
    end
    local d = latestPayload.animDict or latestPayload.AnimDict
    local n = latestPayload.animName or latestPayload.AnimName
    if type(d) ~= "string" or type(n) ~= "string" then
        return nil, nil
    end
    d = d:gsub("^%s*(.-)%s*$", "%1")
    n = n:gsub("^%s*(.-)%s*$", "%1")
    if d == "" or n == "" then
        return nil, nil
    end
    return d, n
end

local function stopPreviewAnim()
    previewAnimOneShotSeq = previewAnimOneShotSeq + 1
    local ped = PlayerPedId()
    if ped ~= 0 and DoesEntityExist(ped) then
        ClearPedTasks(ped)
    end
    previewAnimHold = false
    previewAnimDictStored = nil
    previewAnimNameStored = nil
    previewAnimLoopStored = nil
    previewAnimUpperBodyStored = nil
end

--- NUI/json อาจส่ง animLoop เป็น string หรือค่าประหลาด — บังคับให้ลูปแค่เมื่อเปิดจริง
local function payloadAnimLoopEnabled()
    if type(latestPayload) ~= "table" then
        return true
    end
    local v = latestPayload.animLoop
    if v == nil then
        return true
    end
    if v == false or v == 0 then
        return false
    end
    if type(v) == "string" then
        local s = string.lower((tostring(v):gsub("^%s*(.-)%s*$", "%1")))
        if s == "false" or s == "0" or s == "off" or s == "no" then
            return false
        end
    end
    return true
end

local function payloadAnimUpperBodyEnabled()
    if type(latestPayload) ~= "table" then
        return true
    end
    local v = latestPayload.animUpperBody
    if v == nil then
        v = latestPayload.AnimUpperBody
    end
    if v == nil then
        return true
    end
    if v == false or v == 0 then
        return false
    end
    if type(v) == "string" then
        local s = string.lower((tostring(v):gsub("^%s*(.-)%s*$", "%1")))
        if s == "false" or s == "0" or s == "off" or s == "no" or s == "full" or s == "fullbody" then
            return false
        end
    end
    return true
end

local function pausePreviewAnim()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return
    end
    local d = previewAnimDictStored
    local n = previewAnimNameStored
    if type(d) ~= "string" or type(n) ~= "string" or d == "" or n == "" then
        return
    end
    if IsEntityPlayingAnim(ped, d, n, 3) then
        SetEntityAnimSpeed(ped, d, n, 0.0)
        previewAnimHold = true
    else
        previewAnimHold = false
    end
end

local function taskPlayAnimWithFallback(ped, dict, name, durationMs, flagsList)
    for _, f in ipairs(flagsList) do
        TaskPlayAnim(ped, dict, name, 8.0, 8.0, durationMs, f, 1.0, false, false, false)
        for _ = 1, 12 do
            Wait(0)
            if IsEntityPlayingAnim(ped, dict, name, 3) then
                return true, f
            end
        end
    end
    return false, nil
end

local function playPreviewAnimFromPayload()
    local dict, name = previewAnimDictName()
    if not dict or not name then
        return false
    end
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return false
    end
    local wantsLoop = payloadAnimLoopEnabled()
    local wantsUpperBody = payloadAnimUpperBodyEnabled()
    if previewAnimHold and previewAnimDictStored == dict and previewAnimNameStored == name and previewAnimLoopStored == wantsLoop and previewAnimUpperBodyStored == wantsUpperBody then
        if IsEntityPlayingAnim(ped, dict, name, 3) then
            SetEntityAnimSpeed(ped, dict, name, 1.0)
            previewAnimHold = false
            return true
        end
    end
    previewAnimHold = false
    previewAnimOneShotSeq = previewAnimOneShotSeq + 1
    local oneShotSeq = previewAnimOneShotSeq
    RequestAnimDict(dict)
    local timeoutAt = GetGameTimer() + 8000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeoutAt do
        Wait(0)
    end
    if not HasAnimDictLoaded(dict) then
        print(("[attach_builder] anim dict failed to load: %s"):format(dict))
        return false
    end
    ClearPedSecondaryTask(ped)
    StopAnimTask(ped, dict, name, 2.0)
    Wait(0)
    --- 49 = loop + secondary+upperbody. 48 = one-shot secondary+upperbody.
    local loopFlags = wantsUpperBody and { 49, 17, 1, 0 } or { 1, 0 }
    local oneShotFlags = wantsUpperBody and { 49, 17, 48, 1, 0 } or { 1, 0 }
    if wantsLoop then
        local ok = taskPlayAnimWithFallback(ped, dict, name, -1, loopFlags)
        if not ok then
            print(("[attach_builder] anim play failed (loop on): %s / %s"):format(dict, name))
            return false
        end
    else
        -- One-shot mode: play with a reliable looping task, then stop ourselves after one full cycle.
        local ok = taskPlayAnimWithFallback(ped, dict, name, -1, oneShotFlags)
        if not ok then
            print(("[attach_builder] anim play failed (loop off,start): %s / %s"):format(dict, name))
            return false
        end
        CreateThread(function()
            local d0, n0, p0 = dict, name, ped
            local started = false
            local minRunAt = GetGameTimer() + 250
            local deadline = GetGameTimer() + 45000
            while previewAnimOneShotSeq == oneShotSeq and GetGameTimer() < deadline do
                Wait(0)
                if not DoesEntityExist(p0) then
                    break
                end
                if not IsEntityPlayingAnim(p0, d0, n0, 3) then
                    if started then
                        break
                    end
                else
                    local ct = GetEntityAnimCurrentTime(p0, d0, n0)
                    if ct > 0.02 then
                        started = true
                    end
                    if started and GetGameTimer() >= minRunAt and ct >= 0.985 then
                        StopAnimTask(p0, d0, n0, 2.0)
                        break
                    end
                end
            end
        end)
    end
    previewAnimDictStored = dict
    previewAnimNameStored = name
    previewAnimLoopStored = wantsLoop
    previewAnimUpperBodyStored = wantsUpperBody
    return true
end

local function sanitizeModelName(name)
    if name == nil then
        return ""
    end
    local s = tostring(name):gsub("^%s*(.-)%s*$", "%1")
    if s == "" then
        return ""
    end
    local lower = string.lower(s)
    if lower == "pos" or lower == "rot" or lower == "bone" or lower == "model" then
        return ""
    end
    return s
end

local function cleanupPreview()
    if previewEntity ~= 0 and DoesEntityExist(previewEntity) then
        DeleteEntity(previewEntity)
    end
    previewEntity = 0
    previewModel = 0
    lastAttachBoneIndex = -1
    sendToUi("debugUpdate", { entityId = 0, worldPos = nil })
end

local function sendDebugToNui()
    if previewEntity == 0 or not DoesEntityExist(previewEntity) then
        sendToUi("debugUpdate", { entityId = 0, worldPos = nil })
        return
    end
    local c = GetEntityCoords(previewEntity)
    sendToUi("debugUpdate", {
        entityId = previewEntity,
        worldPos = { x = c.x, y = c.y, z = c.z }
    })
end

local function drawPreviewWireBox(entity, r, g, b, a)
    if entity == 0 or not DoesEntityExist(entity) then
        return
    end
    local model = GetEntityModel(entity)
    local minD, maxD = GetModelDimensions(model)
    if not minD or not maxD then
        return
    end
    local corners = {
        vector3(minD.x, minD.y, minD.z),
        vector3(maxD.x, minD.y, minD.z),
        vector3(maxD.x, maxD.y, minD.z),
        vector3(minD.x, maxD.y, minD.z),
        vector3(minD.x, minD.y, maxD.z),
        vector3(maxD.x, minD.y, maxD.z),
        vector3(maxD.x, maxD.y, maxD.z),
        vector3(minD.x, maxD.y, maxD.z)
    }
    local w = {}
    for i = 1, 8 do
        local c = corners[i]
        w[i] = GetOffsetFromEntityInWorldCoords(entity, c.x, c.y, c.z)
    end
    local edges = {
        { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
        { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
        { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 }
    }
    for _, e in ipairs(edges) do
        local p1, p2 = w[e[1]], w[e[2]]
        DrawLine(p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, r, g, b, a)
    end
end

local function drawBuilderDebug()
    if not uiOpen then
        return
    end
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return
    end
    if previewEntity == 0 or not DoesEntityExist(previewEntity) then
        return
    end
    if debugDrawLine and lastAttachBoneIndex >= 0 then
        local boneW = GetWorldPositionOfEntityBone(ped, lastAttachBoneIndex)
        local propW = GetEntityCoords(previewEntity)
        if boneW and propW then
            local dx = boneW.x - propW.x
            local dy = boneW.y - propW.y
            local dz = boneW.z - propW.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 0.01 and d < 50.0 then
                DrawLine(boneW.x, boneW.y, boneW.z, propW.x, propW.y, propW.z, 80, 200, 255, 220)
            end
        end
    end
    if debugOutline then
        drawPreviewWireBox(previewEntity, 255, 200, 80, 200)
    end
end

local function ensureModelLoaded(modelHash)
    if not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) then
        return false
    end

    if not HasModelLoaded(modelHash) then
        RequestModel(modelHash)
        local timeoutAt = GetGameTimer() + 5000
        while not HasModelLoaded(modelHash) and GetGameTimer() < timeoutAt do
            Wait(0)
        end
    end

    return HasModelLoaded(modelHash)
end

local function ensurePreviewEntity(modelHash, pedCoords)
    if previewEntity ~= 0 and DoesEntityExist(previewEntity) and previewModel == modelHash then
        return true
    end

    cleanupPreview()

    if not ensureModelLoaded(modelHash) then
        return false
    end

    previewEntity = CreateObjectNoOffset(modelHash, pedCoords.x, pedCoords.y, pedCoords.z, false, false, false)
    if previewEntity == 0 or not DoesEntityExist(previewEntity) then
        previewEntity = 0
        return false
    end

    previewModel = modelHash
    SetModelAsNoLongerNeeded(modelHash)
    SetEntityCollision(previewEntity, false, false)
    SetEntityAsMissionEntity(previewEntity, true, true)
    return true
end

local function applyPreview(data)
    mergeIncomingPayload(data)
    syncAttachFieldsFromMessage(data)

    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        return
    end

    debugOutline = latestPayload.debugOutline ~= false
    debugDrawLine = latestPayload.debugDrawLine ~= false

    local rawModel = tostring(latestPayload.model or latestPayload.Model or ""):gsub("^%s*(.-)%s*$", "%1")
    local modelName = sanitizeModelName(latestPayload.model or latestPayload.Model)
    if modelName == "" then
        if rawModel ~= "" then
            latestPayload.model = ""
            latestPayload.Model = nil
        end
        cleanupPreview()
        return
    end
    local modelHash = type(modelName) == "number" and modelName or joaat(modelName)
    if not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) then
        print(("[attach_builder] invalid model '%s'"):format(tostring(modelName)))
        cleanupPreview()
        return
    end
    local pedCoords = GetEntityCoords(ped)
    if not ensurePreviewEntity(modelHash, pedCoords) then
        print(("[attach_builder] failed loading model '%s'"):format(tostring(modelName)))
        return
    end

    local boneId = tonumber(latestPayload.boneId or latestPayload.Bone or latestPayload.bone) or DEFAULT_BONE_ID
    local boneIndex = GetPedBoneIndex(ped, boneId)
    if boneIndex == -1 or boneIndex == 0 then
        boneId = SAFE_BONE_ID
        boneIndex = GetPedBoneIndex(ped, boneId)
    end
    lastBoneId = boneId
    lastAttachBoneIndex = boneIndex
    local posX = attachFloat(latestPayload.posX, 0.0)
    local posY = attachFloat(latestPayload.posY, 0.0)
    local posZ = attachFloat(latestPayload.posZ, 0.0)
    local rotX = attachFloat(latestPayload.rawRotX, 0.0)
    local rotY = attachFloat(latestPayload.rawRotY, 0.0)
    local rotZ = attachFloat(latestPayload.rawRotZ, 0.0)
    if latestPayload.rotOrder == true then
        rotX, rotY, rotZ = rotZ, rotY, rotX
    end

    local useSoftPinning = latestPayload.softPin == true
    local fixedRot = latestPayload.fixRot == true

    --- Always detach first: without detach the engine often keeps the first offset forever.
    if previewEntity ~= 0 and DoesEntityExist(previewEntity) then
        DetachEntity(previewEntity, true, true)
        FreezeEntityPosition(previewEntity, false)
        Wait(0)
    end

    AttachEntityToEntity(
        previewEntity,
        ped,
        boneIndex,
        posX,
        posY,
        posZ,
        rotX,
        rotY,
        rotZ,
        false,
        useSoftPinning,
        false,
        false,
        2,
        fixedRot
    )
    sendDebugToNui()
end

local function closeBuilderUi()
    if not uiOpen then
        return
    end
    setUiOpen(false)
    FreezeEntityPosition(PlayerPedId(), false)
    clearPreviewCam()
    stopPreviewAnim()
    sendToUi("close", {})
    cleanupPreview()
end

RegisterCommand("attach_builder", function()
    if uiOpen then
        closeBuilderUi()
        return
    end
    resetPreviewCamState()
    setUiOpen(true)
    FreezeEntityPosition(PlayerPedId(), true)
    setupPreviewCam()
    sendToUi("open", { payload = latestPayload })
    if latestPayload then
        applyPreview(latestPayload)
    end
end, false)

RegisterNUICallback("uiReady", function(data, cb)
    cb({ ok = true })
    if not uiOpen then
        return
    end

    sendToUi("open", {
        payload = data and data.payload or nil
    })
end)

RegisterNUICallback("builderStateUpdate", function(data, cb)
    applyPreview(data)
    cb({ ok = true })
end)

RegisterNUICallback("animPreview", function(data, cb)
    if type(data) == "table" then
        latestPayload = latestPayload or {}
        if data.animDict ~= nil then
            latestPayload.animDict = data.animDict
        end
        if data.animName ~= nil then
            latestPayload.animName = data.animName
        end
        if data.animLoop ~= nil then
            latestPayload.animLoop = data.animLoop
        end
        if data.animUpperBody ~= nil then
            latestPayload.animUpperBody = data.animUpperBody
        end
        local cmd = data.cmd
        if cmd == "play" then
            playPreviewAnimFromPayload()
        elseif cmd == "pause" then
            pausePreviewAnim()
        elseif cmd == "reset" then
            stopPreviewAnim()
        end
    end
    cb({ ok = true })
end)

RegisterNUICallback("freecamUpdate", function(data, cb)
    if type(data) == "table" then
        if data.orbitYaw ~= nil then
            camState.orbitYaw = tonumber(data.orbitYaw) or camState.orbitYaw
        end
        if data.pitch ~= nil then
            local p = tonumber(data.pitch) or camState.pitch
            camState.pitch = math.max(-89.0, math.min(89.0, p))
        end
        if data.distance ~= nil then
            local dist = tonumber(data.distance) or camState.distance
            camState.distance = math.max(0.5, math.min(50.0, dist))
        end
        if data.lookZ ~= nil then
            camState.lookZ = tonumber(data.lookZ) or camState.lookZ
        end
        if data.panX ~= nil then
            camState.panX = tonumber(data.panX) or camState.panX
        end
        if data.panY ~= nil then
            camState.panY = tonumber(data.panY) or camState.panY
        end
        if data.fov ~= nil then
            local f = tonumber(data.fov) or camState.fov
            camState.fov = math.max(10.0, math.min(120.0, f))
        end
    end
    updatePreviewCamPosition()
    cb({ ok = true })
end)

RegisterNUICallback("copyResult", function(data, cb)
    local text = (data and data.text) or ""
    if text ~= "" then
        print(("[attach_builder] Copied output: %s"):format(text))
    end
    cb({ ok = true })
end)

RegisterNUICallback("presetsLoad", function(_, cb)
    local raw = LoadResourceFile(GetCurrentResourceName(), "presets.json")
    if type(raw) ~= "string" or raw == "" then
        cb({ ok = true, presets = {} })
        return
    end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        cb({ ok = true, presets = {} })
        return
    end
    cb({ ok = true, presets = decoded })
end)

RegisterNUICallback("presetsSave", function(data, cb)
    local presets = data and data.presets
    if type(presets) ~= "table" then
        cb({ ok = false, error = "invalid_presets_payload" })
        return
    end
    local encoded = json.encode(presets)
    if type(encoded) ~= "string" or encoded == "" then
        cb({ ok = false, error = "encode_failed" })
        return
    end
    local wrote = SaveResourceFile(GetCurrentResourceName(), "presets.json", encoded, -1)
    cb({ ok = wrote == true })
end)

RegisterNUICallback("close", function(_, cb)
    closeBuilderUi()
    cb({ ok = true })
end)

RegisterKeyMapping("attach_builder", "Open attach builder", "keyboard", "F7")

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end
    FreezeEntityPosition(PlayerPedId(), false)
    clearPreviewCam()
    stopPreviewAnim()
    cleanupPreview()
end)

CreateThread(function()
    while true do
        if uiOpen then
            local ped = PlayerPedId()
            if ped ~= 0 and DoesEntityExist(ped) and not IsEntityPositionFrozen(ped) then
                FreezeEntityPosition(ped, true)
            end
            if previewCam ~= 0 and DoesCamExist(previewCam) then
                updatePreviewCamPosition()
            end
            drawBuilderDebug()
            Wait(0)
        else
            Wait(200)
        end
    end
end)
