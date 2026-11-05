import json
import unittest

from BaseClasses import CollectionState
from Fill import distribute_items_restrictive
from test.general import setup_multiworld, setup_solo_multiworld
from .. import SMB3DWorld
from ..data import ITEMS, LOCATIONS, boss_event


class TestSMB3D(unittest.TestCase):
    def setUp(self):
        self.multiworld = setup_multiworld(SMB3DWorld, seed=123, options={'darksanity': True, 'bandagesanity': True})
        self.world = self.multiworld.worlds[1]
        self.state = CollectionState(self.multiworld)

    def grant(self, name):
        self.state.collect(self.world.create_item(name))
        self.state.sweep_for_advancements()

    def reachable(self, name):
        self.state.sweep_for_advancements()
        return self.multiworld.get_location(name, 1).can_reach(self.state)

    def test_counts_and_ids(self):
        network = [loc for loc in self.multiworld.get_locations() if loc.address is not None]
        self.assertEqual(len(network), 230)
        self.assertEqual(len(self.multiworld.itempool), 230)
        self.assertEqual(sum(item.name == "Filler" for item in self.multiworld.itempool), 91)
        self.assertEqual(len(set(ITEMS.values())), len(ITEMS))
        self.assertEqual(len(set(LOCATIONS.values())), 230)
        self.assertEqual(len(self.world.location_name_groups["Bosses"]), 5)
        self.assertEqual(len(self.world.fill_slot_data()["starting_light_levels"]), 15)
        json.dumps(self.world.fill_slot_data())

    def test_start_and_dark_world_one(self):
        for n in range(1, 16):
            self.assertTrue(self.reachable(f"1-{n}"))
            self.assertTrue(self.reachable(f"1-{n} Bandage"))
            self.assertFalse(self.reachable(f"Dark 1-{n}"))
        self.assertTrue(self.reachable("World 1 Boss"))
        self.assertFalse(self.reachable("2-1"))
        self.grant("Dark 1-1 Access")
        self.assertTrue(self.reachable("Dark 1-1"))
        self.assertFalse(self.reachable("Dark 1-2"))

    def test_light_needs_world_and_individual_item(self):
        self.grant("2-1 Access")
        self.assertFalse(self.reachable("2-1"))
        self.assertFalse(self.reachable("2-1 Bandage"))
        self.grant("World 2 Access")
        self.assertTrue(self.reachable("2-1"))
        self.assertTrue(self.reachable("2-1 Bandage"))
        self.assertFalse(self.reachable("2-2"))
        self.assertFalse(self.reachable("Dark 2-1"))

    def test_dark_needs_world_but_not_light_item(self):
        self.grant("Dark 3-4 Access")
        self.assertFalse(self.reachable("Dark 3-4"))
        self.grant("World 3 Access")
        self.assertTrue(self.reachable("Dark 3-4"))
        self.assertFalse(self.reachable("3-4"))
        self.assertFalse(self.reachable("Dark 3-5"))

    def test_boss_exactly_ten_same_world_light_levels(self):
        self.grant("World 2 Access")
        for n in range(1, 16):
            self.grant(f"Dark 2-{n} Access")
        for n in range(1, 10):
            self.grant(f"2-{n} Access")
        self.assertFalse(self.reachable("World 2 Boss"))
        # Other worlds and all 15 dark clears still cannot supply the tenth clear.
        self.grant("World 3 Access")
        for n in range(1, 16):
            self.grant(f"3-{n} Access")
        self.assertFalse(self.reachable("World 2 Boss"))
        self.grant("2-15 Access")
        self.assertTrue(self.reachable("World 2 Boss"))

    def test_goal_requires_fifth_boss(self):
        for name in ITEMS:
            if name not in {"World 5 Access", "Filler"}:
                self.grant(name)
        self.assertFalse(self.multiworld.completion_condition[1](self.state))
        for w in range(1, 5):
            self.assertTrue(self.state.has(boss_event(w), 1))
        self.grant("World 5 Access")
        self.assertTrue(self.multiworld.completion_condition[1](self.state))

    def test_actual_fill_solo_and_multiworld(self):
        for players, seeds in ((1, range(20)), (2, range(5))):
            for seed in seeds:
                with self.subTest(players=players, seed=seed):
                    multiworld = setup_multiworld([SMB3DWorld] * players, seed=seed)
                    distribute_items_restrictive(multiworld)
                    self.assertFalse(multiworld.get_unfilled_locations())
                    self.assertTrue(multiworld.can_beat_game())
                    self.assertTrue(multiworld.fulfills_accessibility())
