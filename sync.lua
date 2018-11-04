local sync = {}


local enet = require 'enet'
local bitser = require 'bitser'


local BANDWIDTH_LIMIT = 0 -- Bandwidth limit in bytes per second -- 0 for unlimited

local DESPAWNED = true -- Sentinel for despawned entities -- `true` is a single byte when bitser'd


-- Ids

local idCounter = 0

local function genId() -- Must be called on server
    idCounter = idCounter + 1
    return idCounter
end


-- Types

local typeNameToType, typeIdToName = {}, {}

function sync.registerType(typeName, ty)
    assert(not typeNameToType[typeName], "type with name '" .. typeName .. "' already registered")

    ty = ty or {}
    ty.__typeName = typeName
    typeNameToType[typeName] = ty

    table.insert(typeIdToName, typeName)
    ty.__typeId = #typeIdToName

    return ty
end


-- Manager metatables, creation

local Common = {}
Common.__index = Common

local Client = setmetatable({}, Common)
Client.__index = Client

local Server = setmetatable({}, Common)
Server.__index = Server

function sync.newServer(props)
    local mgr = setmetatable({}, Server)
    mgr:init(props)
    return mgr
end

function sync.newClient(props)
    local mgr = setmetatable({}, Client)
    mgr:init(props)
    return mgr
end


-- Initialization, disconnection

function Common:init(props)
    -- Each of these tables is a 'set' of the form `t[k.__id] = k` for all `k` in the set
    self.all = {} -- Entities we can read
    self.needsSend = {} -- Entities whose sync we need to send
    self.receivedSyncsDumps = {} -- Received syncs pending apply
end

function Server:init(props)
    Common.init(self)

    self.isServer, self.isClient = true, false

    self.controllerTypeName = assert(props.controllerTypeName,
        "server needs `props.controllerTypeName`")

    self.host = enet.host_create(props.address or '*:22122')
    self.host:bandwidth_limit(BANDWIDTH_LIMIT, BANDWIDTH_LIMIT)
    self.controllers = {}
end

function Client:init(props)
    Common.init(self)

    assert(props.address, "client needs `props.address` to connect to")

    self.isServer, self.isClient = false, true

    self.host = enet.host_create()
    self.host:bandwidth_limit(BANDWIDTH_LIMIT, BANDWIDTH_LIMIT)
    self.serverPeer = self.host:connect(props.address)
end

function Client:disconnect()
    self.serverPeer:disconnect()
    self.host:flush()
end


-- RPCs

local rpcNameToId, rpcIdToName = {}, {}

local function defRpc(name)
    if not rpcNameToId[name] then
        table.insert(rpcIdToName, name)
        rpcNameToId[name] = #rpcIdToName
    end
end

local function rpcToData(name, ...)
    return bitser.dumps({ rpcNameToId[name], select('#', ...), ... })
end

local function dataToRpc(data)
    local t = bitser.loads(data)
    return assert(rpcIdToName[t[1]], "invalid rpc id"), unpack(t, 3, t[2] + 2)
end

function Common:callRpc(peer, name, ...)
    self[name](self, peer, ...)
end


-- Spawning

function Common:construct(typeName, ...)
    local ent

    local ty = assert(typeNameToType[typeName], "no type with name '" .. typeName .. "'")
    if ty.construct then -- User-defined construction
        ent = ty:construct(...)
    else -- Default construction
        ty.__index = ty
        ent = setmetatable({}, ty)
    end
    ent.__typeId = ty.__typeId
    ent.__mgr = self
    ent.__local = {}

    if ent.didConstruct then
        ent:didConstruct(...)
    end
    return ent
end

function Common:destruct(ent)
    if ent.didDestruct then
        ent:didDestruct()
    end

    ent.__mgr = nil
end

function Server:spawn(typeName, ...)
    local ent = self:construct(typeName, ...)
    ent.__id = genId()

    self.all[ent.__id] = ent

    if ent.didSpawn then
        ent:didSpawn(...)
    end
    self:sync(ent)

    return ent
end

function Server:despawn(ent)
    if ent.__despawned then
        return
    end

    if ent.willDespawn then
        ent:willDespawn()
    end

    ent.__despawned = true
    self.all[ent.__id] = nil
    self:sync(ent)

    self:destruct(ent)
end


-- Sync

function Server:sync(ent)
    if ent.__despawned then
        self.needsSend[ent.__id] = DESPAWNED
    else
        self.needsSend[ent.__id] = ent
    end
end

function Client:sync(ent)
end

function Server:sendSyncs(peer, syncs) -- `peer == nil` to broadcast to all connected peers
    if not next(syncs) then -- Empty?
        return
    end

    -- Unset `__local` and `__mgr` so they aren't sent, then restore
    local locals = {}
    for _, sync in pairs(syncs) do
        if sync ~= DESPAWNED then
            sync.__mgr = nil
            locals[sync] = sync.__local
            sync.__local = nil
        end
    end
    local data = rpcToData('receiveSyncs', bitser.dumps(syncs)) -- TODO(nikki): `:getSync()` event
    for _, sync in pairs(syncs) do
        if sync ~= DESPAWNED then
            sync.__mgr = self
            sync.__local = locals[sync]
        end
    end

    if peer then
        peer:send(data)
    else
        self.host:broadcast(data)
    end
end

defRpc('receiveSyncs')
function Client:receiveSyncs(peer, syncs)
    table.insert(self.receivedSyncsDumps, syncs)
end

function Common:applyReceivedSyncs()
    -- New entities may be constructed while sync'ing
    local unsyncedEnts = {} -- New entities that haven't received a sync yet -- verify later
    local function getOrConstruct(id, typeId)
        local ent = self.all[id]
        if not ent then
            ent = self:construct(typeIdToName[typeId])
            ent.__id = id
            self.all[id] = ent
            unsyncedEnts[id] = ent
        end
        return ent
    end
    __DESERIALIZE_ENTITY_REF = getOrConstruct -- bitser calls this to deserialize entity references

    -- Collect latest syncs per-entity
    local latestSyncs = {}
    for _, dump in pairs(self.receivedSyncsDumps) do
        local syncs = bitser.loads(dump)
        for id, sync in pairs(syncs) do
            latestSyncs[id] = sync
        end
    end
    self.receivedSyncsDumps = {}

    -- Actually apply the syncs
    local syncedEnts = {}
    for id, sync in pairs(latestSyncs) do
        if sync == DESPAWNED then
            local ent = self.all[id]
            if ent then
                ent.__despawned = true
                self.all[id] = nil
                self:destruct(ent)
            end
        else
            local ent = getOrConstruct(id, sync.__typeId)
            unsyncedEnts[id] = nil

            local savedLocal = ent.__local
            local defaultSyncBehavior = true
            if ent.willSync then
                defaultSyncBehavior = ent:willSync(sync)
            end
            if defaultSyncBehavior ~= false then
                for k in pairs(ent) do
                    if sync[k] == nil then
                        ent[k] = nil
                    end
                end
                for k, v in pairs(sync) do
                    ent[k] = v
                end
            end
            ent.__local = savedLocal
            ent.__mgr = self
            syncedEnts[ent] = true
        end
    end

    -- Verify references
    for id, ent in pairs(unsyncedEnts) do
        error('received a reference to entity ' .. id .. " of type '" .. ent.__typeName .. "' " ..
                'but did not receive a sync for it -- make sure to `nil` out references to ' ..
                'despawned entities')
    end

    -- Call events
    for ent in pairs(syncedEnts) do
        if ent.didSync then
            ent:didSync()
        end
    end

    __DESERIALIZE_ENTITY_REF = nil
end


-- Controllers and connection / disconnection

defRpc('receiveControllerCall')
function Server:receiveControllerCall(peer, methodName, ...)
    local controller = assert(self.controllers[peer], "no controller for this `peer`")
    local method = assert(controller[methodName], "controller has no method '" .. methodName .. "'")
    method(controller, ...)
end

defRpc('receiveControllerId')
function Client:receiveControllerId(peer, controllerId)
    self:applyReceivedSyncs() -- Make sure we've received the controller
    local controller = self.all[controllerId]
    self.controller = setmetatable({}, {
        __index = function(t, k)
            local v = controller[k]
            if type(v) == 'function' then
                t[k] = function(_, ...)
                    self.serverPeer:send(rpcToData('receiveControllerCall', k, ...))
                end
                return t[k]
            else
                return v
            end
        end
    })
end

function Server:didConnect(peer)
    assert(not self.controllers[peer], "controller for `peer` already exists")
    local controller = self:spawn(self.controllerTypeName)
    self.controllers[peer] = controller
    self:sendSyncs(peer, self.all)
    peer:send(rpcToData('receiveControllerId', controller.__id))
end

function Client:didConnect()
end

function Server:didDisconnect(peer)
    local controller = assert(self.controllers[peer], "no controller for this `peer`")
    self.controllers[peer] = nil
    self:despawn(controller)
end

function Client:didDisconnect()
    self.controller = nil
end


-- Top-level process

function Common:process()
    local errs = {}

    while true do
        local event = self.host:service(0)
        if not event then break end

        local success, err = pcall(function()
            if event.type == 'receive' then
                self:callRpc(event.peer, dataToRpc(event.data))
            elseif event.type == 'connect' then
                self:didConnect(event.peer)
            elseif event.type == 'disconnect' then
                self:didDisconnect(event.peer)
            end
        end)
        table.insert(errs, err)
    end

    self:processSyncs()

    self.host:flush()

    if next(errs) then
        error('`:process()` errors:\n\t' .. table.concat(errs, '\n\t'))
    end
end

function Server:processSyncs()
    self:sendSyncs(nil, self.needsSend)
    self.needsSend = {}
end

function Client:processSyncs()
    self:applyReceivedSyncs()
end


return sync
