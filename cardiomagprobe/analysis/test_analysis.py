import unittest
import numpy as np
import pandas as pd
from cardiomag_analysis import Settings, analyze_axis, held_out_template, shifted_beats


def fixture(duration=90, fs=50, heart_rate=72, amplitude=0.08, interval_sd=0.045, seed=7):
    """A biphasic beat-locked waveform in white + drift + folded-line noise, beat times known.

    A TEST FIXTURE of known construction, not a validation of the analysis's sensitivity.
    """
    rng = np.random.default_rng(seed); t = np.arange(0, duration, 1 / fs)
    beats = np.cumsum(rng.normal(60 / heart_rate, interval_sd, int(duration * heart_rate / 60) + 10))
    beats = beats[(beats > 1) & (beats < duration - 1)]
    n = len(t)
    noise = rng.normal(0, .035, n) + np.cumsum(rng.normal(0, .0007, n)) + .008 * np.sin(2 * np.pi * 10 * np.arange(n) / fs)
    injected = sum(amplitude * (np.exp(-((t - b - .10) / .045) ** 2) - .45 * np.exp(-((t - b - .22) / .075) ** 2)) for b in beats)
    return pd.DataFrame({"monotonic_timestamp": t, "mag_x_uT": noise + injected}), beats


class AnalysisTests(unittest.TestCase):
    def test_shift_preserves_count_and_bounds(self):
        x=shifted_beats(np.array([1.,2.,3.]),0,4,2.5); self.assertEqual(len(x),3); self.assertTrue(np.all((x>=0)&(x<4)))
    def test_injection_recovery(self):
        df,beats=fixture(); r=analyze_axis(df,beats,"mag_x_uT",Settings(surrogates=100,bootstraps=100)); self.assertLess(r["empirical_p"],.05)
    def test_held_out_template(self):
        df,beats=fixture(); r=held_out_template(df,beats); self.assertGreater(r["correlation"],.7)


if __name__ == "__main__": unittest.main()
