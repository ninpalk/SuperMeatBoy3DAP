from dataclasses import dataclass

from BaseClasses import Item, ItemClassification, Location, Region, Tutorial
from Options import PerGameCommonOptions, Toggle, Range, Choice
from worlds.AutoWorld import WebWorld, World

from .data import GAME, ITEMS, LOCATIONS, ALL_LOCATIONS, APLUS_LOCATIONS, BOSS_REQUIREMENT, clear_event, boss_event, active_locations, active_items, WARP_LOCATIONS, WARP_ENTRANCE_LEVELS


class SMB3DItem(Item):
    game = GAME


class SMB3DLocation(Location):
    game = GAME


class Darksanity(Toggle):
    """Add 75 dark level clear checks and 75 individual dark level access items.
    When Speedsanity is enabled, also include 75 dark A+ checks.
    """
    display_name = "Darksanity"


class Warpzonesanity(Toggle):
    """Add five warp zone completion checks and five warp zone access items.
    Worlds 2–5 also need their World Access and entrance light-level access.
    """
    display_name = "Warpzonesanity"


class Bandagesanity(Toggle):
    """Add one bandage check in each light level (75 additional checks)."""
    display_name = "Bandagesanity"


class Speedsanity(Toggle):
    """Add 75 light A+ checks, plus 75 dark A+ checks when Darksanity is enabled."""
    display_name = "Speedsanity"


class Goal(Choice):
    """All Bosses: defeat all five bosses (ten light clears in each world).
    Beat the Game: reach the ending credits after Dr. Fetus and the escape.
    Only World 5 Access and ten World 5 light unlocks/clears are needed for that route.
    """
    display_name = "Goal"
    option_all_bosses = 0
    option_beat_the_game = 1
    default = 0


class TofuTrapFillerWeight(Range):
    """Percentage of filler items replaced with Tofu Trap (rounded to nearest item).
    0 disables generated traps; 100 replaces all filler. Progression is unchanged.
    """
    display_name = "Tofu Trap Filler Weight"
    range_start = 0
    range_end = 100
    default = 0


@dataclass
class SMB3DOptions(PerGameCommonOptions):
    goal: Goal
    warpzonesanity: Warpzonesanity
    bandagesanity: Bandagesanity
    darksanity: Darksanity
    speedsanity: Speedsanity
    tofu_trap_filler_weight: TofuTrapFillerWeight


class SMB3DWeb(WebWorld):
    tutorials = [Tutorial("Setup", "Install the generator-only prototype.", "English",
                          "setup_en.md", "setup/en", ["SMB3D integration contributors"])]


class SMB3DWorld(World):
    """Unlock light and dark levels across five worlds and defeat every boss."""
    game = GAME
    web = SMB3DWeb()
    options_dataclass = SMB3DOptions
    options: SMB3DOptions
    item_name_to_id = ITEMS
    location_name_to_id = ALL_LOCATIONS
    item_name_groups = {
        "World Access": {f"World {w} Access" for w in range(2, 6)},
        "Warp Zone Access": {f"World {w} Warp Zone Access" for w in range(1, 6)},
        "Light Access": {name for name in ITEMS if name[0].isdigit()},
        "Dark Access": {name for name in ITEMS if name.startswith("Dark ")},
    }
    location_name_groups = {
        "Light Clears": {f"{w}-{n}" for w in range(1, 6) for n in range(1, 16)},
        "Bandages": {f"{w}-{n} Bandage" for w in range(1, 6) for n in range(1, 16)},
        "Dark Clears": {f"Dark {w}-{n}" for w in range(1, 6) for n in range(1, 16)},
        "Bosses": {f"World {w} Boss" for w in range(1, 6)},
        "A+": set(APLUS_LOCATIONS),
        "Warp Zones": set(WARP_LOCATIONS),
    }

    def create_item(self, name):
        classification = (ItemClassification.trap if name == "Tofu Trap" else
                          ItemClassification.filler if name == "Filler" else ItemClassification.progression)
        return SMB3DItem(name, classification, ITEMS[name], self.player)

    def get_filler_item_name(self):
        return "Filler"

    def _location(self, region, name, event=None):
        location = SMB3DLocation(self.player, name, None if event else ALL_LOCATIONS[name], region)
        region.locations.append(location)
        if event:
            location.place_locked_item(SMB3DItem(event, ItemClassification.progression, None, self.player))
        return location

    def create_regions(self):
        menu = Region("Menu", self.player, self.multiworld)
        self.multiworld.regions.append(menu)
        for w in range(1, 6):
            world = Region(f"World {w}", self.player, self.multiworld)
            self.multiworld.regions.append(world)
            menu.connect(world, rule=lambda state, w=w: w == 1 or state.has(f"World {w} Access", self.player))
            for n in range(1, 16):
                light = Region(f"Light {w}-{n}", self.player, self.multiworld)
                self.multiworld.regions.append(light)
                world.connect(light, rule=lambda state, w=w, n=n:
                              w == 1 or state.has(f"{w}-{n} Access", self.player))
                self._location(light, f"{w}-{n}")
                if self.options.bandagesanity:
                    self._location(light, f"{w}-{n} Bandage")
                self._location(light, f"Event: Light {w}-{n} Cleared", clear_event(w, n))
                if self.options.speedsanity:
                    self._location(light, f"{w}-{n} A+")
                if self.options.darksanity:
                    dark = Region(f"Dark {w}-{n}", self.player, self.multiworld)
                    self.multiworld.regions.append(dark)
                    world.connect(dark, rule=lambda state, w=w, n=n:
                                  state.has(f"Dark {w}-{n} Access", self.player))
                    self._location(dark, f"Dark {w}-{n}")
                    if self.options.speedsanity:
                        self._location(dark, f"Dark {w}-{n} A+")
            if self.options.warpzonesanity:
                warp = Region(f"World {w} Warp Zone Region", self.player, self.multiworld)
                self.multiworld.regions.append(warp)
                world.connect(warp, rule=lambda state, w=w:
                              state.has(f"World {w} Warp Zone Access", self.player)
                              and (w == 1 or state.has(f"{w}-{WARP_ENTRANCE_LEVELS[w]} Access", self.player)))
                self._location(warp, f"World {w} Warp Zone")
            boss = Region(f"World {w} Boss Arena", self.player, self.multiworld)
            self.multiworld.regions.append(boss)
            world.connect(boss, rule=lambda state, w=w:
                          sum(state.has(clear_event(w, n), self.player) for n in range(1, 16))
                          >= BOSS_REQUIREMENT)
            self._location(boss, f"World {w} Boss")
            self._location(boss, f"Event: World {w} Boss Defeated", boss_event(w))
        if self.options.goal == Goal.option_beat_the_game:
            escape = Region("Final Escape", self.player, self.multiworld)
            self.multiworld.regions.append(escape)
            self.multiworld.get_region("World 5 Boss Arena", self.player).connect(
                escape, rule=lambda state: state.has(boss_event(5), self.player))
            self._location(escape, "Event: Ending Credits", "Ending Credits Reached")
            self.multiworld.completion_condition[self.player] = lambda state: state.has(
                "Ending Credits Reached", self.player)
        else:
            self.multiworld.completion_condition[self.player] = lambda state: all(
                state.has(boss_event(w), self.player) for w in range(1, 6))

    def create_items(self):
        pool = [self.create_item(name) for name in active_items(bool(self.options.darksanity), bool(self.options.warpzonesanity)) if name not in {"Filler", "Tofu Trap"}]
        count = len(active_locations(bool(self.options.darksanity), bool(self.options.speedsanity), bool(self.options.bandagesanity), bool(self.options.warpzonesanity)))
        filler_count = count - len(pool)
        trap_count = (filler_count * self.options.tofu_trap_filler_weight.value + 50) // 100
        pool.extend(self.create_item("Tofu Trap") for _ in range(trap_count))
        pool.extend(self.create_item("Filler") for _ in range(filler_count - trap_count))
        self.multiworld.itempool.extend(pool)

    def fill_slot_data(self):
        return {
            "protocol_version": 2,
            "world_count": 5,
            "levels_per_world": 15,
            "boss_light_clears_required": 10,
            "starting_world": 1,
            "starting_light_levels": [f"1-{n}" for n in range(1, 16)],
            "dark_requires_light_clear": False,
            "goal": self.options.goal.current_key,
            "warpzonesanity": bool(self.options.warpzonesanity),
            "warp_zone_entrance_levels": WARP_ENTRANCE_LEVELS,
            "bandagesanity": bool(self.options.bandagesanity),
            "darksanity": bool(self.options.darksanity),
            "speedsanity": bool(self.options.speedsanity),
            "tofu_trap_filler_weight": self.options.tofu_trap_filler_weight.value,
            "item_ids": active_items(bool(self.options.darksanity), bool(self.options.warpzonesanity)),
            "location_ids": active_locations(bool(self.options.darksanity), bool(self.options.speedsanity), bool(self.options.bandagesanity), bool(self.options.warpzonesanity)),
        }

