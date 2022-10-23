--[[
    This class lets the master looter keep track of
	who was awarded what item. This is especially useful
	for master looters who bring items with them and do
	the rolling along the way.
]]

local _, GL = ...;

---@class AwardedLoot
GL.AwardedLoot = {
    _initialized = false,
};

local AwardedLoot = GL.AwardedLoot; ---@type AwardedLoot
local CommActions = GL.Data.Constants.Comm.Actions;

---@return void
function AwardedLoot:_init()
    GL:debug("AwardedLoot:_init");

    if (self._initialized) then
        return;
    end

    -- Bind the appendAwardedLootToTooltip method to the OnTooltipSetItem event
    GL:onTooltipSetItem(function(Tooltip)
        self:appendAwardedLootToTooltip(Tooltip);
    end);

    -- Bind the opening of the trade window to the tradeInitiated method
    GL.Events:register("AwardedLootTradeShowListener", "GL.TRADE_SHOW", function ()
        self:tradeInitiated();
    end);

    -- Bind a successful trade to the tradeCompleted method
    GL.Events:register("AwardedLootTradeCompletedListener", "GL.TRADE_COMPLETED", function (_, Details)
        self:tradeCompleted(Details);
    end);

    -- Bind a item successfully assigned (masterlooted) to the winner to the tradeCompleted method
    GL.Events:register("AwardedLootTradeCompletedListener", "GL.ITEM_MASTER_LOOTED", function (_, player, itemID)
        -- Mimic the GL.TRADE_COMPLETED payload so we can reuse the tradeCompleted method!
        self:tradeCompleted({
            partner = player,
            MyItems = {
                {
                    itemID = itemID,
                },
            },
        });
    end);

    self._initialized = true;
end

--- Append the players this item was awarded to to the tooltip
---
---@param Tooltip table
function AwardedLoot:appendAwardedLootToTooltip(Tooltip)
    GL:debug("AwardedLoot:appendAwardedLootToTooltip");

    -- No tooltip was provided or the user is not in a party/raid
    if (type(Tooltip) ~= "table") then
        return;
    end

    local _, itemLink = Tooltip:GetItem();

    -- We couldn't find an itemLink (this can actually happen!)
    if (not itemLink) then
        return;
    end

    local itemID = GL:getItemIdFromLink(itemLink);

    -- Loop through our awarded loot table in reverse
    local fiveHoursAgo = GetServerTime() - 18000;
    local loadItemsGTE = math.min(fiveHoursAgo, GL.loadedOn);
    local winnersAvailable = false;
    local Lines = {};
    for index = #GL.DB.AwardHistory, 1, -1 do
        local result = (function ()
            local Loot = GL.DB.AwardHistory[index];

            -- loadItemsGTE will equal five hours, or however long the players
            -- current playsession is ongoing (whichever is longest)
            if (Loot.timestamp < loadItemsGTE) then
                return false;
            end

            -- This is not the item we're looking for
            if (Loot.itemId ~= itemID) then
                return;
            end

            local winner = string.lower(GL:stripRealm(Loot.awardedTo));
            local receivedString = " (received)";
            if (not Loot.received) then
                receivedString = " (not received yet)";
            end

            local line = string.format("|c00%s%s|r%s",
                GL:classHexColor(GL.Player:classByName(winner, 0), "5f5f5f"),
                GL:capitalize(winner),
                receivedString
            );
            tinsert(Lines, line);
            winnersAvailable = true;
        end)();

        if (result == false) then
            break;
        end
    end

    -- Nothing to show
    if (not winnersAvailable) then
        return;
    end

    -- Add the header
    Tooltip:AddLine(string.format("\n|c00efb8cd%s|r", "Awarded To"));

    -- Add the actual award info
    for _, line in pairs(Lines) do
        Tooltip:AddLine("    " .. line);
    end
end

--- Add a winner for a specific item, on a specific date, to the SessionHistory table
---
---@param winner string
---@param date string
---@param itemLink string
---@return void
function AwardedLoot:addWinnerOnDate(winner, date, itemLink)
    GL:debug("AwardedLoot:addWinnerOnDate");

    return AwardedLoot:addWinner(winner, itemLink, nil, date);
end

--- Add a winner for a specific item to the SessionHistory table
---
---@param winner string
---@param itemLink string
---@param announce boolean|nil
---@param date string|nil
---@param isOS boolean|nil
---@param addPlusOne boolean|nil
---@return void
function AwardedLoot:addWinner(winner, itemLink, announce, date, isOS, cost)
    GL:debug("AwardedLoot:addWinner");

    -- Determine whether the item should be flagged as off-spec
    isOS = GL:toboolean(isOS);

    local dateProvided = date and type(date) == "string";
    local timestamp = GetServerTime();

    if (type(winner) ~= "string"
        or GL:empty(winner)
    ) then
        return GL:debug("Invalid winner provided for AwardedLoot:addWinner");
    end

    if (type(itemLink) ~= "string"
        or GL:empty(itemLink)
    ) then
        return GL:debug("Invalid itemLink provided for AwardedLoot:addWinner");
    end

    local itemId = GL:getItemIdFromLink(itemLink);

    if (not itemId) then
        return GL:debug("Invalid itemLink provided for AwardedLoot:addWinner");
    end

    -- You can set the date for when this item was awarded, handy if you forgot an item for example
    if (dateProvided) then
        local year, month, day = string.match(date, "^(%d+)-(%d+)-(%d+)$");

        if (type(year) ~= "string" or GL:empty(year)
            or type(month) ~= "string" or GL:empty(month)
            or type(day) ~= "string" or GL:empty(day)
        ) then
            return GL:error(string.format("Unknown date format '%s' expecting yy-m-d", date));
        end

        if (string.len(year) == 2) then
            year = "20" .. year;
        end

        local Date = {
            year = year,
            month = GL:strPadLeft(month, 0, 2),
            day = GL:strPadLeft(day, 0, 2),
        }

        timestamp = time(Date);
    end

    -- Enable the announce switch by default
    if (type(announce) ~= "boolean") then
        announce = true;
    end

    local AwardEntry = {
        checksum = GL:strPadRight(GL:strLimit(GL:stringHash(timestamp .. itemId) .. GL:stringHash(winner .. GL.DB:get("SoftRes.MetaData.id", "")), 20, ""), "0", 20),
        itemLink = itemLink,
        itemId = itemId,
        awardedTo = winner,
        timestamp = timestamp,
        softresID = GL.DB:get("SoftRes.MetaData.id"),
        received = string.lower(winner) == string.lower(GL.User.name),
        OS = isOS,
    };

    -- Insert the award in the more permanent AwardHistory table (for export / audit purposes)
    tinsert(GL.DB.AwardHistory, AwardEntry);

    -- Check whether the user disabled award announcement in the settings
    if (not GL.Settings:get("AwardingLoot.awardMessagesEnabled")) then
        announce = false;
    end

    local channel = "GROUP";
    if (GL.User.isInRaid
        and GL.Settings:get("AwardingLoot.announceAwardMessagesInRW")
    ) then
        channel = "RAID_WARNING";
    end

    if (announce) then
        local awardMessage = "";
        if (GL.BoostedRolls:enabled() and cost > 0) then
            awardMessage = string.format("%s was awarded to %s for %s points. Congrats!",
                itemLink,
                winner,
                cost
            );
        else
            awardMessage = string.format("%s was awarded to %s. Congrats!",
                itemLink,
                winner
            );

            if (GL.BoostedRolls:enabled()) then
                --- Make sure the cost is stored as the (new) default item cost
                GL.Settings:set("BoostedRolls.defaultCost", cost);
            end
        end

        -- Announce awarded item on RAID or RAID_WARNING
        GL:sendChatMessage(
            awardMessage,
            channel
        );

        -- Announce awarded item on GUILD
        if (GL.Settings:get("AwardingLoot.announceAwardMessagesInGuildChat")
            and GL.User.Guild.name -- Make sure the loot master is actually in a guild
            and GL.User.isInGroup -- Make sure the user is in some kind of group (and not just testing)
        ) then
            local Winner = GL.Player:fromName(winner);

            -- Make sure the winner is actually in our guild before we announce him there
            if (GL:tableGet(Winner, "Guild.name") == GL.User.Guild.name) then
                GL:sendChatMessage(
                    awardMessage,
                    "GUILD"
                );
            end
        end
    end

    -- If the user is not in a group then there's no need
    -- to broadcast or attempt to auto assign loot to the winner
    if (GL.User.isInGroup) then
        -- Broadcast the awarded loot details to everyone in the group
        GL.CommMessage.new(CommActions.awardItem, AwardEntry, channel):send();

        -- The loot window is still active and the auto assign setting is enabled
        if (GL.DroppedLoot.lootWindowIsOpened
            and GL.Settings:get("AwardingLoot.autoAssignAfterAwardingAnItem")
        ) then
            GL.PackMule:assignLootToPlayer(AwardEntry.itemId, winner);

            -- The loot window is closed and the auto trade setting is enabled
            -- Also skip this part if you yourself won the item
        elseif (not GL.DroppedLoot.lootWindowIsOpened
            and GL.Settings:get("AwardingLoot.autoTradeAfterAwardingAnItem")
            and GL.User.name ~= winner
        ) then
            AwardedLoot:initiateTrade(AwardEntry);
        end
    end

    -- Send the award data along to CLM if the player has it installed
    pcall(function ()
        local CLMEventDispatcher = LibStub("EventDispatcher");

        if (not CLMEventDispatcher) then
            return;
        end

        local normalizedPlayerName = string.lower(GL:stripRealm(winner));
        local isPrioritized, isWishlisted = false, false;

        for _, Entry in pairs(GL.TMB:byItemIdAndPlayer(itemId, normalizedPlayerName) or {}) do
            if (Entry.type == GL.Data.Constants.tmbTypePrio) then
                isPrioritized = true;
            elseif (Entry.type == GL.Data.Constants.tmbTypeWish) then
                isWishlisted = true;
            end
        end

        CLMEventDispatcher.dispatchEvent("CLM_EXTERNAL_EVENT_ITEM_AWARDED", {
            source = "Gargul",
            itemLink = itemLink,
            player = winner,
            isOffSpec = isOS,
            isWishlisted = isWishlisted,
            isPrioritized = isPrioritized,
            isReserved = GL.SoftRes:itemIdIsReservedByPlayer(itemId, normalizedPlayerName),
        });
    end);
end

--- Return items won by the given player (with optional `after` timestamp)
---
---@param winner string
---@param after number
---@return table
function AwardedLoot:byWinner(winner, after)
    GL:debug("AwardedLoot:byWinner");

    local Entries = {};
    for _, AwardEntry in pairs(GL.DB.AwardHistory) do
        if ((not after or AwardEntry.timestamp > after)
            and AwardEntry.awardedTo == winner
            and not GL:empty(AwardEntry.timestamp)
            and not GL:empty(AwardEntry.itemLink)
        ) then
            tinsert(Entries, AwardEntry);
        end
    end

    return Entries;
end

--- Attempt to initiate a trade with whomever won the item and add the items
---
---@param AwardDetails table
---@return void
function AwardedLoot:initiateTrade(AwardDetails)
    GL:debug("AwardedLoot:initiateTrade");

    local tradingPartner = AwardDetails.awardedTo;

    -- Check whether we have the item in our inventory, no point opening a trade window if not
    local itemPositionInBag = GL:findBagIdAndSlotForItem(AwardDetails.itemId);
    if (GL:empty(itemPositionInBag)) then
        return;
    end

    -- If the item is marked as disenchanted then we need to open a trade window with the disenchanter
    if (AwardDetails.awardedTo == GL.Exporter.disenchantedItemIdentifier
        and GL.PackMule.disenchanter
    ) then
        tradingPartner = GL.PackMule.disenchanter;
    end

    if (not TradeFrame:IsShown()) then
        -- Open a trade window with the winner
        GL.TradeWindow:open(tradingPartner, function ()
            self:tradeInitiated();
        end);

    -- We're already trading with the winner
    elseif (GL:tableGet(GL.TradeWindow, "State.partner") == tradingPartner) then
        -- Attempt to add the item to the trade window
        GL.TradeWindow:addItem(AwardDetails.itemId);
    end
end

--- When a trade is initiated we attempt to automatically add items that should be given to the tradee
---
---@return void
function AwardedLoot:tradeInitiated()
    -- Fetch the player name of whomever we're trading with
    local tradingPartner = GL:tableGet(GL.TradeWindow, "State.partner");

    -- The trading partner could not be determined (the trade window was closed?)
    if (GL:empty(tradingPartner)) then
        return;
    end

    -- Check whether there are any awarded items that need to be traded to your trading partner
    local threeHoursAgo = GetServerTime() - 10800;

    -- Loop through our awarded loot table in reverse
    for index = #GL.DB.AwardHistory, 1, -1 do
        local Loot = GL.DB.AwardHistory[index];

        -- Our trading partner changed in the meantime, stop!
        if (tradingPartner ~= GL:tableGet(GL.TradeWindow, "State.partner")) then
            break;
        end

        -- No need to check loot that was awarded 3 hours (or longer) ago
        -- Since we're looping through the table in reverse (newest to oldest)
        -- there's no reason to keep looping through the awarded loot table
        if (Loot.timestamp < threeHoursAgo) then
            break;
        end

        (function ()
            local awardedTo = GL:stripRealm(Loot.awardedTo);

            -- Check whether this item is meant for our current trading partner
            if (Loot.received -- The item was already received by the winner, no need to check further
                or (awardedTo ~= tradingPartner -- The awarded item entry is not meant for this person

                    -- The item is marked as disenchanted and our trading partner is the designated enchanter
                    and (awardedTo ~= GL.Exporter.disenchantedItemIdentifier
                        or tradingPartner ~= GL.PackMule.disenchanter
                    )
                )
            ) then
                return;
            end

            -- Attempt to add the item to the trade window
            GL.TradeWindow:addItem(Loot.itemId);
        end)();
    end
end

--- Whenever a successful trade is completed we need to check whether we need to mark awarded loot as "received"
---
---@param Details table
---@return void
function AwardedLoot:tradeCompleted(Details)
    GL:debug("AwardedLoot:tradeCompleted");

    local ItemsTradedByMe = {};
    local tradedDisenchanter = Details.partner == GL.PackMule.disenchanter;

    for _, Entry in pairs(Details.MyItems) do
        local itemID = tonumber(Entry.itemID);

        if (itemID) then
            tinsert(ItemsTradedByMe, itemID);
        end
    end

    -- We didn't give anything to the person we traded with
    if (GL:empty(ItemsTradedByMe)) then
        return;
    end

    local threeHoursAgo = GetServerTime() - 10800;

    -- Loop through our awarded loot table in reverse
    for index = #GL.DB.AwardHistory, 1, -1 do
        local Loot = GL.DB.AwardHistory[index];

        -- No need to check loot that was awarded 3 hours (or longer) ago
        -- Since we're looping through the table in reverse (newest to oldest)
        -- there's no reason to keep looping through the awarded loot table
        if (Loot.timestamp < threeHoursAgo) then
            break;
        end

        (function ()
            -- The item was already marked as received, skip it
            if (Loot.received) then
                return;
            end

            -- The item is not meant for the person we traded with, skip it
            if (string.lower(GL:stripRealm(Details.partner)) ~= string.lower(GL:stripRealm(Loot.awardedTo))
                and (not tradedDisenchanter
                    or Loot.awardedTo ~= GL.Exporter.disenchantedItemIdentifier
                )
            ) then
                return;
            end

            -- We didn't trade this item
            if (not GL:inTable(ItemsTradedByMe, Loot.itemId)) then
                return;
            end

            -- We gave this item to the user, mark it as received!
            GL.DB.AwardHistory[index].received = true;

            -- Remove (one of) the item ID entries. This is necessary because
            -- a person might get the same item more than once
            for key, itemID in pairs(ItemsTradedByMe) do
                if (itemID == Loot.itemId) then
                    ItemsTradedByMe[key] = nil;
                    break;
                end
            end
        end)();
    end
end

--- The loot master awarded an item to someone, add it to our list as well
---
---@param CommMessage table
---@return void
function AwardedLoot:processAwardedLoot(CommMessage)
    GL:debug("AwardedLoot:processAwardedLoot");

    -- No need to add awarded loot if we broadcasted it ourselves
    if (CommMessage.Sender.name == GL.User.name) then
        GL:debug("AwardedLoot:processAwardedLoot received by self, skip");
        return;
    end

    local AwardEntry = CommMessage.content;

    -- Make sure all values are available
    if (GL:empty(AwardEntry.checksum)
        or GL:empty(AwardEntry.itemLink)
        or GL:empty(AwardEntry.itemId)
        or GL:empty(AwardEntry.awardedTo)
        or GL:empty(AwardEntry.timestamp)
    ) then
        return GL:warning("Couldn't process award result in AwardedLoot:processAwardedLoot");
    end

    -- There's no point to us giving the winner the item since we don't have it
    AwardEntry.received = true;

    -- Insert the award in the more permanent AwardHistory table (for export / audit purposes)
    -- We don't pass the actual AwardEntry object as-is here just in case there are some additional keys that we don't need
    tinsert(GL.DB.AwardHistory, {
        checksum = AwardEntry.checksum,
        itemLink = AwardEntry.itemLink,
        itemId = AwardEntry.itemId,
        awardedTo = AwardEntry.awardedTo,
        timestamp = AwardEntry.timestamp,
        softresID = AwardEntry.softresID,
        received = AwardEntry.received,
        OS = AwardEntry.OS,
    });
end



GL:debug("AwardedLoot.lua");