--[[
    CraftGuard - Ashita v4 addon for CatsEyeXI (Final Fantasy XI private server)

    Trigger with /craftguard or /cg - both equivalent.

    Displays your current crafting skill levels on screen, including:
      - Your raw (in-game) skill per craft
      - The bonus from "Mega Moglification" guild-rank key items - tracked via the 0x055 (key
        items) packet rather than HasKeyItem(), which was found to be unreliable (a recent retail
        client update broke Ashita's HasKeyItem pattern - since fixed upstream, make sure Ashita
        is up to date). The 0x055 packet only arrives on login/zone or when a key item actually
        changes, so ZONE ONCE after loading this addon for the KI column to populate.
      - The bonus from any equipped crafting rings/gear (see data.lua)
      - Your resulting effective skill and whether it's capped
      - Whether High-Quality synthesis is currently disabled because you're
        wearing an item that blocks it (see data.lua: HQ_BLOCKING_ITEMS)

    Also BLOCKS synthesis attempts that use an ingredient on your personal blocklist while HQ is
    currently disabled - see the /cg blocklist commands below. This uses the outgoing
    "Synth" packet (id 0x096), confirmed against CatsEyeXI via a real packet capture.
    /cg blocklist off disables blocking entirely without losing your list, if it ever
    misbehaves.

    All server-specific item names, key item ids, and bonus values live in
    data.lua next to this file - edit that file, not this one, to keep the
    addon accurate as you confirm more details.

    Commands:
      /cg                          - Toggle the window.
      /cg show                     - Show the window.
      /cg hide                     - Hide the window.
      /cg reload                   - Reload data.lua (after you edit it) and settings.
      /cg blocklist add <item>     - Adds an ingredient to your blocklist.
      /cg blocklist remove <item>  - Removes an ingredient from your blocklist.
      /cg blocklist list           - Lists your current blocklist.
      /cg blocklist on / off       - Enables/disables blocklist blocking without clearing the list.
      /cg help                     - Print this command list.
--]]

addon.name      = 'craftguard';
addon.author    = 'ClutchHawks';
addon.version   = '1.0';
addon.desc      = 'Effective crafting skill tracking (KI/gear/support/HQ) plus a personal ingredient blocklist that blocks synthesis while HQ is disabled.';
addon.link      = 'https://ashitaxi.com/';

require 'common';

local chat      = require 'chat';
local imgui     = require 'imgui';
local settings  = require 'settings';
local struct    = require 'struct';
local data      = require 'data';

--------------------------------------------------------------------------------------------------
-- Default (per-character) settings
--------------------------------------------------------------------------------------------------
local default_settings = T{
    visible = T{ true, },
    -- Your personal list of ingredients to block synthesis on while HQ is disabled (see the
    -- /cg blocklist commands). [item name] = true.
    blocklist = T{},
    blocklist_enabled   = T{ true, },
};

--------------------------------------------------------------------------------------------------
-- Equipment slot ids (standard FFXI equipment slots, matches Ashita's own equipmon addon)
--------------------------------------------------------------------------------------------------
local EQUIP_SLOTS = T{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
};

-- FFXI's generic "Food" status effect id - the same one regardless of what food you actually ate
-- (confirmed via /cg buffscan). Used only to show whether food is up at all.
local FOOD_BUFF_ID = 251;

-- The outgoing "Synth" packet - sent by the client with the crystal + up to 8 ingredient item ids
-- when you confirm a synthesis attempt. Id and byte offsets confirmed against CatsEyeXI via a
-- real packet capture.
local SYNTH_PACKET_ID           = 0x096;
local SYNTH_PACKET_CRYSTAL_OFFSET     = 0x06; -- unsigned short
local SYNTH_PACKET_INGREDIENT_OFFSET  = 0x0A; -- unsigned short[8], 2 bytes apart

--------------------------------------------------------------------------------------------------
-- Addon state
--------------------------------------------------------------------------------------------------
local craftguard = T{
    settings            = settings.load(default_settings),
    is_open             = T{ true, },

    -- Resolved (name -> id) lookup tables, built on load from data.lua.
    equip_bonus_by_id   = T{},
    hq_block_by_id      = T{},
    hq_chance_by_id     = T{},

    -- Resolved (id -> name) lookup for your personal blocklist (see settings.blocklist
    -- above), rebuilt by rebuild_blocklist() whenever the list changes.
    blocklist_by_id= T{},

    -- Mega Moglification KI tracking, kept up to date by the 0x055 packet handler (see
    -- rebuild_ki_tracking() / the packet_in event below) rather than polling HasKeyItem(), which
    -- was found unreliable. [ki_id] = true/false. ki_confirmed is false until the first real
    -- 0x055 packet updates it (only sent on login/zone/KI change) - until then, ki_state holds a
    -- best-effort HasKeyItem() bootstrap that may be wrong.
    ki_state            = T{},
    ki_confirmed        = false,

    -- Recomputed every visible frame.
    rows                = T{},
    equipped_bonus_items= T{},
    hq_disabled         = false,
    hq_blocking_names   = T{},
    hq_chance_bonus     = 0,
    hq_chance_items     = T{},
    active_support_buffs= T{},
    support_status      = T{}, -- ON/OFF + countdown info for the status line, built by recompute()
    food_active         = false, -- whether the generic "Food" buff (id 251) is currently up

    -- Persists ACROSS frames (unlike the above) - records when each currently-active support buff
    -- was first seen, so we can count down from its configured duration in data.lua.
    support_started_at  = T{},
};

--------------------------------------------------------------------------------------------------
-- Resolves the item names in data.lua to their internal item ids.
-- Prints a warning for any name that couldn't be found in the game's resources.
--------------------------------------------------------------------------------------------------
local function resolve_item_database()
    craftguard.equip_bonus_by_id = T{};
    craftguard.hq_block_by_id = T{};
    craftguard.hq_chance_by_id = T{};

    local resmgr = AshitaCore:GetResourceManager();
    local unresolved = T{};

    data.EQUIP_BONUS:each(function (info, name)
        local item = resmgr:GetItemByName(name, 0);
        if (item == nil) then
            unresolved:append(name);
        else
            craftguard.equip_bonus_by_id[item.Id] = T{ name = name, craft = info.craft, bonus = info.bonus, };
        end
    end);

    data.HQ_BLOCKING_ITEMS:each(function (_, name)
        local item = resmgr:GetItemByName(name, 0);
        if (item == nil) then
            unresolved:append(name);
        else
            craftguard.hq_block_by_id[item.Id] = name;
        end
    end);

    data.HQ_CHANCE_BONUS:each(function (chance, name)
        local item = resmgr:GetItemByName(name, 0);
        if (item == nil) then
            unresolved:append(name);
        else
            craftguard.hq_chance_by_id[item.Id] = T{ name = name, chance = chance, };
        end
    end);

    if (#unresolved > 0) then
        print(chat.header(addon.name):append(chat.error('Warning: Could not resolve the following item name(s) from data.lua (check spelling):')));
        unresolved:each(function (name)
            print(chat.header(addon.name):append(chat.error('  - ')):append(chat.message(name)));
        end);
    end
end

--------------------------------------------------------------------------------------------------
-- Rebuilds craftguard.blocklist_by_id from craftguard.settings.blocklist (the item
-- names you've added via /cg blocklist add). Called whenever the list changes, and on
-- load/reload. Silently skips any name that doesn't resolve - blocklist_add() already warns about that
-- at the time you add it, so no need to warn again every time this rebuilds.
--------------------------------------------------------------------------------------------------
local function rebuild_blocklist()
    craftguard.blocklist_by_id = T{};
    local resmgr = AshitaCore:GetResourceManager();

    craftguard.settings.blocklist:each(function (_, name)
        local item = resmgr:GetItemByName(name, 0);
        if (item ~= nil) then
            craftguard.blocklist_by_id[item.Id] = name;
        end
    end);
end

--------------------------------------------------------------------------------------------------
-- Mega Moglification KI tracking via the 0x055 (key items) packet.
--
-- HasKeyItem() was found to be unreliable for these ids (a retail client update broke Ashita's
-- HasKeyItem pattern - see the note atom0s posted about it). Instead, this listens for the raw
-- 0x055 packet the server sends and reads the KI bits directly, the same way the server itself
-- tracks them. The packet is sent per 512-item chunk on login/zone-in, and again (for just the
-- affected chunk) whenever a key item actually changes - it is NOT sent on demand, so the KI
-- column won't be accurate until at least one 0x055 has arrived after this addon loads.
--------------------------------------------------------------------------------------------------

-- Groups each craft's configured KI id by which 512-item chunk it lives in (floor(id / 512)), so
-- the packet handler only has to do work for chunks that actually contain a KI we care about.
-- Rebuilt whenever data.lua is reloaded, in case the configured ids ever change.
local ki_tracked_by_chunk = T{};

local function rebuild_ki_tracking()
    ki_tracked_by_chunk = T{};
    data.CRAFTS:each(function (craft)
        local chunk = math.floor(craft.ki / 512); -- Ashita's Lua (LuaJIT) has no // operator
        ki_tracked_by_chunk[chunk] = ki_tracked_by_chunk[chunk] or T{};
        ki_tracked_by_chunk[chunk]:append(craft);
    end);
end

-- Best-effort seed of craftguard.ki_state directly from HasKeyItem(), used on load so the KI
-- column isn't blank while waiting for the next 0x055 packet. Since HasKeyItem() is the
-- unreliable call this whole system exists to route around, this is only a placeholder until a
-- real 0x055 packet arrives and sets craftguard.ki_confirmed = true - if HasKeyItem happens to be
-- working fine on your Ashita version, this will already be correct.
local function bootstrap_ki_from_memory()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then
        return false;
    end

    data.CRAFTS:each(function (craft)
        craftguard.ki_state[craft.ki] = player:HasKeyItem(craft.ki);
    end);

    return true;
end

--------------------------------------------------------------------------------------------------
-- Returns the item id equipped in the given slot, or nil if the slot is empty.
--------------------------------------------------------------------------------------------------
local function get_equipped_item_id(slot)
    local inv = AshitaCore:GetMemoryManager():GetInventory();

    local eitem = inv:GetEquippedItem(slot);
    if (eitem == nil or eitem.Index == 0) then
        return nil;
    end

    local container = bit.band(eitem.Index, 0xFF00) / 0x0100;
    local index = eitem.Index % 0x0100;

    local iitem = inv:GetContainerItem(container, index);
    if (iitem == nil or T{ nil, 0, -1, 65535 }:hasval(iitem.Id)) then
        return nil;
    end

    return iitem.Id;
end

--------------------------------------------------------------------------------------------------
-- Does a fresh, on-demand scan of equipped gear for any HQ-blocking item. Deliberately NOT using
-- the cached craftguard.hq_disabled from recompute() here, since recompute() only runs while the
-- window is visible (via render()) - the packet_out handler below needs an accurate answer even
-- if the window is hidden.
--------------------------------------------------------------------------------------------------
local function is_hq_currently_disabled()
    local blocking_name = nil;

    EQUIP_SLOTS:each(function (slot)
        if (blocking_name == nil) then
            local itemid = get_equipped_item_id(slot);
            if (itemid ~= nil) then
                local name = craftguard.hq_block_by_id[itemid];
                if (name ~= nil) then
                    blocking_name = name;
                end
            end
        end
    end);

    return (blocking_name ~= nil), blocking_name;
end

--------------------------------------------------------------------------------------------------
-- Returns the player's currently active buff/status effect ids (deduped, zero entries skipped).
--------------------------------------------------------------------------------------------------
local function get_active_buffs()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then
        return T{};
    end

    local raw = player:GetBuffs();
    if (raw == nil) then
        return T{};
    end

    local seen = T{};
    local ids = T{};
    for i = 0, #raw do
        local id = raw[i];
        if (id ~= nil and id > 0 and not seen[id]) then -- id 0 and -1 are empty buff slots, not real buffs
            seen[id] = true;
            ids:append(id);
        end
    end

    return ids;
end

--------------------------------------------------------------------------------------------------
-- Recomputes all displayed craft skill / bonus / HQ-block data from current game state.
--------------------------------------------------------------------------------------------------
local function recompute()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then
        return;
    end

    -- Scan equipment once, tally per-craft gear bonuses, HQ-chance bonuses, and detect
    -- HQ-blocking items..
    local gear_bonus = T{};
    local all_gear_bonus = 0;
    local equipped_bonus_items = T{};
    local hq_disabled = false;
    local hq_blocking_names = T{};
    local hq_chance_bonus = 0;
    local hq_chance_items = T{};

    EQUIP_SLOTS:each(function (slot)
        local itemid = get_equipped_item_id(slot);
        if (itemid ~= nil) then
            local bonus_info = craftguard.equip_bonus_by_id[itemid];
            if (bonus_info ~= nil) then
                if (bonus_info.craft == 'ALL') then
                    all_gear_bonus = all_gear_bonus + bonus_info.bonus;
                else
                    gear_bonus[bonus_info.craft] = (gear_bonus[bonus_info.craft] or 0) + bonus_info.bonus;
                end
                equipped_bonus_items:append(bonus_info);
            end

            local blocking_name = craftguard.hq_block_by_id[itemid];
            if (blocking_name ~= nil) then
                hq_disabled = true;
                hq_blocking_names:append(blocking_name);
            end

            local chance_info = craftguard.hq_chance_by_id[itemid];
            if (chance_info ~= nil) then
                hq_chance_bonus = hq_chance_bonus + chance_info.chance;
                hq_chance_items:append(chance_info);
            end
        end
    end);

    -- Scan active buffs once, tally per-craft Synthesis Support bonuses, and check food status..
    local support_bonus = T{};
    local all_support_bonus = 0;
    local active_support_buffs = T{};
    local active_buffs = get_active_buffs();

    active_buffs:each(function (buffid)
        local info = data.SUPPORT_BUFFS[buffid];
        if (info ~= nil) then
            if (info.craft == 'ALL') then
                all_support_bonus = all_support_bonus + info.bonus;
            else
                support_bonus[info.craft] = (support_bonus[info.craft] or 0) + info.bonus;
            end
            active_support_buffs:append(T{ id = buffid, craft = info.craft, bonus = info.bonus, });
        end
    end);

    -- Food status - just a quick "do you currently have food up" check. FFXI's food status effect
    -- uses one generic "Food" buff id (251) no matter what you actually ate, so this can't say
    -- WHICH food or what its bonus is - just whether one is active at all.
    local food_active = active_buffs:hasval(FOOD_BUFF_ID);

    -- Track how long each currently-active support buff has been up, so the window can show an
    -- ON/OFF status line with a countdown, similar to the HQ line. craftguard.support_started_at
    -- persists ACROSS frames (unlike everything else in this function), so a buff's start time is
    -- only recorded the first frame it's seen active, and forgotten once it's no longer active -
    -- meaning a future re-activation of the same buff id starts a fresh countdown, not a stale one.
    local now = os.time();
    local still_active = T{};
    local support_status = T{};

    active_support_buffs:each(function (info)
        still_active[info.id] = true;

        if (craftguard.support_started_at[info.id] == nil) then
            craftguard.support_started_at[info.id] = now;
        end

        local buff_data = data.SUPPORT_BUFFS[info.id];
        local duration = (buff_data ~= nil and buff_data.duration) or 0;
        local elapsed = now - craftguard.support_started_at[info.id];
        local remaining = duration - elapsed;
        if (remaining < 0) then
            remaining = 0;
        end

        support_status:append(T{ craft = info.craft, bonus = info.bonus, remaining = remaining, has_duration = duration > 0, });
    end);

    craftguard.support_started_at:each(function (_, id)
        if (not still_active[id]) then
            craftguard.support_started_at[id] = nil;
        end
    end);

    -- Build the display rows for each craft..
    local rows = T{};
    data.CRAFTS:each(function (craft)
        local skill = player:GetCraftSkill(craft.id);
        local base = skill ~= nil and skill:GetSkill() or 0;
        local capped = skill ~= nil and skill:IsCapped() or false;

        local has_ki = craftguard.ki_state[craft.ki];
        local ki_bonus = has_ki and craft.kibonus or 0;
        local this_gear_bonus = (gear_bonus[craft.name] or 0) + all_gear_bonus;
        local this_support_bonus = (support_bonus[craft.name] or 0) + all_support_bonus;

        rows:append(T{
            name          = craft.name,
            base          = base,
            ki_bonus      = ki_bonus,
            gear_bonus    = this_gear_bonus,
            support_bonus = this_support_bonus,
            effective   = base + ki_bonus + this_gear_bonus + this_support_bonus,
            capped      = capped,
        });
    end);

    craftguard.rows = rows;
    craftguard.equipped_bonus_items = equipped_bonus_items;
    craftguard.hq_disabled = hq_disabled;
    craftguard.hq_blocking_names = hq_blocking_names;
    craftguard.hq_chance_bonus = hq_chance_bonus;
    craftguard.hq_chance_items = hq_chance_items;
    craftguard.active_support_buffs = active_support_buffs;
    craftguard.support_status = support_status;
    craftguard.food_active = food_active;
end

--------------------------------------------------------------------------------------------------
-- Formats a whole number of seconds as m:ss for the support countdown display.
--------------------------------------------------------------------------------------------------
local function format_countdown(seconds)
    if (seconds == nil or seconds < 0) then
        seconds = 0;
    end
    local m = math.floor(seconds / 60);
    local s = math.floor(seconds % 60);
    return ('%d:%02d'):fmt(m, s);
end

--------------------------------------------------------------------------------------------------
-- Prints the addon help information.
--------------------------------------------------------------------------------------------------
local function print_help()
    print(chat.header(addon.name):append(chat.message('Available commands:')));

    local cmds = T{
        { '/cg',        'Toggle the window.', },
        { '/cg show',   'Show the window.', },
        { '/cg hide',   'Hide the window.', },
        { '/cg reload', 'Reload data.lua and settings from disk.', },
        { '/cg itemfind <text>', 'Searches ALL item names for <text> and prints matching id(s) - use this if data.lua fails to resolve an item.', },
        { '/cg blocklist add <item>', 'Adds an ingredient to your blocklist - blocked from synthesis while HQ is disabled.', },
        { '/cg blocklist remove <item>', 'Removes an ingredient from your blocklist.', },
        { '/cg blocklist list', 'Lists your current blocklist.', },
        { '/cg blocklist on / off', 'Enables/disables blocklist blocking without clearing your list.', },
        { '/cg help',   'Shows this help.', },
    };

    cmds:each(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

--------------------------------------------------------------------------------------------------
-- Strips a single pair of matching leading/trailing double quotes, if present. Lets
-- /cg blocklist add "Rhodium Ore" and /cg blocklist add Rhodium Ore both work.
--------------------------------------------------------------------------------------------------
local function strip_quotes(s)
    if (s ~= nil and #s >= 2 and s:sub(1, 1) == '"' and s:sub(-1) == '"') then
        return s:sub(2, -2);
    end
    return s;
end

--------------------------------------------------------------------------------------------------
-- Adds an item to your personal blocklist (settings.blocklist), persisted per
-- character. Resolves the name immediately so a typo is caught right away rather than silently
-- never blocking anything.
--------------------------------------------------------------------------------------------------
local function blocklist_add(name)
    if (name == nil or #name == 0) then
        print(chat.header(addon.name):append(chat.error('Usage: /cg blocklist add <item name>')));
        return;
    end

    local resmgr = AshitaCore:GetResourceManager();
    local item = resmgr:GetItemByName(name, 0);
    if (item == nil) then
        print(chat.header(addon.name):append(chat.error(('Could not resolve item "%s" - check spelling, or run /cg itemfind %s to find the exact in-game name.'):fmt(name, name))));
        return;
    end

    craftguard.settings.blocklist[name] = true;
    settings.save();
    rebuild_blocklist();
    print(chat.header(addon.name):append(chat.success(('Added "%s" to your blocklist.'):fmt(name))));
end

--------------------------------------------------------------------------------------------------
-- Removes an item from your blocklist. Requires an exact match against what's stored - use
-- /cg blocklist list if you're not sure of the exact spelling you added it under.
--------------------------------------------------------------------------------------------------
local function blocklist_remove(name)
    if (name == nil or #name == 0) then
        print(chat.header(addon.name):append(chat.error('Usage: /cg blocklist remove <item name>')));
        return;
    end

    if (craftguard.settings.blocklist[name] == nil) then
        print(chat.header(addon.name):append(chat.error(('"%s" is not on your blocklist (run /cg blocklist list to check the exact spelling).'):fmt(name))));
        return;
    end

    craftguard.settings.blocklist[name] = nil;
    settings.save();
    rebuild_blocklist();
    print(chat.header(addon.name):append(chat.success(('Removed "%s" from your blocklist.'):fmt(name))));
end

--------------------------------------------------------------------------------------------------
-- Lists everything currently on your blocklist.
--------------------------------------------------------------------------------------------------
local function blocklist_list()
    local names = T{};
    craftguard.settings.blocklist:each(function (_, name)
        names:append(name);
    end);

    if (#names == 0) then
        print(chat.header(addon.name):append(chat.message('Your blocklist is empty. Add one with /cg blocklist add <item name>.')));
        return;
    end

    print(chat.header(addon.name):append(chat.message(('Blocklist (blocking %s):'):fmt(craftguard.settings.blocklist_enabled[1] and 'ON' or 'OFF - run /cg blocklist on to re-enable'))));
    names:each(function (name)
        print(chat.header(addon.name):append(chat.color1(2, '  - ')):append(chat.message(name)));
    end);
end

--------------------------------------------------------------------------------------------------
-- Searches the full buff/status name table for a substring match and prints every id/name that
-- matches, regardless of whether it's currently active. This finds every craft's Imagery/Support
-- buff id in one pass, without having to visit every guild NPC in person to trigger buffscan.
--------------------------------------------------------------------------------------------------
local function bufffind(search)
    local resmgr = AshitaCore:GetResourceManager();
    if (resmgr == nil or search == nil or #search == 0) then
        return;
    end

    print(chat.header(addon.name):append(chat.message(('Searching buff names for "%s" (this may take a moment)...'):fmt(search))));

    local needle = search:lower();
    local found = 0;
    local active = get_active_buffs();

    for id = 0, 4096 do
        local name = resmgr:GetString('buffs.names', id);
        if (name ~= nil and #name > 0 and name:lower():contains(needle)) then
            found = found + 1;
            local is_active = active:hasval(id);
            print(chat.header(addon.name):append((is_active and chat.success or chat.message)(('  id %d: "%s"%s'):fmt(id, name, is_active and ' (currently active)' or ''))));
        end
    end

    if (found == 0) then
        print(chat.header(addon.name):append(chat.error('No buff names matched.')));
    end
end

--------------------------------------------------------------------------------------------------
-- Searches the full item name table for a substring match and prints every id/name that matches.
-- Use this whenever an item name in data.lua fails to resolve (see the warning on load/reload) -
-- it reads the name straight from the game's own data, so it's authoritative for CatsEyeXI even
-- when it doesn't match what a retail wiki calls the item (server can rename/abbreviate items).
--------------------------------------------------------------------------------------------------
local function itemfind(search)
    local resmgr = AshitaCore:GetResourceManager();
    if (resmgr == nil or search == nil or #search == 0) then
        return;
    end

    print(chat.header(addon.name):append(chat.message(('Searching item names for "%s" (this may take a moment)...'):fmt(search))));

    local needle = search:lower();
    local found = 0;

    for id = 0, 20000 do
        local item = resmgr:GetItemById(id);
        if (item ~= nil and item.Name ~= nil and item.Name[1] ~= nil and #item.Name[1] > 0 and item.Name[1]:lower():contains(needle)) then
            found = found + 1;
            print(chat.header(addon.name):append(chat.success(('  id %d: "%s"'):fmt(id, item.Name[1]))));
        end
    end

    if (found == 0) then
        print(chat.header(addon.name):append(chat.error('No item names matched.')));
    end
end

--------------------------------------------------------------------------------------------------
-- Prints every currently active buff/status effect on the player, with its name. Use this while
-- standing at a guild NPC with Synthesis Support active to find its real buff id.
--------------------------------------------------------------------------------------------------
local function buffscan()
    local resmgr = AshitaCore:GetResourceManager();
    local ids = get_active_buffs();

    if (#ids == 0) then
        print(chat.header(addon.name):append(chat.error('No active buffs detected.')));
        return;
    end

    print(chat.header(addon.name):append(chat.message('Currently active buffs:')));
    ids:each(function (id)
        local name = resmgr:GetString('buffs.names', id) or '(unknown)';
        print(chat.header(addon.name):append(chat.success(('  id %d: "%s"'):fmt(id, name))));
    end);
end

--------------------------------------------------------------------------------------------------
-- Renders the main window.
--------------------------------------------------------------------------------------------------
local function render()
    if (not craftguard.settings.visible[1]) then
        return;
    end

    recompute();

    imgui.SetNextWindowSize({ 480, 0, }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('CraftGuard', craftguard.settings.visible, ImGuiWindowFlags_AlwaysAutoResize)) then
        -- HQ status banner..
        if (craftguard.hq_disabled) then
            imgui.TextColored({ 1.0, 0.3, 0.3, 1.0 }, ('HQ DISABLED - wearing: %s'):fmt(table.concat(craftguard.hq_blocking_names, ', ')));
        else
            if (craftguard.hq_chance_bonus > 0) then
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, ('HQ Enabled (HQ+%d)'):fmt(craftguard.hq_chance_bonus));
            else
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'HQ Enabled');
            end
        end

        -- Guild Synthesis Support status banner..
        if (#craftguard.support_status == 0) then
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Support: OFF');
        else
            craftguard.support_status:each(function (info)
                if (info.has_duration) then
                    imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, ('Support: ON - %s (+%d) - %s left'):fmt(info.craft, info.bonus, format_countdown(info.remaining)));
                else
                    imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, ('Support: ON - %s (+%d)'):fmt(info.craft, info.bonus));
                end
            end);
        end

        -- Food status - just whether the generic "Food" buff is up, not which food or its bonus.
        if (craftguard.food_active) then
            imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Food Active');
        else
            imgui.TextColored({ 1.0, 0.3, 0.3, 1.0 }, 'No Food');
        end

        if (not craftguard.ki_confirmed) then
            imgui.TextColored({ 1.0, 0.85, 0.3, 1.0 }, 'KI status not yet confirmed - zone once for accurate KI detection.');
        end

        imgui.Separator();

        -- Craft skill table..
        if (imgui.BeginTable('craftguard_table', 6, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg, ImGuiTableFlags_SizingStretchProp))) then
            imgui.TableSetupColumn('Craft');
            imgui.TableSetupColumn('Base');
            imgui.TableSetupColumn('KI');
            imgui.TableSetupColumn('Gear');
            imgui.TableSetupColumn('Support');
            imgui.TableSetupColumn('Effective');
            imgui.TableHeadersRow();

            craftguard.rows:each(function (row)
                imgui.TableNextRow();

                imgui.TableNextColumn();
                imgui.Text(row.name);

                imgui.TableNextColumn();
                imgui.Text(('%d'):fmt(row.base));

                imgui.TableNextColumn();
                imgui.Text(row.ki_bonus > 0 and ('+%d'):fmt(row.ki_bonus) or '-');

                imgui.TableNextColumn();
                imgui.Text(row.gear_bonus > 0 and ('+%d'):fmt(row.gear_bonus) or '-');

                imgui.TableNextColumn();
                imgui.Text(row.support_bonus > 0 and ('+%d'):fmt(row.support_bonus) or '-');

                imgui.TableNextColumn();
                if (row.capped) then
                    imgui.TextColored({ 1.0, 0.85, 0.3, 1.0 }, ('%d (capped)'):fmt(row.effective));
                else
                    imgui.Text(('%d'):fmt(row.effective));
                end
            end);

            imgui.EndTable();
        end

        -- Detected bonus gear, so you can verify data.lua is matching what you're wearing..
        if (#craftguard.equipped_bonus_items > 0) then
            imgui.Separator();
            imgui.TextDisabled('Detected crafting gear:');
            craftguard.equipped_bonus_items:each(function (info)
                imgui.BulletText(('%s (%s, +%d)'):fmt(info.name, info.craft, info.bonus));
            end);
        end

        -- Detected active Synthesis Support buffs, so you can verify data.lua is matching what's active..
        if (#craftguard.active_support_buffs > 0) then
            imgui.Separator();
            imgui.TextDisabled('Active support buffs:');
            craftguard.active_support_buffs:each(function (info)
                imgui.BulletText(('id %d (%s, +%d)'):fmt(info.id, info.craft, info.bonus));
            end);
        end

        -- Detected HQ-chance gear, so you can verify data.lua is matching what you're wearing..
        if (#craftguard.hq_chance_items > 0) then
            imgui.Separator();
            imgui.TextDisabled('Detected HQ-chance gear:');
            craftguard.hq_chance_items:each(function (info)
                imgui.BulletText(('%s (HQ+%d)'):fmt(info.name, info.chance));
            end);
        end

        -- Your blocklist, so you can see what's protected without needing /cg blocklist list.
        if (next(craftguard.settings.blocklist) ~= nil) then
            imgui.Separator();
            if (craftguard.settings.blocklist_enabled[1]) then
                imgui.TextDisabled('Blocklist (blocking while HQ disabled):');
            else
                imgui.TextColored({ 1.0, 0.85, 0.3, 1.0 }, 'Blocklist (blocking OFF - /cg blocklist on to enable):');
            end
            craftguard.settings.blocklist:each(function (_, name)
                imgui.BulletText(name);
            end);
        end
    end
    imgui.End();
end

--------------------------------------------------------------------------------------------------
-- event: load
--------------------------------------------------------------------------------------------------
ashita.events.register('load', 'load_cb', function ()
    resolve_item_database();
    rebuild_ki_tracking();
    bootstrap_ki_from_memory();
    rebuild_blocklist();
end);

--------------------------------------------------------------------------------------------------
-- event: packet_in
--------------------------------------------------------------------------------------------------
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    -- Packet: Key Items (0x055) - sent per 512-item chunk on zone-in, and again (for just the
    -- affected chunk) whenever a key item changes. See the KI tracking comment above.
    if (e.id ~= 0x055) then
        return;
    end

    local chunk = struct.unpack('B', e.data, 0x84 + 1);
    local tracked = ki_tracked_by_chunk[chunk];
    if (tracked == nil) then
        return;
    end

    local chunk_offset = chunk * 512;
    tracked:each(function (craft)
        local bit_index = craft.ki - chunk_offset;
        craftguard.ki_state[craft.ki] = (ashita.bits.unpack_be(e.data_raw, 0x04, bit_index, 1) == 1);
    end);

    craftguard.ki_confirmed = true;
end);

--------------------------------------------------------------------------------------------------
-- event: packet_out
--------------------------------------------------------------------------------------------------
ashita.events.register('packet_out', 'packet_out_cb', function (e)
    -- Packet: Synth (0x096) - sent when you confirm a synthesis attempt, containing the crystal
    -- and up to 8 ingredient item ids. See the SYNTH_PACKET_* constants above.
    if (e.id ~= SYNTH_PACKET_ID or not craftguard.settings.blocklist_enabled[1]) then
        return;
    end

    -- Nothing to check against - skip the packet read entirely if the blocklist is empty.
    if (next(craftguard.blocklist_by_id) == nil) then
        return;
    end

    local hq_disabled, blocking_ring = is_hq_currently_disabled();
    if (not hq_disabled) then
        return;
    end

    local hit_name = nil;

    local crystal_id = struct.unpack('H', e.data, SYNTH_PACKET_CRYSTAL_OFFSET + 1);
    if (craftguard.blocklist_by_id[crystal_id] ~= nil) then
        hit_name = craftguard.blocklist_by_id[crystal_id];
    end

    if (hit_name == nil) then
        for i = 0, 7 do
            local ingredient_id = struct.unpack('H', e.data, SYNTH_PACKET_INGREDIENT_OFFSET + (i * 2) + 1);
            if (ingredient_id ~= nil and ingredient_id ~= 0 and craftguard.blocklist_by_id[ingredient_id] ~= nil) then
                hit_name = craftguard.blocklist_by_id[ingredient_id];
                break;
            end
        end
    end

    if (hit_name ~= nil) then
        e.blocked = true;
        print(chat.header(addon.name):append(chat.error(('Synthesis BLOCKED - "%s" is on your blocklist and %s is currently blocking HQ. Remove the ring, or run /cg blocklist remove %s to allow it.'):fmt(hit_name, blocking_ring, hit_name))));
    end
end);

--------------------------------------------------------------------------------------------------
-- event: command
--------------------------------------------------------------------------------------------------
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/craftguard', '/cg')) then
        return;
    end

    e.blocked = true;

    if (#args == 1) then
        craftguard.settings.visible[1] = not craftguard.settings.visible[1];
        settings.save();
        return;
    end

    if (args[2]:any('show')) then
        craftguard.settings.visible[1] = true;
        settings.save();
        return;
    end

    if (args[2]:any('hide')) then
        craftguard.settings.visible[1] = false;
        settings.save();
        return;
    end

    if (args[2]:any('reload', 'rl')) then
        package.loaded['data'] = nil; -- Force a fresh read of data.lua from disk, not the cached module.
        data = require('data');
        resolve_item_database();
        rebuild_ki_tracking();
        settings.reload();
        rebuild_blocklist(); -- after settings.reload(), so it reflects any on-disk changes
        print(chat.header(addon.name):append(chat.message('data.lua and settings reloaded.')));
        return;
    end

    if (args[2]:any('itemfind')) then
        if (#args < 3) then
            print(chat.header(addon.name):append(chat.error('Usage: /cg itemfind <text>')));
            return;
        end
        itemfind(args:concat(' ', 3));
        return;
    end

    if (args[2]:any('buffscan')) then
        buffscan();
        return;
    end

    if (args[2]:any('bufffind')) then
        local search = (#args >= 3) and args:concat(' ', 3) or 'Imagery';
        bufffind(search);
        return;
    end

    if (args[2]:any('blocklist', 'bl')) then
        local sub = args[3] and args[3]:lower() or nil;

        if (sub == 'list') then
            blocklist_list();
            return;
        end

        if (sub == 'on') then
            craftguard.settings.blocklist_enabled[1] = true;
            settings.save();
            print(chat.header(addon.name):append(chat.success('Blocklist blocking enabled.')));
            return;
        end

        if (sub == 'off') then
            craftguard.settings.blocklist_enabled[1] = false;
            settings.save();
            print(chat.header(addon.name):append(chat.error('Blocklist blocking disabled (your blocklist is kept, just not enforced).')));
            return;
        end

        if (sub == 'remove' or sub == 'rm') then
            blocklist_remove(strip_quotes(args:concat(' ', 4)));
            return;
        end

        if (sub == 'add') then
            blocklist_add(strip_quotes(args:concat(' ', 4)));
            return;
        end

        -- Shorthand: /cg blocklist <item name> behaves like "add".
        if (#args < 3) then
            print(chat.header(addon.name):append(chat.error('Usage: /cg blocklist add|remove|list|on|off [item name]')));
            return;
        end
        blocklist_add(strip_quotes(args:concat(' ', 3)));
        return;
    end

    print_help();
end);

--------------------------------------------------------------------------------------------------
-- event: d3d_present
--------------------------------------------------------------------------------------------------
ashita.events.register('d3d_present', 'present_cb', function ()
    render();
end);

--------------------------------------------------------------------------------------------------
-- event: unload
--------------------------------------------------------------------------------------------------
ashita.events.register('unload', 'unload_cb', function ()
    settings.save();
end);
