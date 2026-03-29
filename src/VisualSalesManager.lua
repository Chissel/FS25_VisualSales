VisualSalesManager = {
    MOD_DIRECTORY = g_currentModDirectory,
    DEFAULT_SPOTS = {
        ["$data/maps/mapUS/mapUS.xml"] = "xml/riverbendSpringsVisualSales.xml",
        ["$data/maps/mapAS/mapAS.xml"] = "xml/hutanPantaiVisualSales.xml",
        ["$data/maps/mapEU/mapEU.xml"] = "xml/zielonkaVisualSales.xml",
        ["pdlc_highlandsFishingPack.HighlandsFishingMap"] = "xml/kinlaigVisualSales.xml",
    },
    SPOT_TYPE_AREA = "area"
}

local VisualSalesManager_mt = Class(VisualSalesManager, AbstractManager)

function VisualSalesManager.new(customMt)
	local self = VisualSalesManager:superClass().new(customMt or VisualSalesManager_mt)

    self.spots = {}

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)

    return self
end

function VisualSalesManager:deleteMap()
    if g_currentMission:getIsServer() then
        g_messageCenter:unsubscribeAll(self)
    end
end

function VisualSalesManager:onDayChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local vehicleSaleSystem = g_currentMission.vehicleSaleSystem

    for _, spot in self.spots do
        if not spot.free then
            for saleId, _ in spot.saleIds do
                local item = vehicleSaleSystem:getSaleById(saleId)
                self:removeSale(item, spot.saleId, _)
            end
        end
    end

    local items = vehicleSaleSystem:getItems()
    local usedValues = {}
    local randomIndex

    g_asyncTaskManager:addTask(function()
        for i=1, #items do
            while randomIndex == nil or usedValues[randomIndex] ~= nil do
                randomIndex = math.random(1, #items)
            end
            usedValues[randomIndex] = true
            self:addSale(items[randomIndex])
        end
	end)
end

function VisualSalesManager:getFreeSpot()
    for _, spot in self.spots do
        if spot.free then
            return spot
        end
    end

    return nil
end

function VisualSalesManager:getSpotForSaleId(id)
    if id == nil then
        return nil
    end

    for _, spot in self.spots do
        if spot.saleIds[id] then
            return spot
        end
    end

    return nil
end

function VisualSalesManager:isSpotValidForItem(spot, storeItem)
    local valid = true

    if spot.type == VisualSalesManager.SPOT_TYPE_AREA then
        return true
    end

    if spot.brands ~= nil then
        local validBrand = false
        for _, brand in spot.brands do
            if storeItem.brandNameRaw == brand then
                validBrand = true
                break
            end
        end
        valid = valid and validBrand
    end

    if spot.categories ~= nil then
        local validCategory = false
        for _, category in spot.categories do
            if storeItem.categoryName == category then
                validCategory = true
                break
            end
        end
        valid = valid and validCategory
    end

    local size = StoreItemUtil.getSizeValues(storeItem.xmlFilename, "vehicle", storeItem.rotation)

    if spot.maxWidth ~= nil and size.width > spot.maxWidth then
        valid = false
    end

    if spot.maxLength ~= nil and size.length > spot.maxLength then
        valid = false
    end

    return valid
end

function VisualSalesManager:addSale(item, _)
    Logging.devInfo("Add sale: "..item.id)
    if not g_currentMission:getIsServer() then
        return
    end

    local data = VehicleLoadingData.new()
    data:setFilename(item.xmlFilename)

    if data.isValid then
        if self:getSpotForSaleId(item.id) ~= nil then
            Logging.devInfo("Add sale: Sale already visible")
            return
        end

        local spot
        for _, currentSpot in pairs(self.spots) do
            if currentSpot.free and self:isSpotValidForItem(currentSpot, data.storeItem) and not self:isBlocked(currentSpot) then
                if currentSpot.type == VisualSalesManager.SPOT_TYPE_AREA then
                    if data:setLoadingPlace(currentSpot.places, currentSpot.usedPlaces) then
                        spot = currentSpot
                        break
                    end
                else
                    spot = currentSpot
                    break
                end
            end
        end

        if spot == nil then
            Logging.devInfo("Add sale: No spot available")
            return
        end

        if spot.type ~= VisualSalesManager.SPOT_TYPE_AREA then
            spot.free = false
        end

        spot.saleIds[item.id] = true
        local vehicleParams = {
            damage = item.damage,
            wear = item.wear
        }
        if item.boughtConfigurations ~= nil then
            data:setBoughtConfigurations(item.boughtConfigurations)
        end

        if spot.type ~= VisualSalesManager.SPOT_TYPE_AREA then
            data.validLocation = true
            data:setRotation(spot.rotation.x, spot.rotation.y, spot.rotation.z)
            data:setPosition(spot.position.x, spot.position.y, spot.position.z)
        end

        data:setOwnerFarmId(FarmManager.INVALID_FARM_ID)

        data:load(
            self.onVehiclesLoaded,
            self,
            {
                ["spot"] = spot,
                ["saleId"] = item.id,
                ["vehicleParams"] = vehicleParams
            }
        )
    end
end

VehicleSaleSystem.addSale = Utils.overwrittenFunction(VehicleSaleSystem.addSale, function(saleSystem, superFunc, item, noEventSend)
    superFunc(saleSystem, item, noEventSend)
    g_visualSalesManager:addSale(item, noEventSend)
end)

function VisualSalesManager:removeSale(item, index, noEventSend)
    if not g_currentMission:getIsServer() or item == nil then
        return
    end

    local spot = self:getSpotForSaleId(item.id)

    --if spot == nil then
    --    spot = self:getSpotForSaleId(index)
    --end

    if spot == nil then
        Logging.devInfo("Remove Sale: Vehicle not found")
        return
    end

    local vehicleSystem = g_currentMission.vehicleSystem

    local vehicleIds = spot.vehicleIds[item.id]
    for _, vehicleId in ipairs(vehicleIds) do
        Logging.devInfo("Remove sale with id: "..vehicleId)
        local vehicle = vehicleSystem:getVehicleByUniqueId(vehicleId)

        if vehicle == nil then
            Logging.error("Vehicle with unique id not fround: "..vehicleId)
        else
            vehicle:delete(true)
        end
    end

    spot.free = true
    spot.vehicleIds[item.id] = nil
    spot.saleIds[item.id] = nil

    g_asyncTaskManager:addTask(function()
        self:addSaleIfAvailable()
	end)
end

VehicleSaleSystem.removeSale = Utils.overwrittenFunction(VehicleSaleSystem.removeSale, function(saleSystem, superFunc, item, index, noEventSend)
    superFunc(saleSystem, item, index, noEventSend)
    g_visualSalesManager:removeSale(item, index, noEventSend)
end)

VehicleSaleSystem.removeSaleWithId = Utils.overwrittenFunction(VehicleSaleSystem.removeSaleWithId, function(saleSystem, superFunc, saleItemId)
    superFunc(saleSystem, saleItemId)
    g_visualSalesManager:removeSale(nil, saleItemId, nil)
end)

function VisualSalesManager:addSaleIfAvailable()
    local vehicleSaleSystem = g_currentMission.vehicleSaleSystem
    local items = vehicleSaleSystem:getItems()

    for _, item in items do
        local spot = self:getSpotForSaleId(item.id)

        if spot == nil then
            self:addSale(item)
        end
    end
end

function VisualSalesManager:onVehiclesLoaded(loadedVehicles, vehicleLoadState, asyncArguments)
    local spot = asyncArguments.spot
    local vehicleParams = asyncArguments.vehicleParams
    local vehicleSaleSystem = g_currentMission.vehicleSaleSystem

    if vehicleLoadState == VehicleLoadingState.OK and vehicleSaleSystem:getSaleById(asyncArguments.saleId) ~= nil then
        local vehicles = {}
        for _, vehicle in ipairs(loadedVehicles) do
            table.insert(vehicles, vehicle:getUniqueId())
            self:addVehicleParams(vehicle, vehicleParams)
        end

        spot.vehicleIds[asyncArguments.saleId] = vehicles
    else
        Logging.info("foo b "..vehicleLoadState)
        for _, vehicle in ipairs(loadedVehicles) do
            vehicle:delete()
        end
        spot.free = true
        spot.saleIds[asyncArguments.saleId] = nil
    end
end

function VisualSalesManager:addVehicleParams(vehicle, params)
    vehicle:addDamageAmount(params.damage or 0, true)
	vehicle:addWearAmount(params.wear or 0, true)
end


function VisualSalesManager:loadMap(filename)
    g_currentMission:registerToLoadOnMapFinished(g_visualSalesManager)
end

function VisualSalesManager:onLoadMapFinished()
    local xmlFile = g_currentMission.xmlFile
	local visualSalesXmlFile = getXMLString(xmlFile, "map.visualSales#filename")
	if visualSalesXmlFile ~= nil then
		local visualSalesFile = Utils.getFilename(visualSalesXmlFile, g_currentMission.baseDirectory)
		local visualSales = XMLFile.load("visualSales", visualSalesFile)

        if visualSales == nil then
			return
		end

        self:loadSpots(visualSales)
    else
        self:loadDefaultSpotsIfAvailable()
    end
end

function VisualSalesManager:loadDefaultSpotsIfAvailable()
    local map = g_currentMission.missionInfo.map
    local defaultPath = VisualSalesManager.DEFAULT_SPOTS[map.mapXMLFilename] or VisualSalesManager.DEFAULT_SPOTS[map.id]

    if defaultPath == nil then
        return
    end

    local filename = VisualSalesManager.MOD_DIRECTORY..""..defaultPath
    local key = "visualSales"
    local xmlFile = XMLFile.loadIfExists("visualSales", filename, key)

    if xmlFile ~= nil then
        self:loadSpots(xmlFile)
    end
end

function VisualSalesManager:loadSpots(visualSales)
    for index, key in visualSales:iterator("visualSales.spot") do
		local spotType = visualSales:getString(key .. "#type")

        if spotType == VisualSalesManager.SPOT_TYPE_AREA then
            --local nodeIndex = visualSales:getString(key .. "#nodeIndex")
            --local node = I3DUtil.indexToObject(getRootNode(), nodeIndex)

            local yOffset = visualSales:getFloat(key .. "#yOffset")

            local startNode = createTransformGroup("startNode")
            local startNodeValue = visualSales:getString(key .. "#startNodePosition")
            local startPositionValues = string.split(startNodeValue, " ")
            local startNodePosition = self:createPosition(startPositionValues, yOffset)
			setWorldTranslation(startNode, startNodePosition.x, startNodePosition.y, startNodePosition.z)

            local startNodeRotationValue = visualSales:getString(key .. "#startNodeRotation")
            local startNodeRotationValues = string.split(startNodeRotationValue, " ")
            local startNodeRotation = self:createRotation(startNodeRotationValues)
            setWorldRotation(startNode, startNodeRotation.x, startNodeRotation.y, startNodeRotation.z)

            local endNode = createTransformGroup("endNode")
            local endNodeValue = visualSales:getString(key .. "#endNodePosition")
            local endPositionValues = string.split(endNodeValue, " ")
            local endNodePosition = self:createPosition(endPositionValues, yOffset)
			setWorldTranslation(endNode, endNodePosition.x, endNodePosition.y, endNodePosition.z)

            local endNodeRotationValue = visualSales:getString(key .. "#endNodeRotation")
            local endNodeRotationValues = string.split(endNodeRotationValue, " ")
            local endNodeRotation = self:createRotation(endNodeRotationValues)
            setWorldRotation(endNode, endNodeRotation.x, endNodeRotation.y, endNodeRotation.z)

            link(getRootNode(), startNode)
            link(getRootNode(), endNode)
            local place = PlacementUtil.loadPlaceFromNode(startNode, endNode, false)
            local places = {}
            table.insert(places, place)

            local spot = {
                type = VisualSalesManager.SPOT_TYPE_AREA,
                index = index,
                places = places,
                usedPlaces = {},
                free = true,
                vehicleIds = {},
                saleIds = {}
            }
            self.spots[index] = spot
        else
            local position = visualSales:getString(key .. "#position")
            local positionValues = string.split(position, " ")

            local rotation = visualSales:getString(key .. "#rotation")
            local rotationValues = string.split(rotation, " ")

            local spot = {
                index = index,
                position = self:createPosition(positionValues),
                rotation = self:createRotation(rotationValues),
                maxWidth = visualSales:getFloat(key .. "#maxWidth"),
                maxLength = visualSales:getFloat(key .. "#maxLength"),
                free = true,
                vehicleIds = {},
                saleIds = {}
            }

            local brandValues = visualSales:getString(key .. "#brands")
            if brandValues ~= nil then
                spot.brands = string.split(brandValues, " ")
            end

            local categoryValues = visualSales:getString(key .. "#categories")
            if categoryValues ~= nil then
                spot.categories = string.split(categoryValues, " ")
            end

            self.spots[index] = spot
        end
    end
end

function VisualSalesManager:isBlocked(spot)
    if spot.type == VisualSalesManager.SPOT_TYPE_AREA then
        return false
    end

    PlacementUtil.tempHasCollision = false
    overlapBox(
        spot.position.x,
        spot.position.y or getTerrainHeightAtWorldPos(g_terrainNode, spot.position.x, 0, spot.position.z),
        spot.position.z,
        spot.rotation.x,
        spot.rotation.y,
        spot.rotation.z,
        spot.maxWidth * 0.5,
        5 * 0.5,
        spot.maxLength * 0.5,
        "PlacementUtil.collisionTestCallback",
        nil,
        CollisionFlag.VEHICLE + CollisionFlag.PLAYER + CollisionFlag.DYNAMIC_OBJECT,
        true,
        true,
        false,
        true
    )
    return PlacementUtil.tempHasCollision
end

function VisualSalesManager:createPosition(values, yOffset)
    if #values == 3 then
        return {
            x = tonumber(values[1]),
            y = tonumber(values[2]),
            z = tonumber(values[3])
        }
    elseif #values == 2 then
        local position = {
            x = tonumber(values[1]),
            z = tonumber(values[2])
        }

        position.y = getTerrainHeightAtWorldPos(g_terrainNode, position.x, 0, position.z) + (yOffset or 0)

        return position
    else
        Logging.error("Position values not correct")
        return nil
    end
end

function VisualSalesManager:createRotation(values)
    return {
        x = tonumber(values[1]) * (math.pi / 180),
        y = tonumber(values[2]) * (math.pi / 180),
        z = tonumber(values[3]) * (math.pi / 180)
    }
end


function VisualSalesManager:saveToXMLFile()
    local savegameDirectory = g_currentMission.missionInfo.savegameDirectory

    if savegameDirectory ~= nil then
        local saveGamePath = savegameDirectory.."/visualSales.xml"
        local key = "visualSales"
        local xmlFile = XMLFile.create("visualSales", saveGamePath, key)

        if xmlFile ~= nil then
            for spotIndex, spot in pairs(self.spots) do
                local spotKey = string.format(key..".spot(%d)", spotIndex - 1)
                xmlFile:setBool(spotKey.."#free", spot.free)
                xmlFile:setInt(spotKey.."#index", spot.index)
                if spot.saleIds ~= nil then
                    local saleIdsIndex = 0
                    local saleIdsKey = string.format(spotKey..".saleIds(%d)", saleIdsIndex)
                    local saleIdIndex = 0
                    for saleId, _ in pairs(spot.saleIds) do
                        local saleIdKey = string.format(saleIdsKey..".saleId(%d)", saleIdIndex)
                        xmlFile:setInt(saleIdKey.."#saleId", saleId)
                        saleIdIndex = saleIdIndex + 1
                    end
                    saleIdIndex = saleIdIndex + 1
                end

                for saleId, vehicleIds in pairs(spot.vehicleIds) do
                    local vehicleIdsIndex = 0
                    local vehicleIdsKey = string.format(spotKey..".vehicleIds(%d)", vehicleIdsIndex)
                    xmlFile:setInt(vehicleIdsKey.."#saleId", saleId)
                    for vehicleIdIndex, vehicleId in vehicleIds do
                        local vehicleKey = string.format(vehicleIdsKey..".vehicleId(%d)", vehicleIdIndex - 1)
                        xmlFile:setString(vehicleKey.."#uniqueId", vehicleId)
                    end
                    vehicleIdsIndex = vehicleIdsIndex + 1
                end
            end

            xmlFile:save()
            xmlFile:delete()
        end
    end
end

VehicleSaleSystem.saveToXMLFile = Utils.overwrittenFunction(VehicleSaleSystem.saveToXMLFile, function(self, superFunc, xmlFilename)
    local returnValue = superFunc(self, xmlFilename)
    g_visualSalesManager:saveToXMLFile()
    return returnValue
end)

function VisualSalesManager:loadFromXMLFile()
    local savegameDirectory = g_currentMission.missionInfo.savegameDirectory

    if savegameDirectory ~= nil then
        local filename = savegameDirectory.."/visualSales.xml"
        local key = "visualSales"
        local xmlFile = XMLFile.loadIfExists("visualSales", filename, key)

        if xmlFile ~= nil then
            xmlFile:iterate(key..".spot", function(_, spotKey)
                local index = xmlFile:getInt(spotKey.."#index")
                local spot = self.spots[index]

                local saleIds = {}
                xmlFile:iterate(key..".saleIds", function(_, saleIdsKey)
                    local saleId = xmlFile:getInt(saleIdsKey.."#saleId")
                    saleIds[saleId] = true
                end)
                spot.saleIds = saleIds

                spot.free = xmlFile:getBool(spotKey.."#free")

                xmlFile:iterate(spotKey..".vehicleIds", function(_, vehicleIdsKey)
                    local saleId = xmlFile:getInt(vehicleIdsKey.."#saleId")
                    local vehicleIds = {}
                    xmlFile:iterate(vehicleIdsKey..".vehicleId", function(_, vehicleIdkey)
                        local vehicleId = xmlFile:getString(vehicleIdkey.."#uniqueId")
                        table.insert(vehicleIds, vehicleId)
                    end)
                    spot.vehicleIds[saleId] = vehicleIds
                end)
            end)

            xmlFile:delete()
        end
    end
end

VehicleSaleSystem.loadFromXMLFile = Utils.overwrittenFunction(VehicleSaleSystem.loadFromXMLFile, function(self, superFunc, xmlFilename)
    local returnValue = superFunc(self, xmlFilename)
    g_visualSalesManager:loadFromXMLFile()
    return returnValue
end)

g_visualSalesManager = VisualSalesManager.new()
addModEventListener(g_visualSalesManager)