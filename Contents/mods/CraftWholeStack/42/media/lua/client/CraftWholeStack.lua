-- Craft Whole Stack
-- Adds "<Recipe> (All N)" next to every B42 recipe option in the inventory right-click menu.
-- Runs through ISEntityUI.HandcraftStartMultiple, the same path the crafting window's quantity
-- box uses, so every craft is still validated by the server in multiplayer.

require "ISUI/ISInventoryPaneContextMenu"
require "Entity/ISEntityUI"

CraftWholeStack = CraftWholeStack or {}

-- Items the player right-clicked, captured for the duration of one createMenu call.
local selectedItems = {}

local function countSelectedOfType(fullType)
    local n = 0
    for _, item in ipairs(selectedItems) do
        if item:getFullType() == fullType then n = n + 1 end
    end
    return n
end

local function newLogic(playerObj, recipe, selectedItem)
    local logic = HandcraftLogic.new(playerObj, nil, nil)
    logic:setIsoObject(logic:findCraftSurface(playerObj, 2))
    logic:setContainers(ISInventoryPaneContextMenu.getContainers(playerObj))
    logic:setRecipeFromContextClick(recipe, selectedItem)
    return logic
end

-- How many times this recipe can run for this right-click. A multi-item selection caps it
-- at the selection size, and a single right-click runs it for everything you're carrying.
function CraftWholeStack.getCount(playerObj, recipe, selectedItem)
    if not recipe:isAllowBatchCraft() then return 0 end
    local logic = newLogic(playerObj, recipe, selectedItem)
    if not logic:canPerformCurrentRecipe() then return 0 end
    local possible = logic:getPossibleCraftCount(true)
    local selected = countSelectedOfType(selectedItem:getFullType())
    if selected > 1 then possible = math.min(possible, selected) end
    return possible
end

-- Recipes that can't run from the floor need their inputs on the player. Queue transfers for
-- the selected stack up front, but only as many as fit so the queue doesn't fail halfway.
local function pullStackToInventory(playerObj, recipe, stack, qty, alreadyQueued)
    if recipe:isCanBeDoneFromFloor() then return {} end
    local inv = playerObj:getInventory()
    local free = inv:getEffectiveCapacity(playerObj) - inv:getCapacityWeight()
    local moved = {}
    for _, item in ipairs(stack) do
        if #moved >= qty then break end
        if item:getContainer() ~= inv and not alreadyQueued[item] then
            local w = item:getUnequippedWeight()
            if w > free then break end
            free = free - w
            ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
            table.insert(moved, item)
        end
    end
    return moved
end

function CraftWholeStack.OnCraftAll(selectedItem, recipe, player, qty, stack)
    local playerObj = getSpecificPlayer(player)
    local logic = newLogic(playerObj, recipe, selectedItem)
    if not logic:canPerformCurrentRecipe() then return end

    qty = math.min(qty, logic:getPossibleCraftCount(true))
    if qty < 1 then return end

    -- Tools and first-craft inputs, same as vanilla OnNewCraft.
    local returnToContainer = {}
    local queued = {}
    local items = logic:getRecipeData():getAllInputItems()
    local keep = logic:getRecipeData():getAllPutBackInputItems()
    if not recipe:isCanBeDoneFromFloor() then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item:getContainer() ~= playerObj:getInventory() then
                ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
                queued[item] = true
                if keep:contains(item) then table.insert(returnToContainer, item) end
            end
        end
    end
    local moved = pullStackToInventory(playerObj, recipe, stack or {}, qty, queued)
    if not recipe:isCanBeDoneFromFloor() then
        -- Only queue crafts whose inputs will actually be on the player.
        local fullType = selectedItem:getFullType()
        local onPlayer = playerObj:getInventory():getCountTypeRecurse(fullType) + #moved
        for item in pairs(queued) do
            if item:getFullType() == fullType then onPlayer = onPlayer + 1 end
        end
        qty = math.min(qty, onPlayer)
        if qty < 1 then return end
    end

    logic:updateManualInputAllowedItemTypes()
    local actions = ISEntityUI.HandcraftStartMultiple(playerObj, logic, false, qty, false)
    if not actions then return end
    for _, action in ipairs(actions) do
        action:setOnStart(function(l, a) l:startCraftAction(a) end, logic)
        action:setOnComplete(function(l) l:stopCraftAction() end, logic)
        action:setOnCancel(function(l) l:stopCraftAction() end, logic)
        ISTimedActionQueue.add(action)
    end

    -- Tools go back where they came from after the last craft.
    ISCraftingUI.ReturnItemsToOriginalContainer(playerObj, returnToContainer)
end

local function findRecipeMenu(context, recipeList)
    -- Vanilla nests the recipes under the item name when there's more than one.
    if recipeList:size() > 1 then
        local last = context.options[context.numOptions - 1]
        if last and last.subOption then return context:getSubMenu(last.subOption) end
    end
    return context
end

local function insertAfter(menu, afterOption, name, target, onSelect, p1, p2, p3, p4)
    local option = menu:addOption(name, target, onSelect, p1, p2, p3, p4)
    if not option then return nil end
    local idx
    for i, v in ipairs(menu.options) do
        if v == afterOption then idx = i break end
    end
    if idx and idx < #menu.options - 1 then
        table.remove(menu.options, #menu.options)
        table.insert(menu.options, idx + 1, option)
        for i, v in ipairs(menu.options) do v.id = i end
    end
    return option
end

local origAddCraftMenu = ISInventoryPaneContextMenu.addNewCraftingDynamicalContextMenu
ISInventoryPaneContextMenu.addNewCraftingDynamicalContextMenu = function(selectedItem, context, recipeList, player, containerList)
    origAddCraftMenu(selectedItem, context, recipeList, player, containerList)

    local playerObj = getSpecificPlayer(player)
    if not playerObj or playerObj:isDriving() then return end
    local menu = findRecipeMenu(context, recipeList)
    if not menu then return end

    -- The click happens after createMenu returns, so hand the stack to the option itself.
    local stack = {}
    for _, item in ipairs(selectedItems) do
        if item:getFullType() == selectedItem:getFullType() then table.insert(stack, item) end
    end

    -- Snapshot first, since inserting shifts the table.
    local craftOptions = {}
    for _, option in ipairs(menu.options) do
        if option.onSelect == ISInventoryPaneContextMenu.OnNewCraft and not option.notAvailable then
            table.insert(craftOptions, option)
        end
    end

    for _, option in ipairs(craftOptions) do
        local recipe = option.param1
        local count = CraftWholeStack.getCount(playerObj, recipe, selectedItem)
        if count > 1 then
            local name = getText("ContextMenu_CraftWholeStack_All", option.name, count)
            local allOption = insertAfter(menu, option, name, selectedItem, CraftWholeStack.OnCraftAll, recipe, player, count, stack)
            if not allOption then break end
            allOption.iconTexture = option.iconTexture
            allOption.color = option.color
            allOption.toolTip = option.toolTip
        end
    end
end

local origCreateMenu = ISInventoryPaneContextMenu.createMenu
ISInventoryPaneContextMenu.createMenu = function(player, isInPlayerInventory, items, x, y, origin)
    selectedItems = ISInventoryPane.getActualItems(items)
    local result = origCreateMenu(player, isInPlayerInventory, items, x, y, origin)
    selectedItems = {}
    return result
end
