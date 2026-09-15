import argparse
from cardiomag_analysis import full_analysis

if __name__ == "__main__":
    p=argparse.ArgumentParser(description="Reproduce CardioMag Probe analysis")
    p.add_argument("session", help="Export folder containing samples.csv and manifest.json")
    p.add_argument("--out", default="analysis_output")
    args=p.parse_args(); print(full_analysis(args.session,args.out))

