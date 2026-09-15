import unittest
import numpy as np
from cardiomag_analysis import Settings, analyze_axis, held_out_template, shifted_beats
from synthetic_validation import synthetic_dataset

class AnalysisTests(unittest.TestCase):
    def test_shift_preserves_count_and_bounds(self):
        x=shifted_beats(np.array([1.,2.,3.]),0,4,2.5); self.assertEqual(len(x),3); self.assertTrue(np.all((x>=0)&(x<4)))
    def test_injection_recovery(self):
        df,beats=synthetic_dataset(duration=90,amplitude=.08); r=analyze_axis(df,beats,"mag_x_uT",Settings(surrogates=100,bootstraps=100)); self.assertLess(r["empirical_p"],.05)
    def test_held_out_template(self):
        df,beats=synthetic_dataset(duration=90,amplitude=.08); r=held_out_template(df,beats); self.assertGreater(r["correlation"],.7)

if __name__ == "__main__": unittest.main()

