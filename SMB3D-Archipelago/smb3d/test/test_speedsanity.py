import unittest
from BaseClasses import CollectionState
from Fill import distribute_items_restrictive
from test.general import setup_multiworld
from .. import SMB3DWorld

class TestSpeedsanity(unittest.TestCase):
    def test_access_and_generation(self):
        for seed in range(10):
            m = setup_multiworld(SMB3DWorld, seed=seed, options={'speedsanity': True, 'darksanity': True, 'bandagesanity': True})
            world = m.worlds[1]
            state = CollectionState(m)
            self.assertEqual(sum(l.address is not None for l in m.get_locations()), 380)
            self.assertEqual(len(m.itempool), 380)
            self.assertEqual(sum(i.name == 'Filler' for i in m.itempool), 241)
            self.assertTrue(world.fill_slot_data()['speedsanity'])
            for w in range(1,6):
                for n in range(1,16):
                    light = m.get_location(f'{w}-{n} A+',1)
                    dark = m.get_location(f'Dark {w}-{n} A+',1)
                    self.assertEqual(light.can_reach(state), w == 1)
                    self.assertFalse(dark.can_reach(state))
            state.collect(world.create_item('2-1 Access'))
            state.collect(world.create_item('Dark 2-1 Access'))
            self.assertFalse(m.get_location('2-1 A+',1).can_reach(state))
            state.collect(world.create_item('World 2 Access'))
            self.assertTrue(m.get_location('2-1 A+',1).can_reach(state))
            self.assertTrue(m.get_location('Dark 2-1 A+',1).can_reach(state))
            distribute_items_restrictive(m)
            self.assertTrue(m.can_beat_game())
            self.assertTrue(m.fulfills_accessibility())
