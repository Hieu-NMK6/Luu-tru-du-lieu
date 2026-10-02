"""Cấu hình và tiện ích dùng chung cho ingest/train/predict.

Endpoint lấy từ biến môi trường (ưu tiên) hoặc .env:
  MLFLOW_TRACKING_URI     http://localhost:5000  (site B: 5100)
  MLFLOW_S3_ENDPOINT_URL  http://localhost:9000  (site B: 9100)
"""
import io
import os
import sys
from pathlib import Path

import boto3
import numpy as np
import pandas as pd
from botocore.config import Config
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env", override=False)
os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
sys.stdout.reconfigure(encoding="utf-8")   # console Windows mặc định cp1252

TRACKING_URI = os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000")
S3_ENDPOINT = os.environ.get("MLFLOW_S3_ENDPOINT_URL", "http://localhost:9000")
RAW_BUCKET = "raw-data"
RAW_PREFIX = "weather/hanoi/"
EXPERIMENT = "weather-forecast"
MODEL_NAME = "weather-next-day-temp"

FEATURES = [
    "temp_mean", "temp_max", "temp_min", "precipitation", "wind_max",
    "temp_lag1", "temp_lag2", "temp_lag3", "temp_roll7", "doy_sin", "doy_cos",
]


def s3_client(access_env: str, secret_env: str):
    """S3 client tới MinIO bằng user ứng dụng (không dùng root)."""
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=os.environ[access_env],
        aws_secret_access_key=os.environ[secret_env],
        region_name="us-east-1",
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"},
                      retries={"max_attempts": 3}),
    )


def init_mlflow():
    """Trỏ MLflow client vào tracking server; artifact ghi thẳng lên MinIO bằng user mlflow-app."""
    import mlflow

    os.environ["AWS_ACCESS_KEY_ID"] = os.environ["MLFLOW_APP_ACCESS_KEY"]
    os.environ["AWS_SECRET_ACCESS_KEY"] = os.environ["MLFLOW_APP_SECRET_KEY"]
    os.environ["MLFLOW_S3_ENDPOINT_URL"] = S3_ENDPOINT
    mlflow.set_tracking_uri(TRACKING_URI)
    return mlflow


def load_raw(s3) -> pd.DataFrame:
    """Đọc toàn bộ các lô CSV trong raw-data, gộp và sắp theo ngày."""
    frames = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=RAW_BUCKET, Prefix=RAW_PREFIX):
        for obj in page.get("Contents", []):
            body = s3.get_object(Bucket=RAW_BUCKET, Key=obj["Key"])["Body"].read()
            frames.append(pd.read_csv(io.BytesIO(body), parse_dates=["date"]))
    if not frames:
        raise SystemExit(f"Không có dữ liệu trong {RAW_BUCKET}/{RAW_PREFIX} — chạy 'make ingest' trước")
    df = pd.concat(frames).drop_duplicates("date", keep="last").sort_values("date")
    return df.set_index("date")


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out["temp_lag1"] = out["temp_mean"].shift(1)
    out["temp_lag2"] = out["temp_mean"].shift(2)
    out["temp_lag3"] = out["temp_mean"].shift(3)
    out["temp_roll7"] = out["temp_mean"].rolling(7).mean()
    doy = out.index.dayofyear
    out["doy_sin"] = np.sin(2 * np.pi * doy / 365.25)
    out["doy_cos"] = np.cos(2 * np.pi * doy / 365.25)
    out["target"] = out["temp_mean"].shift(-1)   # nhiệt độ trung bình ngày kế tiếp
    return out
