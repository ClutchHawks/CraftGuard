--[[
    CraftSkill - Item & Key Item Database
    --------------------------------------------------------------------------
    This file is the ONLY file you should need to edit to keep the addon
    accurate for CatsEyeXI. It is kept separate from craftskill.lua so you
    can update item names/bonus values without touching any addon logic.

    HOW TO ADD/EDIT ENTRIES
    --------------------------------------------------------------------------
    Item names must be typed EXACTLY as they appear in-game (the addon looks
    them up by name when it loads, via the game's own resource data). If a
    name doesn't match, the addon will print a warning listing which entries
    it could not resolve - check that message after /craftskill reload.

    Anything marked TODO below is a placeholder. The addon will still load
    and work without them filled in (it just won't add those bonuses), but
    the "effective skill" numbers won't be accurate until you fill them in.
--]]

local data = T{};

--[[
    The 9 standard synthesis skills, in the order they're displayed.

    id      = the LOCAL index into the game's craft-skill array (this is a
              SEPARATE 0-based list from combat skills, not the global skill
              id you may have seen elsewhere - Fishing=0, Woodworking=1, etc,
              matching the order the game itself stores them in).
    ki      = the internal key item id for that craft's "Mega Moglification"
              guild-rank key item (confirmed from CatsEyeXI's resource ids)
    kibonus = flat skill points granted while you hold that key item.
              Confirmed as +5 for Goldsmithing; assumed the same for the
              other 8 crafts since they follow the same naming/id pattern.
              Change any of these individually if one turns out to differ.
--]]
data.CRAFTS = T{
    { name = 'Woodworking',  id = 1, ki = 554, kibonus = 5 },
    { name = 'Smithing',     id = 2, ki = 555, kibonus = 5 },
    { name = 'Goldsmithing', id = 3, ki = 556, kibonus = 5 },
    { name = 'Clothcraft',   id = 4, ki = 557, kibonus = 5 },
    { name = 'Leathercraft', id = 5, ki = 558, kibonus = 5 },
    { name = 'Bonecraft',    id = 6, ki = 559, kibonus = 5 },
    { name = 'Alchemy',      id = 7, ki = 560, kibonus = 5 },
    { name = 'Cooking',      id = 8, ki = 561, kibonus = 5 },
};

--[[
    Equipment skill bonuses.

    Key   = exact in-game item name.
    craft = must match one of the `name` values in data.CRAFTS above,
            OR the special value 'ALL' for items that boost every craft
            at once.
    bonus = flat skill points added while equipped in ANY slot.

    IMPORTANT: The 8 per-craft guild rings (Goldsmith's Ring, etc.) do NOT
    belong here - confirmed via their actual tooltip, they give a small
    Success Rate % (not skill) and disable HQ. They're listed in
    HQ_BLOCKING_ITEMS below instead, not here.
--]]
data.EQUIP_BONUS = T{
    -- Confirmed all-craft bonus items (do NOT block HQ):
    ['Kupo Shield']       = { craft = 'ALL', bonus = 3 }, -- Confirmed: Synthesis skill +3, all crafts (Shield slot)
    ['Artisan\'s Torque']    = { craft = 'ALL', bonus = 2 }, -- Confirmed: +2 to all crafts (Neck slot)
    ['Artisan\'s Torque +1'] = { craft = 'ALL', bonus = 2 }, -- Confirmed: same +2 to all crafts as the base torque (Neck slot)

    -- Standard guild NPC "apron" gear (Body slot, level 1/all jobs, rare/ex). CatsEyeXI uses the
    -- full retail names for most of these, EXCEPT Smithing and Bonecraft, which are abbreviated
    -- server-side (confirmed via /craftskill reload's "could not resolve" warning + the item
    -- list screenshot). If Boneworker's Apn. still doesn't resolve, run
    -- /craftskill itemfind Apn to get the exact spelling straight from the game's own data.
    ['Carpenter\'s Apron']  = { craft = 'Woodworking',   bonus = 1 },
    ['Blacksmith\'s Apn.']  = { craft = 'Smithing',      bonus = 1 }, -- Confirmed abbreviated on CatsEyeXI
    ['Goldsmith\'s Apron']  = { craft = 'Goldsmithing',  bonus = 1 },
    ['Weaver\'s Apron']     = { craft = 'Clothcraft',    bonus = 1 },
    ['Tanner\'s Apron']     = { craft = 'Leathercraft',  bonus = 1 },
    ['Boneworker\'s Apn.']  = { craft = 'Bonecraft',     bonus = 1 }, -- Best guess at the abbreviation, same pattern as Blacksmith's - confirm with itemfind if it doesn't resolve
    ['Alchemist\'s Apron']  = { craft = 'Alchemy',       bonus = 1 },
    ['Culinarian\'s Apron'] = { craft = 'Cooking',       bonus = 1 }, -- Confirmed: DEF:2, Fire+1, Water+1, Cooking skill +1

    -- Guild Point shop gear (70,000 GP each on CatsEyeXI's guide) - a SECOND item per craft,
    -- separate from and stacking with the apron above. Each gives another +1 to its craft.
    -- Several of these are ALSO abbreviated server-side (Spectacles -> Specs.) - names below are
    -- confirmed against your item list screenshot, not the full retail wiki names.
    ['Carpenter\'s Gloves'] = { craft = 'Woodworking',   bonus = 1 }, -- Confirmed resolves
    ['Smithy\'s Mitts']     = { craft = 'Smithing',      bonus = 1 }, -- Confirmed resolves
    ['Shaded Specs.']       = { craft = 'Goldsmithing',  bonus = 1 }, -- Confirmed abbreviated in-game
    ['Magnifying Specs.']   = { craft = 'Clothcraft',    bonus = 1 }, -- Confirmed abbreviated in-game
    ['Tanner\'s Gloves']    = { craft = 'Leathercraft',  bonus = 1 }, -- Confirmed via item list screenshot (not "Tanner's Mitts")
    ['Protective Specs.']   = { craft = 'Bonecraft',     bonus = 1 }, -- Confirmed abbreviated in-game
    ['Caduceus']            = { craft = 'Alchemy',       bonus = 1 }, -- Confirmed resolves
    ['Chef\'s Hat']         = { craft = 'Cooking',       bonus = 1 }, -- Confirmed resolves

    -- TODO: Craftkeeper's Ring / Artificer's Ring - still unconfirmed what these grant.
    -- Craftmaster's Ring/+1 turned out to NOT belong here at all - see HQ_CHANCE_BONUS below,
    -- they boost your % chance of a synthesis coming out HQ, not flat skill.
    -- ['Craftkeeper\'s Ring'] = { craft = 'ALL', bonus = 0 },
    -- ['Artificer\'s Ring']   = { craft = 'ALL', bonus = 0 },
};

--[[
    Items that increase your % chance of a synthesis coming out High Quality (separate from the
    HQ_BLOCKING_ITEMS below, which disable HQ entirely - these just make it more likely once HQ
    is possible at all).

    Key   = exact in-game item name. Only the +1 version is abbreviated server-side
            ("Craftmaster's" -> "Craftmstr.'s") - confirmed via your item list screenshot. The
            base ring is NOT abbreviated (confirmed via its own examine-window tooltip, which
            spelled out "Craftmaster's ring" in full) - my last guess wrongly abbreviated it too.
    value = the % HQ chance bonus while equipped in ANY slot. Confirmed: Craftmaster's Ring +1%,
            Craftmstr.'s Ring +1 (the upgraded version) +2%. Both can be worn at once (two ring
            slots), stacking to +3. Assumed to apply to all crafts, same as the naming pattern of
            the other universal ALL-craft items above - let me know if it's craft-specific instead.
--]]
data.HQ_CHANCE_BONUS = T{
    ['Craftmaster\'s Ring']   = 1, -- Confirmed via examine-window tooltip - NOT abbreviated
    ['Craftmstr.\'s Ring +1'] = 2, -- Confirmed abbreviated in-game via your screenshot
};

--[[
    Items that disable HQ synthesis entirely while equipped in ANY slot.

    Confirmed via in-game tooltip: the per-craft guild rings read
    "<Craft> Success Rate +1% / Cannot synthesize high quality items" - so
    every one of them blocks HQ (not just Artisan's Ring/+1, which are the
    combined, all-craft version of the same thing and do the same).
--]]
data.HQ_BLOCKING_ITEMS = T{
    ['Carpenter\'s Ring']   = true,
    ['Smith\'s Ring']       = true,
    ['Goldsmith\'s Ring']   = true,
    ['Tailor\'s Ring']      = true,
    ['Tanner\'s Ring']      = true,
    ['Bonecrafter\'s Ring'] = true,
    ['Alchemist\'s Ring']   = true,
    ['Chef\'s Ring']        = true,
    ['Artisan\'s Ring']     = true,
    ['Artisan\'s Ring +1']  = true,
};

--[[
    Guild NPC "Synthesis Support" buffs (talk to a guild NPC, pay for Basic
    or Advanced support). These are temporary STATUS EFFECTS, not key items
    or equipment, so they're tracked separately here by buff id.

    Key   = the buff/status effect id (find it with /craftskill buffscan
            while the support buff is active).
    craft = must match a `name` in data.CRAFTS, or 'ALL' if the same buff id
            applies regardless of which craft you're getting support for.
    bonus    = flat skill points added while the buff is active.
    duration = how many REAL-TIME seconds the buff lasts, used to drive the
               on-screen countdown timer. The client doesn't expose the
               server's actual remaining time, so the addon starts its own
               countdown the moment it first detects the buff, using this
               value as the total length. This is currently retail's
               documented Advanced Support duration (3 Vana'diel hours 20
               minutes = 8 real minutes = 480 seconds) - if CatsEyeXI's
               timing differs, adjust this number so the timer matches what
               you see drop off in-game (the addon will still correctly
               show ON/OFF regardless, since that's read live every frame -
               only the countdown number depends on this being accurate).

    Confirmed: each craft has its OWN buff, named "<Craft> Imagery" (not a
    single shared 'ALL' buff like the KIs/gear above). All 8 ids below are
    confirmed. Advanced Support confirmed as +3 skill; if Basic Support
    turns out to use a different (lower) id/bonus/duration, add those
    separately - right now these ids are assumed to be the Advanced tier
    only.
--]]
data.SUPPORT_BUFFS = T{
    [236] = { craft = 'Woodworking',  bonus = 3, duration = 480 }, -- "Woodworking Imagery"
    [237] = { craft = 'Smithing',     bonus = 3, duration = 480 }, -- "Smithing Imagery"
    [238] = { craft = 'Goldsmithing', bonus = 3, duration = 480 }, -- "Goldsmithing Imagery", confirmed via buffscan
    [239] = { craft = 'Clothcraft',   bonus = 3, duration = 480 }, -- "Clothcraft Imagery"
    [240] = { craft = 'Leathercraft', bonus = 3, duration = 480 }, -- "Leathercraft Imagery"
    [241] = { craft = 'Bonecraft',    bonus = 3, duration = 480 }, -- "Bonecraft Imagery"
    [242] = { craft = 'Alchemy',      bonus = 3, duration = 480 }, -- "Alchemy Imagery"
    [243] = { craft = 'Cooking',      bonus = 3, duration = 480 }, -- "Cooking Imagery"
};

return data;
