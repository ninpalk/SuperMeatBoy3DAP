import unittest
from BaseClasses import ItemClassification
from Fill import distribute_items_restrictive
from test.general import setup_multiworld
from .. import SMB3DWorld

class TestTofuTrap(unittest.TestCase):
    def test_pool_counts_and_beatable(self):
        for speedsanity in (False, True):
            for weight in (0, 25, 100):
                with self.subTest(speedsanity=speedsanity, weight=weight):
                    m=setup_multiworld(SMB3DWorld, seed=48+weight, options={
                        'darksanity': True, 'bandagesanity': True, 'speedsanity': speedsanity, 'tofu_trap_filler_weight': weight})
                    total=380 if speedsanity else 230
                    filler=total-139
                    count=(filler*weight+50)//100
                    self.assertEqual(len(m.itempool),total)
                    self.assertEqual(sum(i.name=='Tofu Trap' for i in m.itempool),count)
                    self.assertEqual(sum(i.name=='Filler' for i in m.itempool),filler-count)
                    self.assertEqual(sum(i.advancement for i in m.itempool),139)
                    self.assertEqual(m.worlds[1].create_item('Tofu Trap').classification,ItemClassification.trap)
                    distribute_items_restrictive(m)
                    self.assertTrue(m.can_beat_game())
                    self.assertTrue(m.fulfills_accessibility())
