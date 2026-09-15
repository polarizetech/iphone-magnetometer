"""Inject known heartbeat-locked waveforms into realistic stationary noise."""
from __future__ import annotations
import argparse, json
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from cardiomag_analysis import Settings, analyze_axis

def synthetic_dataset(duration=180, fs=50, heart_rate=72, amplitude=0.02, seed=7):
    rng = np.random.default_rng(seed); t = np.arange(0, duration, 1/fs)
    intervals = rng.normal(60/heart_rate, .045, int(duration*heart_rate/60)+10); beats = np.cumsum(intervals); beats = beats[(beats>1) & (beats<duration-1)]
    noise = signal_noise(rng, len(t), fs)
    injected = sum(amplitude * (np.exp(-((t-b-.10)/.045)**2) - .45*np.exp(-((t-b-.22)/.075)**2)) for b in beats)
    df = pd.DataFrame({"monotonic_timestamp":t,"mag_x_uT":noise+injected,"mag_y_uT":noise*.7,"mag_z_uT":noise*1.2,"mag_magnitude_uT":50+noise+injected,"accel_x_g":0,"accel_y_g":0,"accel_z_g":1,"gyro_x_rad_s":0,"gyro_y_rad_s":0,"gyro_z_rad_s":0})
    return df, beats

def signal_noise(rng, n, fs):
    white = rng.normal(0, .035, n); drift = np.cumsum(rng.normal(0, .0007, n)); mains = .008*np.sin(2*np.pi*10*np.arange(n)/fs)
    return white + drift + mains

def sensitivity_curve(amplitudes, beat_counts=(30,60,120), trials=30, seed=19, surrogate_count=120):
    rows=[]; quick=Settings(surrogates=surrogate_count, bootstraps=min(80,surrogate_count))
    for nbeats in beat_counts:
        for amp in amplitudes:
            detected=0
            for trial in range(trials):
                duration=max(45,nbeats); df, beats=synthetic_dataset(duration=duration, amplitude=amp, seed=seed+trial); beats=beats[:nbeats]
                r=analyze_axis(df, beats, "mag_x_uT", quick); detected += r["empirical_p"] < .0125
            rows.append({"amplitude_uT":amp,"beat_count":nbeats,"detection_probability":detected/trials})
    return pd.DataFrame(rows)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--out", default="example_outputs"); parser.add_argument("--quick", action="store_true"); args=parser.parse_args()
    out=Path(args.out); out.mkdir(parents=True, exist_ok=True)
    # Keep >=80 surrogates even in quick mode so p < .0125 is numerically attainable.
    amps=np.array([0,.005,.01,.02,.04,.08]); curve=sensitivity_curve(amps, trials=3 if args.quick else 30, surrogate_count=100 if args.quick else 1000); curve.to_csv(out/"detection_probability.csv",index=False)
    fig,ax=plt.subplots(figsize=(8,5));
    for count,g in curve.groupby("beat_count"): ax.plot(g.amplitude_uT*1000,g.detection_probability,marker="o",label=f"{count} beats")
    ax.set(xlabel="Injected peak scale (nT)",ylabel="Detection probability",ylim=(-.03,1.03),title="Synthetic recovery in phone-like magnetometer noise"); ax.grid(alpha=.25); ax.legend(); fig.tight_layout(); fig.savefig(out/"synthetic_sensitivity.png",dpi=180); plt.close(fig)
    df,beats=synthetic_dataset(duration=120,amplitude=.02); r=analyze_axis(df,beats,"mag_x_uT",Settings(surrogates=300,bootstraps=300));
    fig,ax=plt.subplots(figsize=(8,4)); ax.fill_between(r["grid"]*1000,r["low"]*1000,r["high"]*1000,alpha=.2,label="95% bootstrap CI"); ax.plot(r["grid"]*1000,r["mean"]*1000,label="Triggered average"); ax.axvline(0,color="k",lw=.7); ax.set(xlabel="Time from beat (ms)",ylabel="nT",title=f"Known 20 nT injection · empirical p={r['empirical_p']:.4f}"); ax.legend(); fig.tight_layout(); fig.savefig(out/"example_recovery.png",dpi=180); plt.close(fig)
    (out/"validation_summary.json").write_text(json.dumps({"injected_amplitude_uT":.02,"beat_count":len(beats),"empirical_p":r["empirical_p"],"rms_uT":r["rms"]},indent=2))

if __name__ == "__main__": main()
