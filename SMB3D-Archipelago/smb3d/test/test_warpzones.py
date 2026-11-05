import itertools,unittest
from BaseClasses import CollectionState
from Fill import distribute_items_restrictive
from test.general import setup_multiworld
from .. import SMB3DWorld
from ..data import WARP_ENTRANCE_LEVELS
class TestWarpZones(unittest.TestCase):
    def test_every_warp_requires_its_items_and_host_level(self):
        m=setup_multiworld(SMB3DWorld,seed=130,options={'warpzonesanity':True})
        w=m.worlds[1]
        for world in range(1,6):
            state=CollectionState(m);location=m.get_location(f'World {world} Warp Zone',1)
            self.assertFalse(location.can_reach(state))
            state.collect(w.create_item(f'World {world} Warp Zone Access'))
            if world==1:self.assertTrue(location.can_reach(state));continue
            state.collect(w.create_item(f'{world}-{WARP_ENTRANCE_LEVELS[world]} Access'))
            self.assertFalse(location.can_reach(state))
            state=CollectionState(m);state.collect(w.create_item(f'World {world} Access'))
            state.collect(w.create_item(f'World {world} Warp Zone Access'))
            state.collect(w.create_item(f'{world}-1 Access'))
            self.assertFalse(location.can_reach(state))
            state.collect(w.create_item(f'{world}-{WARP_ENTRANCE_LEVELS[world]} Access'))
            self.assertTrue(location.can_reach(state))
    def test_all_sanity_combinations_with_warps(self):
        for dark,bandage,speed,goal in itertools.product((False,True),(False,True),(False,True),('all_bosses','beat_the_game')):
            m=setup_multiworld(SMB3DWorld,seed=131,options={'warpzonesanity':True,'darksanity':dark,'bandagesanity':bandage,'speedsanity':speed,'goal':goal})
            expected=85+75*dark+75*bandage+(75+75*dark)*speed
            self.assertEqual(len(m.itempool),expected)
            self.assertEqual(sum(i.name.endswith(' Warp Zone Access') for i in m.itempool),5)
            self.assertEqual(sum(i.advancement for i in m.itempool),69+75*dark)
            data=m.worlds[1].fill_slot_data()
            self.assertEqual(sum(n.endswith(' Warp Zone') for n in data['location_ids']),5)
            distribute_items_restrictive(m)
            self.assertTrue(m.can_beat_game());self.assertTrue(m.fulfills_accessibility())
    def test_disabled_has_no_warp_items_or_checks(self):
        m=setup_multiworld(SMB3DWorld,seed=132,options={})
        self.assertEqual(len(m.itempool),80)
        self.assertFalse(any(i.name.endswith(' Warp Zone Access') for i in m.itempool))
        self.assertFalse(any(n.endswith(' Warp Zone') for n in m.worlds[1].fill_slot_data()['location_ids']))
