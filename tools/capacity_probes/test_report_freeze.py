import unittest
from report_freeze import adjacent_slopes, estimate


class Slopes(unittest.TestCase):
    def test_nonuniform_tick_spacing_and_paired_sem(self):
        points={0:{'a':0.,'b':.2},2:{'a':.2,'b':.4},10:{'a':.4,'b':.6}}
        result=adjacent_slopes(points)
        self.assertAlmostEqual(result[0]['slope'],.1)
        self.assertAlmostEqual(result[1]['slope'],.025)
        self.assertAlmostEqual(result[0]['sem'],0.)
        self.assertTrue(result[0]['steepest'])
        self.assertFalse(result[1]['steepest'])

    def test_ties_direction_flat_and_single_point(self):
        result=adjacent_slopes({0:{'a':0},2:{'a':1},4:{'a':0}})
        self.assertTrue(all(r['steepest'] for r in result))
        self.assertEqual(result[1]['slope'],-.5)
        self.assertIsNone(result[1]['sem'])
        self.assertFalse(adjacent_slopes({0:{'a':.5},4:{'a':.5}})[0]['steepest'])
        self.assertEqual(adjacent_slopes({0:{'a':.5}}),[])

    def test_unpaired_rejected(self):
        with self.assertRaises(ValueError):
            adjacent_slopes({0:{'a':1},1:{'b':2}})


if __name__=='__main__':
    unittest.main()
