"""Tải dữ liệu thời tiết Hà Nội (Open-Meteo Archive, CSV công khai) và đẩy lên raw-data theo từng lô tháng.

Không tải được -> sinh dữ liệu giả lập có tính mùa vụ.
Chạy lại sẽ ghi đè cùng key -> tạo version mới (minh họa versioning + ILM noncurrent).

  python app/ingest.py [--delay GIÂY] [--last N]
    --delay  nghỉ giữa các lô để mô phỏng dữ liệu đổ về liên tục (mặc định 0)
    --last   chỉ đẩy N lô (tháng) cuối cùng
"""
import argparse
import io
import time

import numpy as np
import pandas as pd
import requests

from common import RAW_BUCKET, RAW_PREFIX, S3_ENDPOINT, s3_client

START, END = "2016-01-01", "2025-12-31"
URL = (
    "https://archive-api.open-meteo.com/v1/archive?latitude=21.0285&longitude=105.8542"
    f"&start_date={START}&end_date={END}&timezone=Asia%2FBangkok&format=csv"
    "&daily=temperature_2m_mean,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max"
)
COLUMNS = ["date", "temp_mean", "temp_max", "temp_min", "precipitation", "wind_max"]


def download() -> pd.DataFrame:
    resp = requests.get(URL, timeout=30)
    resp.raise_for_status()
    lines = resp.text.splitlines()
    header = next(i for i, line in enumerate(lines) if line.startswith("time,"))  # bỏ khối metadata đầu file
    df = pd.read_csv(io.StringIO("\n".join(lines[header:])))
    df.columns = COLUMNS
    return df.dropna()


def synthesize() -> pd.DataFrame:
    rng = np.random.default_rng(42)
    dates = pd.date_range(START, END, freq="D")
    doy = dates.dayofyear.to_numpy()
    season = 24 + 6 * np.sin(2 * np.pi * (doy - 105) / 365.25)      # nóng tháng 6-7, lạnh tháng 1
    noise = np.zeros(len(dates))
    for i in range(1, len(dates)):                                   # nhiễu AR(1) cho giống thời tiết thật
        noise[i] = 0.7 * noise[i - 1] + rng.normal(0, 1.2)
    mean = season + noise
    rain_season = 1 + np.sin(2 * np.pi * (doy - 120) / 365.25)
    return pd.DataFrame({
        "date": dates.strftime("%Y-%m-%d"),
        "temp_mean": mean.round(1),
        "temp_max": (mean + 4 + rng.normal(0, 1, len(dates))).round(1),
        "temp_min": (mean - 4 + rng.normal(0, 1, len(dates))).round(1),
        "precipitation": np.maximum(0, rng.gamma(0.6, 8 * rain_season) - 3).round(1),
        "wind_max": np.abs(rng.normal(12, 4, len(dates))).round(1),
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay", type=float, default=0)
    ap.add_argument("--last", type=int, default=0)
    args = ap.parse_args()

    try:
        df, source = download(), "open-meteo-archive"
        print(f"[ingest] Tải Open-Meteo thành công: {len(df)} ngày ({START}..{END})")
    except Exception as exc:  # mạng lỗi / API đổi định dạng
        df, source = synthesize(), "synthetic-seasonal"
        print(f"[ingest] Không tải được dataset ({exc.__class__.__name__}: {exc}) -> dùng dữ liệu giả lập")

    df["month"] = df["date"].str[:7]
    batches = list(df.groupby("month"))
    if args.last:
        batches = batches[-args.last:]

    s3 = s3_client("INGEST_ACCESS_KEY", "INGEST_SECRET_KEY")
    print(f"[ingest] Đẩy {len(batches)} lô lên {S3_ENDPOINT}/{RAW_BUCKET}/{RAW_PREFIX}")
    for n, (month, part) in enumerate(batches, 1):
        key = f"{RAW_PREFIX}{month[:4]}/{month}.csv"
        s3.put_object(
            Bucket=RAW_BUCKET, Key=key, ContentType="text/csv",
            Body=part.drop(columns="month").to_csv(index=False).encode(),
            Metadata={"source": source, "rows": str(len(part))},
        )
        if n % 12 == 0 or n == len(batches):
            print(f"[ingest]   {n}/{len(batches)} lô, mới nhất: {key}")
        if args.delay:
            time.sleep(args.delay)
    print(f"[ingest] Xong: {len(df)} dòng, nguồn={source}")


if __name__ == "__main__":
    main()
