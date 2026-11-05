import itertools
import unittest
from BaseClasses import CollectionState
from Fill import distribute_items_restrictive
from test.general import setup_multiworld
from .. import SMB3DWorld

class TestSanities(unittest.TestCase):
    def test_all_combinations_both_goals(self):
        for dark,bandage,speed,goal in itertools.product((False,True),(False,True),(False,True),('all_bosses','beat_the_game')):
            with self.subTest(dark=dark,bandage=bandage,speed=speed,goal=goal):
                m=setup_multiworld(SMB3DWorld,seed=103,options={'darksanity':dark,'bandagesanity':bandage,'speedsanity':speed,'goal':goal,'tofu_trap_filler_weight':25})
                w=m.worlds[1];data=w.fill_slot_data()
                expected=80+75*dark+75*bandage+(75+75*dark)*speed
                progression=64+75*dark
                self.assertEqual(len(m.itempool),expected)
                self.assertEqual(sum(l.address is not None for l in m.get_locations()),expected)
                self.assertEqual(sum(i.advancement for i in m.itempool),progression)
                self.assertEqual(sum(i.name.startswith('Dark ') for i in m.itempool),75*dark)
                self.assertEqual(sum(n.startswith('Dark ') for n in data['location_ids']),75*dark*(1+speed))
                self.assertEqual(sum(n.endswith(' Bandage') for n in data['location_ids']),75*bandage)
                self.assertEqual(sum(n.endswith(' A+') for n in data['location_ids']),(75+75*dark)*speed)
                self.assertEqual(sum(n.startswith('Dark ') for n in data['item_ids']),75*dark)
                filler=expected-progression
                self.assertEqual(sum(i.name=='Tofu Trap' for i in m.itempool),(filler*25+50)//100)
                state=CollectionState(m)
                self.assertTrue(m.get_location('1-1',1).can_reach(state))
                if speed:self.assertTrue(m.get_location('1-1 A+',1).can_reach(state))
                if dark:
                    self.assertFalse(m.get_location('Dark 1-1',1).can_reach(state))
                    state.collect(w.create_item('Dark 1-1 Access'))
                    self.assertTrue(m.get_location('Dark 1-1',1).can_reach(state))
                    state.collect(w.create_item('Dark 2-1 Access'))
                    self.assertFalse(m.get_location('Dark 2-1',1).can_reach(state))
                    state.collect(w.create_item('World 2 Access'))
                    self.assertTrue(m.get_location('Dark 2-1',1).can_reach(state))
                    if speed:self.assertTrue(m.get_location('Dark 2-1 A+',1).can_reach(state))
                distribute_items_restrictive(m)
                self.assertTrue(m.can_beat_game());self.assertTrue(m.fulfills_accessibility())
    def test_default_is_light_levels_and_bosses_only(self):
        m=setup_multiworld(SMB3DWorld,seed=104,options={})
        data=m.worlds[1].fill_slot_data()
        self.assertEqual(len(data['location_ids']),80)
        self.assertFalse(data['darksanity']);self.assertFalse(data['bandagesanity']);self.assertFalse(data['speedsanity'])
