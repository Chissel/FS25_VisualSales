VisualSalesManager = {
    MOD_DIRECTORY = g_currentModDirectory,
    DEFAULT_SPOTS = {
        ["$data/maps/mapUS/mapUS.xml"] = "xml/riverbendSpringsVisualSales.xml",
        ["$data/maps/mapAS/mapAS.xml"] = "xml/hutanPantaiVisualSales.xml",
        ["$data/maps/mapEU/mapEU.xml"] = "xml/zielonkaVisualSales.xml",
        ["pdlc_highlandsFishingPack.HighlandsFishingMap"] = "xml/kinlaigVisualSales.xml",
    }
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

    for index, spot in self.spots do
        if not spot.free then
            self:removeSale(_, spot.saleId, _)
        end
    end

    local vehicleSaleSystem = g_currentMission.vehicleSaleSystem
    local items = vehicleSaleSystem:getItems()
    local usedValues = {}
    local randomIndex

    for i=1, #items do
        while randomIndex == nil or usedValues[randomIndex] ~= nil do
            randomIndex = math.random(1, #items)
        end
        usedValues[randomIndex] = true
        self:addSale(items[randomIndex])
    end
end

function VisualSalesManager:getFreeSpot()
    for index, spot in self.spots do
        if spot.free then
            return spot
        end
    end

    return nil
end

function VisualSalesManager:getSpotForSaleId(id)
    for index, spot in self.spots do
        if spot.saleId == id then
            return spot
        end
    end

    return nil
end

function VisualSalesManager:isSpotValidForItem(spot, storeItem)
    local valid = true

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
    if not g_currentMission:getIsServer() then
        return
    end

    local data = VehicleLoadingData.new()
    data:setFilename(item.xmlFilename)

    if data.isValid then
        local spot
        for _, currentSpot in pairs(self.spots) do
            if currentSpot.free and self:isSpotValidForItem(currentSpot, data.storeItem) then
                spot = currentSpot
                break
            end
        end

        if spot == nil then
            return
        end

        spot.free = false
        spot.saleId = item.id
        if item.boughtConfigurations ~= nil then
            data:setBoughtConfigurations(item.boughtConfigurations)
        end

        data:setRotation(spot.rotation.x, spot.rotation.y, spot.rotation.z)
        data:setPosition(spot.position.x, spot.position.y, spot.position.z)
        data:setOwnerFarmId(FarmManager.INVALID_FARM_ID)
        data:load(function(_, loadedVehicles, vehicleLoadState, _)
            if spot.isRemoved == false and vehicleLoadState == VehicleLoadingState.OK then
                spot.vehicleIds = {}
                for _, vehicle in ipairs(loadedVehicles) do
                    table.insert(spot.vehicleIds, vehicle:getUniqueId())
                end

                Logging.info("Load vehicle successfully")
            else
                for _, vehicle in ipairs(loadedVehicles) do
                    vehicle:delete()
                end
                spot.free = true
                spot.vehicleIds = {}
                spot.saleId = nil
            end

            spot.isRemoved = false
        end, nil, nil)
    end
end

VehicleSaleSystem.addSale = Utils.overwrittenFunction(VehicleSaleSystem.addSale, function(saleSystem, superFunc, item, noEventSend)
    superFunc(saleSystem, item, noEventSend)
    g_visualSalesManager:addSale(item, noEventSend)
end)

function VisualSalesManager:removeSale(item, index, noEventSend)
    if not g_currentMission:getIsServer() then
        return
    end
    
    local spot = self:getSpotForSaleId(index)

    if spot == nil then
        spot = self:getSpotForSaleId(item.id)
    end

    if spot == nil then
        return
    end

    if #spot.vehicleIds == 0 then
        spot.isRemoved = true
    end

    local vehicleSystem = g_currentMission.vehicleSystem

    for _, vehicleId in ipairs(spot.vehicleIds) do
        local vehicle = vehicleSystem:getVehicleByUniqueId(vehicleId)

        if vehicle == nil then
            Logging.error("Vehicle with unique id not fround: "..vehicleId)
        else
            vehicle:delete()
        end
    end

    spot.free = true
    spot.vehicleIds = {}
    spot.saleId = nil
end

VehicleSaleSystem.removeSale = Utils.overwrittenFunction(VehicleSaleSystem.removeSale, function(saleSystem, superFunc, item, index, noEventSend)
    superFunc(saleSystem, item, index, noEventSend)
    g_visualSalesManager:removeSale(item, index, noEventSend)
end)

function VisualSalesManager:loadMap(filename)
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
		local position = visualSales:getString(key .. "#position")
        local positionValues = string.split(position, " ")

		local rotation = visualSales:getString(key .. "#rotation")
        local rotationValues = string.split(rotation, " ")

        local spot = {
            index = index,
            position = self:createPosition(positionValues),
            rotation = {
                x = tonumber(rotationValues[1]) * (math.pi / 180),
                y = tonumber(rotationValues[2]) * (math.pi / 180),
                z = tonumber(rotationValues[3]) * (math.pi / 180)
            },
            maxWidth = visualSales:getFloat(key .. "#maxWidth"),
            maxLength = visualSales:getFloat(key .. "#maxLength"),
            free = true,
            vehicleIds = {},
            isRemoved = false
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

function VisualSalesManager:createPosition(values)
    if #values == 3 then
        return {
            x = tonumber(values[1]),
            y = tonumber(values[2]),
            z = tonumber(values[3])
        }
    elseif #values == 2 then
        return {
            x = tonumber(values[1]),
            z = tonumber(values[2])
        }
    else
        Logging.error("Position values not correct")
        return nil
    end
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
                if spot.saleId ~= nil then
                    xmlFile:setInt(spotKey.."#saleId", spot.saleId)
                end

                for vehicleIndex, vehicleId in pairs(spot.vehicleIds) do
                    local vehicleKey = string.format(spotKey..".vehicleIds(%d)", vehicleIndex - 1)
                    xmlFile:setString(vehicleKey.."#uniqueId", vehicleId)
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

                spot.saleId = xmlFile:getInt(spotKey.."#saleId")
                spot.free = xmlFile:getBool(spotKey.."#free")

                xmlFile:iterate(spotKey..".vehicleIds", function(_, vehicleKey)
                    local vehicleId = xmlFile:getString(vehicleKey.."#uniqueId")
                    table.insert(spot.vehicleIds, vehicleId)
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