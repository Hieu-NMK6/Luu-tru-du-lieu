"""Nạp version mới nhất của model từ MLflow Model Registry và dự báo nhiệt độ ngày mai."""
from datetime import timedelta

from common import (FEATURES, MODEL_NAME, S3_ENDPOINT, TRACKING_URI, build_features,
                    init_mlflow, load_raw, s3_client)


def main():
    print(f"[predict] MLflow={TRACKING_URI}  S3={S3_ENDPOINT}")
    mlflow = init_mlflow()
    versions = mlflow.MlflowClient().search_model_versions(f"name='{MODEL_NAME}'")
    if not versions:
        raise SystemExit(f"Chưa có model '{MODEL_NAME}' trong registry — chạy 'make train' trước")
    latest = max(versions, key=lambda v: int(v.version))
    model = mlflow.pyfunc.load_model(f"models:/{MODEL_NAME}/{latest.version}")
    print(f"[predict] Model {MODEL_NAME} v{latest.version} (run {latest.run_id})")

    feats = build_features(load_raw(s3_client("RAW_READER_ACCESS_KEY", "RAW_READER_SECRET_KEY")))
    last = feats[FEATURES].dropna().tail(1)
    today = last.index[0]
    forecast = float(model.predict(last)[0])

    print("[predict] 7 ngày gần nhất (nhiệt độ TB thực tế, °C):")
    for day, t in feats["temp_mean"].tail(7).items():
        print(f"            {day.date()}  {t:5.1f}")
    print(f"[predict] ==> Dự báo {(today + timedelta(days=1)).date()}: {forecast:.1f} °C")


if __name__ == "__main__":
    main()
