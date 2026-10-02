"""Huấn luyện RandomForest dự báo nhiệt độ trung bình ngày kế tiếp; log param/metric/model vào MLflow."""
import numpy as np
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

from common import (EXPERIMENT, FEATURES, MODEL_NAME, S3_ENDPOINT, TRACKING_URI,
                    build_features, init_mlflow, load_raw, s3_client)

PARAMS = {"n_estimators": 200, "max_depth": 12, "min_samples_leaf": 3, "random_state": 42}
TEST_RATIO = 0.2


def main():
    print(f"[train] MLflow={TRACKING_URI}  S3={S3_ENDPOINT}")
    raw = load_raw(s3_client("RAW_READER_ACCESS_KEY", "RAW_READER_SECRET_KEY"))
    data = build_features(raw).dropna()

    split = int(len(data) * (1 - TEST_RATIO))   # chia theo thời gian, không xáo trộn
    train, test = data.iloc[:split], data.iloc[split:]
    print(f"[train] {len(raw)} ngày dữ liệu; train={len(train)} test={len(test)} "
          f"({test.index[0].date()}..{test.index[-1].date()})")

    model = RandomForestRegressor(n_jobs=-1, **PARAMS).fit(train[FEATURES], train["target"])
    pred = model.predict(test[FEATURES])
    metrics = {
        "mae": mean_absolute_error(test["target"], pred),
        "rmse": float(np.sqrt(mean_squared_error(test["target"], pred))),
        "r2": r2_score(test["target"], pred),
        # baseline "ngày mai = hôm nay" để so sánh
        "baseline_persistence_mae": mean_absolute_error(test["target"], test["temp_mean"]),
    }

    mlflow = init_mlflow()
    mlflow.set_experiment(EXPERIMENT)
    with mlflow.start_run(run_name="rf-next-day-temp") as run:
        mlflow.log_params({**PARAMS, "test_ratio": TEST_RATIO, "n_rows": len(data),
                           "features": ",".join(FEATURES)})
        mlflow.log_metrics(metrics)
        info = mlflow.sklearn.log_model(
            sk_model=model, name="model", registered_model_name=MODEL_NAME,
            input_example=test[FEATURES].head(3),
            # MLflow 3.16 serialize bằng skops: model tự train nên tin cậy đúng kiểu node của cây
            skops_trusted_types=["sklearn.tree._tree.Tree"],
        )
    print("[train] metrics: " + ", ".join(f"{k}={v:.3f}" for k, v in metrics.items()))
    print(f"[train] run_id={run.info.run_id}  model={MODEL_NAME} v{info.registered_model_version}")
    print(f"[train] model_uri={info.model_uri}")


if __name__ == "__main__":
    main()
