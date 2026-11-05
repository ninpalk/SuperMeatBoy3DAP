"""Stable protocol v1 IDs. Do not renumber when adding content."""
GAME = "Super Meat Boy 3D"
BASE_ID = 0x534D4200
WORLD_COUNT = 5
LEVEL_COUNT = 15
BOSS_REQUIREMENT = 10

ITEMS = {f"World {w} Access": BASE_ID + w for w in range(2, 6)}
ITEMS.update({f"{w}-{level} Access": BASE_ID + 100 + (w - 1) * 15 + level
              for w in range(2, 6) for level in range(1, 16)})
ITEMS.update({f"Dark {w}-{level} Access": BASE_ID + 300 + (w - 1) * 15 + level
              for w in range(1, 6) for level in range(1, 16)})
ITEMS.update({f"World {w} Warp Zone Access": BASE_ID + 500 + w for w in range(1, 6)})
ITEMS["Filler"] = BASE_ID + 900
ITEMS["Tofu Trap"] = BASE_ID + 901
LOCATIONS = {}
for w in range(1, 6):
    for level in range(1, 16):
        offset = (w - 1) * 15 + level
        LOCATIONS[f"{w}-{level}"] = BASE_ID + 1000 + offset
        LOCATIONS[f"{w}-{level} Bandage"] = BASE_ID + 1100 + offset
        LOCATIONS[f"Dark {w}-{level}"] = BASE_ID + 1200 + offset
    LOCATIONS[f"World {w} Boss"] = BASE_ID + 1400 + w

APLUS_LOCATIONS = {}
for w in range(1, 6):
    for level in range(1, 16):
        offset = (w - 1) * 15 + level
        APLUS_LOCATIONS[f"{w}-{level} A+"] = BASE_ID + 1500 + offset
        APLUS_LOCATIONS[f"Dark {w}-{level} A+"] = BASE_ID + 1600 + offset
WARP_ENTRANCE_LEVELS = {2: 6, 3: 10, 4: 3, 5: 8}
WARP_LOCATIONS = {f"World {w} Warp Zone": BASE_ID + 1700 + w for w in range(1, 6)}
ALL_LOCATIONS = {**LOCATIONS, **APLUS_LOCATIONS, **WARP_LOCATIONS}

def clear_event(world, level):
    return f"Light {world}-{level} Cleared"

def boss_event(world):
    return f"World {world} Boss Defeated"


def active_locations(darksanity=True, speedsanity=False, bandagesanity=True, warpzonesanity=False):
    catalog = {**LOCATIONS, **(APLUS_LOCATIONS if speedsanity else {}), **(WARP_LOCATIONS if warpzonesanity else {})}
    return {name: identifier for name, identifier in catalog.items()
            if (darksanity or not name.startswith("Dark "))
            and (bandagesanity or not name.endswith(" Bandage"))}


def active_items(darksanity=True, warpzonesanity=False):
    return {name: identifier for name, identifier in ITEMS.items()
            if (darksanity or not name.startswith("Dark "))
            and (warpzonesanity or not name.endswith(" Warp Zone Access"))}
