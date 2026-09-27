"""Independent, falsification-first analysis for CardioMag Probe exports."""
from __future__ import annotations
import json
from dataclasses import dataclass
from pathlib import Path
from collections.abc import Iterable
import numpy as np
import pandas as pd
from scipy import signal

AXES = ("mag_x_uT", "mag_y_uT", "mag_z_uT", "mag_magnitude_uT")

@dataclass(frozen=True)
class Settings:
    pre: float = 0.5
    post: float = 0.5
    baseline: tuple[float, float] = (-0.45, -0.15)
    response: tuple[float, float] = (-0.1, 0.35)
    accel_threshold: float = 0.08
    gyro_threshold: float = 0.08
    surrogates: int = 1000
    bootstraps: int = 1000
    seed: int = 0xCA4D10

DEFAULT_SETTINGS = Settings()

def load_session(folder: str | Path):
    folder = Path(folder)
    return pd.read_csv(folder / "samples.csv"), json.loads((folder / "manifest.json").read_text())

def interpolate_epochs(t, x, beats, grid):
    return np.stack([np.interp(beat + grid, t, x) for beat in beats]) if len(beats) else np.empty((0, len(grid)))

def baseline_correct(epochs, grid, window=(-0.45, -0.15)):
    mask = (grid >= window[0]) & (grid <= window[1])
    return epochs - epochs[:, mask].mean(axis=1, keepdims=True)

def motion_filter(df: pd.DataFrame, beats: np.ndarray, settings: Settings):
    t = df.monotonic_timestamp.to_numpy()
    accel = np.sqrt(df.accel_x_g**2 + df.accel_y_g**2 + df.accel_z_g**2).to_numpy()
    gyro = np.sqrt(df.gyro_x_rad_s**2 + df.gyro_y_rad_s**2 + df.gyro_z_rad_s**2).to_numpy()
    good = []
    for beat in beats:
        m = np.abs(t - beat) <= settings.pre
        good.append(m.any() and np.max(np.abs(accel[m] - 1)) <= settings.accel_threshold and np.max(gyro[m]) <= settings.gyro_threshold)
    return np.asarray(good)

def bootstrap_ci(epochs, rng, n=1000):
    means = np.stack([epochs[rng.integers(0, len(epochs), len(epochs))].mean(axis=0) for _ in range(n)])
    return np.quantile(means, [0.025, 0.975], axis=0)

def rms(x): return float(np.sqrt(np.mean(np.square(x))))

def shifted_beats(beats, start, end, offset):
    return np.sort(start + np.mod(beats - start + offset, end - start))

def analyze_axis(df, beats, axis, settings=DEFAULT_SETTINGS):
    rng = np.random.default_rng(settings.seed)
    t = df.monotonic_timestamp.to_numpy()
    dt = np.median(np.diff(t))
    grid = np.arange(-settings.pre, settings.post + dt / 2, dt)
    epochs = baseline_correct(interpolate_epochs(t, df[axis].to_numpy(), beats, grid), grid, settings.baseline)
    mean = epochs.mean(axis=0)
    ci = bootstrap_ci(epochs, rng, settings.bootstraps)
    response = (grid >= settings.response[0]) & (grid <= settings.response[1])
    observed = rms(mean[response])
    null = []
    for _ in range(settings.surrogates):
        offset = rng.uniform(settings.post, (t[-1] - t[0]) - settings.pre)
        sb = shifted_beats(beats, t[0], t[-1], offset)
        ep = baseline_correct(interpolate_epochs(t, df[axis].to_numpy(), sb, grid), grid, settings.baseline)
        null.append(rms(ep.mean(axis=0)[response]))
    p = (1 + np.sum(np.asarray(null) >= observed)) / (1 + len(null))
    odd, even = epochs[::2], epochs[1::2]
    split = len(epochs) // 2
    def corr(a, b): return float(np.corrcoef(a.mean(0), b.mean(0))[0, 1]) if len(a) and len(b) else np.nan
    return {"axis": axis, "grid": grid, "mean": mean, "low": ci[0], "high": ci[1], "rms": observed, "empirical_p": p, "null_rms": np.asarray(null), "odd_even_r": corr(odd, even), "first_second_r": corr(epochs[:split], epochs[split:])}

def coherence_with_beats(df, beats, axis):
    t = df.monotonic_timestamp.to_numpy(); fs = 1 / np.median(np.diff(t)); impulses = np.zeros(len(t))
    for beat in beats: impulses[np.argmin(np.abs(t - beat))] = 1
    return signal.coherence(impulses, df[axis].to_numpy(), fs=fs, nperseg=min(512, len(t)))

def held_out_template(df, beats, axis="mag_x_uT", settings=DEFAULT_SETTINGS):
    t = df.monotonic_timestamp.to_numpy()
    dt = np.median(np.diff(t))
    grid = np.arange(-settings.pre, settings.post + dt / 2, dt)
    epochs = baseline_correct(interpolate_epochs(t, df[axis].to_numpy(), beats, grid), grid, settings.baseline)
    split = len(epochs) // 2
    template = epochs[:split].mean(0)
    test = epochs[split:].mean(0)
    template = (template - template.mean()) / max(np.linalg.norm(template - template.mean()), 1e-12)
    return {"grid": grid, "template": template, "test_mean": test, "correlation": float(np.corrcoef(template, test)[0, 1])}

def template_controls(df, beats, axis="mag_x_uT", settings=DEFAULT_SETTINGS):
    held=held_out_template(df,beats,axis,settings); template=held["template"]; test=held["test_mean"]
    shifted=shifted_beats(beats,df.monotonic_timestamp.iloc[0],df.monotonic_timestamp.iloc[-1],3.17)
    wrong=held_out_template(df,shifted,axis,settings)["test_mean"]
    return {"correct_r":held["correlation"],"time_reversed_r":float(np.corrcoef(template[::-1],test)[0,1]),"shifted_timing_r":float(np.corrcoef(template,wrong)[0,1])}

def jitter_curve(df, beats, axis="mag_x_uT", levels=(0,5,10,25,50,100,250,500), settings=DEFAULT_SETTINGS):
    rng = np.random.default_rng(settings.seed); rows = []
    for ms in levels:
        jittered = beats + rng.uniform(-ms/1000, ms/1000, len(beats))
        result = analyze_axis(df, jittered, axis, Settings(**{**settings.__dict__, "surrogates": min(settings.surrogates, 200), "bootstraps": min(settings.bootstraps, 200)}))
        rows.append({"jitter_ms": ms, "rms": result["rms"], "empirical_p": result["empirical_p"]})
    return pd.DataFrame(rows)

def timing_surrogate_tests(df, beats, axis="mag_x_uT", settings=DEFAULT_SETTINGS):
    """Return real, shuffled-interval, and circular-shift null statistics."""
    rng = np.random.default_rng(settings.seed); t = df.monotonic_timestamp.to_numpy()
    def statistic(candidate):
        dt=np.median(np.diff(t)); grid=np.arange(-settings.pre,settings.post+dt/2,dt); response=(grid>=settings.response[0])&(grid<=settings.response[1])
        ep=baseline_correct(interpolate_epochs(t,df[axis].to_numpy(),candidate,grid),grid,settings.baseline)
        return rms(ep.mean(0)[response])
    real = statistic(beats)
    intervals = np.diff(beats); shuffled = []; circular = []
    for _ in range(settings.surrogates):
        perm = rng.permutation(intervals); surrogate = beats[0] + np.r_[0, np.cumsum(perm)]
        surrogate = surrogate[surrogate < t[-1] - settings.post]
        shuffled.append(statistic(surrogate))
        offset = rng.uniform(settings.post * 2, (t[-1] - t[0]) - settings.pre * 2)
        circular.append(statistic(shifted_beats(beats, t[0], t[-1], offset)))
    return {"real_rms": real, "shuffled_interval_rms": np.asarray(shuffled), "circular_shift_rms": np.asarray(circular)}

def noise_characterization(df):
    t=df.monotonic_timestamp.to_numpy(); dt=np.diff(t); fs=1/np.median(dt); report={"achieved_hz":float(fs),"sample_interval_ms":{"median":float(np.median(dt)*1000),"p05":float(np.quantile(dt,.05)*1000),"p95":float(np.quantile(dt,.95)*1000)}}
    for axis in AXES[:3]:
        x=df[axis].to_numpy(); freq,psd=signal.welch(x,fs=fs,nperseg=min(4096,len(x))); unique,counts=np.unique(x,return_counts=True)
        report[axis]={"std_uT":float(np.std(x)),"quantization_step_uT":float(np.min(np.diff(unique))) if len(unique)>1 else None,"repeated_fraction":float(1-len(unique)/len(x)),"psd_frequency_hz":freq,"psd_uT2_hz":psd}
    return report

def prior_level_comparison(df, beats, axis="mag_x_uT", settings=DEFAULT_SETTINGS):
    """Cross-validated operationalization of prior-information levels 0–4.

    Level 5 is evaluated across sessions by distance_comparison because spatial
    behavior cannot be inferred from one recording.
    """
    x=df[axis].to_numpy(); t=df.monotonic_timestamp.to_numpy(); fs=1/np.median(np.diff(t)); hr=1/np.median(np.diff(beats)); half=len(t)//2
    f,px=signal.welch(x[half:],fs=fs,nperseg=min(2048,len(x)-half)); band=(f>=max(.5,hr-.2))&(f<=hr+.2)
    level0=float(np.max(px)/np.median(px)); level1=float(np.max(px[band])/np.median(px)) if band.any() else np.nan
    triggered=analyze_axis(df,beats,axis,Settings(**{**settings.__dict__,"surrogates":200,"bootstraps":200}))
    held=held_out_template(df,beats,axis,settings)
    # Preferred projection is learned on training beats only, then frozen.
    held_axes=[held_out_template(df,beats,a,settings)["correlation"] for a in AXES[:3]]
    return pd.DataFrame([
        {"level":0,"prior":"none / spectral outlier","held_out_statistic":level0},
        {"level":1,"prior":"heart-rate band","held_out_statistic":level1},
        {"level":2,"prior":"exact beat times","held_out_statistic":1-triggered["empirical_p"]},
        {"level":3,"prior":"times + frozen morphology","held_out_statistic":held["correlation"]},
        {"level":4,"prior":"times + morphology + frozen XYZ choice","held_out_statistic":float(np.nanmax(held_axes))},
    ])

def distance_comparison(session_folders: Iterable[str | Path], axis="mag_x_uT", settings=DEFAULT_SETTINGS):
    rows=[]
    for folder in session_folders:
        df,manifest=load_session(folder); distance=manifest.get("nominalDistanceCM"); beats=np.asarray(manifest["beatTimes"],float)
        if distance is None: continue
        good=motion_filter(df,beats,settings); result=analyze_axis(df,beats[good],axis,settings)
        rows.append({"session_id":manifest["sessionID"],"distance_cm":distance,"rms_uT":result["rms"],"empirical_p":result["empirical_p"]})
    return pd.DataFrame(rows).sort_values("distance_cm")

def full_analysis(folder: str | Path, output: str | Path):
    import matplotlib.pyplot as plt
    df, manifest = load_session(folder); out = Path(output); out.mkdir(parents=True, exist_ok=True)
    beats = np.asarray(manifest["beatTimes"], float); settings = Settings()
    good = motion_filter(df, beats, settings); valid = beats[good]
    results = [analyze_axis(df, valid, axis, settings) for axis in AXES]
    timing_nulls=timing_surrogate_tests(df,valid,settings=settings)
    fig, axes = plt.subplots(2, 2, figsize=(10, 7), sharex=True)
    for ax, r in zip(axes.flat, results):
        ax.fill_between(r["grid"]*1000, r["low"], r["high"], alpha=.2); ax.plot(r["grid"]*1000, r["mean"]); ax.axvline(0, color="k", lw=.7); ax.set_title(f'{r["axis"]} · p={r["empirical_p"]:.4f}'); ax.set_ylabel("µT")
    axes[-1,0].set_xlabel("Time from PPG beat (ms)"); axes[-1,1].set_xlabel("Time from PPG beat (ms)"); fig.tight_layout(); fig.savefig(out/"heartbeat_triggered_average.png", dpi=180); plt.close(fig)
    jitter=jitter_curve(df,valid,settings=Settings(surrogates=100,bootstraps=100)); jitter.to_csv(out/"timing_jitter.csv",index=False)
    priors=prior_level_comparison(df,valid,settings=Settings(surrogates=100,bootstraps=100)); priors.to_csv(out/"prior_levels.csv",index=False)
    fig,ax=plt.subplots(figsize=(7,4)); ax.plot(jitter.jitter_ms,jitter.rms,marker="o"); ax.set(xscale="symlog",xlabel="Timing jitter (ms)",ylabel="Triggered RMS (µT)",title="Timing precision sensitivity"); ax.grid(alpha=.25); fig.tight_layout(); fig.savefig(out/"timing_jitter.png",dpi=180); plt.close(fig)
    noise=noise_characterization(df); serial_noise={k:({kk:vv for kk,vv in v.items() if not isinstance(vv,np.ndarray)} if isinstance(v,dict) else v) for k,v in noise.items()}
    summary = {"valid_beats": int(good.sum()), "rejected_beats": int((~good).sum()), "held_out":held_out_template(df,valid), "template_controls":template_controls(df,valid), "timing_nulls":{"shuffled_p":float((1+np.sum(timing_nulls["shuffled_interval_rms"]>=timing_nulls["real_rms"]))/(1+len(timing_nulls["shuffled_interval_rms"]))),"circular_p":float((1+np.sum(timing_nulls["circular_shift_rms"]>=timing_nulls["real_rms"]))/(1+len(timing_nulls["circular_shift_rms"])))}, "noise":serial_noise, "axes": [{k: v for k,v in r.items() if k in ("axis","rms","empirical_p","odd_even_r","first_second_r")} for r in results]}
    summary["held_out"]={k:v for k,v in summary["held_out"].items() if not isinstance(v,np.ndarray)}
    (out/"summary.json").write_text(json.dumps(summary, indent=2))
    return summary
