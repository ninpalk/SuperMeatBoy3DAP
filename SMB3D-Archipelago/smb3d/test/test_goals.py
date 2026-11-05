import unittest
from BaseClasses import CollectionState
from Fill import distribute_items_restrictive
from test.general import setup_multiworld
from .. import SMB3DWorld

class TestGoals(unittest.TestCase):
    def test_short_goal_requires_world5_and_ten_levels(self):
        m=setup_multiworld(SMB3DWorld,seed=72,options={'goal':'beat_the_game'})
        w=m.worlds[1];state=CollectionState(m)
        for n in range(1,11):state.collect(w.create_item(f'5-{n} Access'))
        state.sweep_for_advancements()
        self.assertFalse(m.completion_condition[1](state))
        state.collect(w.create_item('World 5 Access'));state.sweep_for_advancements()
        self.assertTrue(m.completion_condition[1](state))
        for world in (2,3,4):self.assertFalse(state.has(f'World {world} Access',1))
        self.assertTrue(state.has('Ending Credits Reached',1))
        m=setup_multiworld(SMB3DWorld,seed=73,options={'goal':'beat_the_game'})
        w=m.worlds[1];state=CollectionState(m);state.collect(w.create_item('World 5 Access'))
        for n in range(1,10):state.collect(w.create_item(f'5-{n} Access'))
        state.sweep_for_advancements();self.assertFalse(m.completion_condition[1](state))
    def test_default_still_requires_other_bosses(self):
        m=setup_multiworld(SMB3DWorld,seed=74,options={})
        w=m.worlds[1];state=CollectionState(m);state.collect(w.create_item('World 5 Access'))
        for n in range(1,11):state.collect(w.create_item(f'5-{n} Access'))
        state.sweep_for_advancements();self.assertFalse(m.completion_condition[1](state))
        self.assertEqual(w.fill_slot_data()['goal'],'all_bosses')
    def test_generation_both_goals_and_speedsanity(self):
        for goal in ('all_bosses','beat_the_game'):
            for speed in (False,True):
                m=setup_multiworld(SMB3DWorld,seed=75,options={'goal':goal,'speedsanity':speed})
                self.assertEqual(len(m.itempool),155 if speed else 80)
                self.assertEqual(m.worlds[1].fill_slot_data()['goal'],goal)
                self.assertEqual(m.worlds[1].fill_slot_data()['protocol_version'],2)
                distribute_items_restrictive(m)
                self.assertTrue(m.can_beat_game());self.assertTrue(m.fulfills_accessibility())
