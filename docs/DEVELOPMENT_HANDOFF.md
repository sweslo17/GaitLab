# GaitLab 開發交接 — 2026-10-29

此檢查點位於 `develop`。先讀本文，再讀 AGENTS.md、VALIDATION.md 與 docs/FEATURE_STATUS.md。尚未做生物力學準確度驗證，不要把程式測試或公開資料執行成功當成跑姿準確度。

## 接續指令

```bash
git fetch origin
git switch develop
git pull --ff-only origin develop
poetry install
poetry run bash scripts/bootstrap.sh
poetry run bash scripts/verify_local.sh
flutter build apk --debug --target-platform android-arm64
flutter devices
```

已有未提交修改時，先保存再切換分支。不要重匯入舊 ZIP，也不要覆蓋 Android 前景服務。

## 已完成的程式

- v0.5：個人節奏目標、步頻與品質時間、間隔變異、幅度／規律性、七份匯出。
- v0.6：第一段與最後一段各30秒的條件式比較、缺值說明及窄螢幕支援。不是疲勞診斷。
- v0.7：Android health 前景服務、CPU partial wake lock、關屏錄製、通知停止並儲存、寫檔 flush 競爭修正。iOS 仍限前景。
- v0.8：實驗性動作狀態時間軸、加速度／角速度 RMS 趨勢、後腰中央的選用方向校正、三向平方幅度分布、完整新分析 JSON 匯出。未區分已驗證的走／跑，也不估計骨盆角度。
- 公開資料：取得並核對多個來源，2309次 production Dart replay；結果與不相容／排除條件見 docs/DATASET_VALIDATION_2026-10-28.md。部分試驗沒有逐步答案，部分負向對照與計數評分不佳；沒有為了結果調整 detector。
- 新增 Android/iOS runner 原始碼與 lock files。SDK 路徑、簽章、編譯產物、下載資料及個人原始錄製不進 Git。

## 最後發現及修正的問題

Android 重新訂閱感測器時，第一筆可能是上一段結尾的快取。實機第一筆比新段開始早167.5秒，造成整段分析時間膨脹；94秒受控關屏區間本身仍持續取樣。重現證據保留於 validation/motion_startup_cache_reproduction_2026-10-28.json，整段摘要驗證列為 FAIL。

`SessionStartGate` 現在在同一 App 內接續前段各串流的原生時間戳上限，排除未前進的初始快取。第一次訂閱才比較記錄開始 epoch（允許100ms偏差）。後續排序仍由原本引擎負責，沒有改步數偵測參數。舊加速度保留原值並標 `accepted=0`；舊 gyro 保留原值，時間戳與排除理由記入 summary.json 的 acquisition_startup。

用原始失敗錄製離線重播後，分析時間從321.539841秒改為154.011586秒，分別排除一筆舊加速度與 gyro。相關回歸先失敗，再修正通過。首次 epoch 假設與同一 App native watermark 的範圍已寫入摘要。

## 本機檢查狀態

2026-10-29：`poetry run bash scripts/verify_local.sh` 通過，包含40個 Python 測試、Flutter 靜態分析與84個 Flutter 測試。新快取修正版 Android arm64 debug APK 建置也通過；尚未重新安裝及做實機重測。完整證據以 VALIDATION.md 為準。GitHub CI 推送後才執行，不把本機結果當成 CI 通過。

## 第一個待辦：修正版實機重測

目前手機上的早期 v0.8 不包含最後的啟動快取修正。不要只看0.8.0版本號就認為已是最新 APK，應比對 SHA256。

1. 在 macOS 建立修正版並安裝到使用者解鎖的手機。先確認沒有其他錄製，避免安裝中斷紀錄。
2. 同一 App 連續錄製兩段，確認上一段快取在第二段保留原始資料、但不進入分析。
3. 關屏至少60秒，核對兩個原始串流在該區間的時間戳、取樣量與新動作分箱。
4. 從通知停止並儲存，核對七份檔案、summary 拒絕數、motion duration 與有效原生訊號範圍一致，服務及 CPU lock 已移除。
5. 用 `poetry run python tools/analyze_session.py SESSION --out REPORT.json` 做 QA，再更新 VALIDATION.md。原始 gyro 中已列為啟動快取的事件必須依 acquisition_startup 區分，不要靜默刪除原始檔。

此修正後的實機檢查目前 NOT RUN。舊版本關屏證據、合成單元測試、APK 建置與新版本硬體測試是不同證據。

## 後續研究待辦

- 影片活動區間與參考 IMU／動作捕捉，量測狀態 F1、方向混入與角速度誤差。
- 腰帶重複固定與校正重測，含傾斜、純偏航滑動、起停、轉身及鬆動情境。
- 拔線後長時間錄製與耗電；其他手機；iPhone 的前景錄製。iOS 背景錄製未實作。
- 不增加接地時間、左右腳判定、傷害風險或疲勞分數等沒有獨立參考的答案。

下載研究資料位於 `data/public/`，轉換與重播報告位於 `reports/public/`，兩者均忽略。新電腦需依 PUBLIC_DATASETS.md 與資料集報告重新下載，不能用合成訊號替代。Python dependency 由 Poetry 管理。
