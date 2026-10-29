# 公開資料驗證：2026-10-28

本次保留正式 `GaitEngine` 及參數不變。資料轉換留在 `tools/`，原始下載與衍生 CSV 留在 git 忽略的 `data/public/`，完整逐筆結果在 `reports/public/`。摘要另存 `validation/dataset_benchmark_2026-10-28.json`。

## 取得與重播

| 來源 | 實際取得與重播 | 能驗證的範圍 |
|---|---|---|
| AZI350 | 固定 commit 全檔下載，651 blobs 核對；646 筆感測試驗全部重播 | 手機活動與位置壓力測試，沒有步數答案 |
| Running_IMU | 兩個 MAT 與來源說明下載，Git blob 核對；173 段下背訊號全部重播 | 800 Hz 短片段訊號測試，不能評逐步準確度 |
| Apple Watch | 完整 ZIP，官方 MD5 與全部 CRC 通過；469 段腰部訊號，468 重播成功、1 失敗 | 衍生加速度訊號測試，測力板只涵蓋局部接觸 |
| Harvard／Baker | 完整 ZIP，官方 MD5 與全部 CRC 通過；657 段 OG／OUT 重播成功 | 跨環境訊號測試，這些段落沒有測力板答案 |
| Clemson | 完整同步 Data.zip 與原始 RawData.zip，CRC 通過；90 段髖部訊號重播 | 88 段可比較影片參考總步數；15 Hz 屬超出預期範圍的壓力測試 |
| WalkRec | 完整固定版本 ZIP，CRC 通過；142 段手機訊號，77 人 | 對照腿部手機演算法及來源修正步數，不是全部人工影片答案 |
| Cambridge | 官方完整檔下載、MD5 核對；132 段全部重播 | 117 段有影片參考步數及有效標註區間 |

共重播 2,309 段，2,308 段執行成功，1 段因原始時間問題拒絕。325 段可做具明示限制的參考步數比較。

**重播 PASS 只代表工具完成讀取與執行，不代表步數準確。** 未執行實機腰帶測試、逐步事件 F1 或商店發布。沒有因驗證結果而調整引擎參數。

## 已發現的問題

### 活動負控制不通過

AZI350 的 82 筆 sitting 中有 26 筆產生候選事件，共 105 次。86 筆 standing 中有 32 筆產生候選事件，共 154 次。大部分事件在試驗中段，延長暖機不能單獨消除問題。活動標籤不能精確界定每次假陽性，但已顯示目前單一坐著範例不足以代表整體表現。

79 筆 running 的候選步數中位數為 35，76 筆 walking 為 31。沒有參考答案，不能算準確率。放桌面的試驗也有 running／walking 標籤，不能把其零候選步數解釋為漏步。

AZI350 原始 449,899 列中有 210 列全零加速度。轉換記錄來源列號並排除這些初始化佔位列，原檔不變。其餘 449,689 列進入引擎。README 未明列單位，m/s² 含重力的解釋是明示假設，原始模長約 9.8 提供支持。

### Clemson 步數比較

參考答案只計 `left/right` 完整步，另列 `leftshift/rightshift`。包含引擎暖機的整段時間一起評分，不刪除開頭來改善分數。

| 活動 | 可評分試驗 | 參考步數 | 候選步數 | 每試驗絕對百分比誤差中位數 | 加權絕對誤差 |
|---|---:|---:|---:|---:|---:|
| Regular | 29 | 30,425 | 30,240 | 0.55% | 0.82% |
| SemiRegular | 30 | 19,917 | 20,844 | 3.97% | 6.66% |
| Irregular | 29 | 5,139 | 4,908 | 10.95% | 13.21% |

加權絕對誤差是 `sum(abs(預測−參考)) / sum(參考)`。它不讓不同試驗的多算與漏算互相抵銷。這些是髖部研究感測器的走路資料，不能宣稱後腰手機跑步達到相同準確度。

P010 Regular 及 P019 Irregular 的 shift 參考索引超出訊號列數。完整步索引仍在範圍內，但來源區間可能不一致，因此兩筆保留訊號重播、整筆停止準確度評分。沒有自行猜時間偏移。來源同步訊號約為 g，轉換乘以 9.80665；15 Hz 低於目前品質門檻，不插值成 100 Hz 掩蓋限制。原始 HTTP 取得沒有官方 checksum，另記錄本地 SHA256 及 ZIP CRC。

### Cambridge 步數比較

132 份原始串流全部重播，117 份可比較影片參考總步數。另 14 份缺實驗步數、1 份缺對應攜帶位置的走路區間，保留訊號但不評分。

參考 9,122 步，標註區間內產生 9,177 次候選事件。加權絕對誤差 3.32%，每試驗絕對百分比誤差中位數 1.56%。直接合併的有號誤差僅 +0.60%，會掩蓋試驗間的漏步與多算，因此不作主要指標。

完整訊號先送入引擎，以保留開始走路前的暖機。只計算標註走路區間內的候選事件。來源未明確指定索引起點與端點包含方式；四種邊界組合的敏感度檢查對 117 份資料都產生相同步數。手機放口袋、手持或包包，資料只有走路，不能推論後腰手機跑步準確度。

### WalkRec 步數比較

完整 142 段、77 人，2,350,516 個樣本全部重播。原始 ACC 輸出有 36,900 對時間逆序；衍生輸入按原生奈秒時間排序，沒有重採樣，原始 ZIP 不變。無重複時間。來源明列加速度單位 m/s²、包含重力。

15 段 NOTES 的 corrected GT 與合併腿部 @GT 列數不同，停止對這些段落的步數評分。另外 7 段參考峰谷超出主手機的紀錄時間，因此也停止評分。其餘 120 段比較為參考 11,545、預測 12,720，加權絕對誤差 11.89%，每段絕對百分比誤差中位數 7.35%。一段零參考步數仍產生 54 次候選事件。時間範圍容差採來源取樣間隔中位數加上 1 ms，明列於 manifest。

參考來自腿部手機峰谷演算法及來源修正，並非每筆都有人工影片答案。不能把對這組參考的誤差宣稱為後腰手機跑步準確率。沒有使用主手機自身的 @main_GT 當答案。

### Running_IMU 與高頻輸入限制

OptoJump MAT 只有左右 stance／stride 時長，沒有完整接觸時間或區間步數；資料階層也沒有受試者 ID。173 段每段約 1.3–3.4 秒，0.6 秒暖機占比高。無法做受試者保留測試或逐步配對。

800 Hz 時，引擎自相關的頻率上限 220 Hz 與固定樣本視窗會改變實際延遲／時間範圍。此次保留原始輸入揭露限制，沒有把品質等級當成生物力學驗證。

### Zenodo 來源與表示法

Apple 原檔有移除重力的 `userAcceleration` 與 `gravity`。衍生輸入為 `(userAcceleration + gravity) × 9.80665`，明確標示不是原生 raw。`apple_0086.csv` 有一筆不遞增時間，重播拒絕整段並回傳 FAIL，沒有靜默刪除。

Apple 網頁 API、論文／GitHub 與 ZIP 的數量和授權描述不一致。API 描述 757／584、CC0；論文／GitHub 描述 492／395、CC BY 4.0。實際 ZIP 有 469 waist、490 wrist、810 force CSV，未找到宣稱的 manifest／alignment log／data dictionary。保留來源歸屬且不重新散布資料，先停止接觸事件評分。

Harvard 的 9,390 段測力板 stride 視窗保留於原始 ZIP，沒有串成連續訊號。OG／OUT 的骨盆資料以物理尺度 m/s² 解釋，但 README 未明列單位，manifest 記錄尚未獨立確認，因此只做探索重播。

## 重現方式

Python 使用 Poetry。新增 NumPy／SciPy 是為讀取 MATLAB 研究檔；手機應用程式沒有新增依賴。已安裝的環境可離線執行轉換與測試。

```bash
poetry install
poetry run bash scripts/verify_local.sh
poetry run python tools/inspect_running_imu.py --export
poetry run python tools/inspect_zenodo.py
poetry run python tools/prepare_zenodo_replay.py
poetry run python tools/prepare_clemson.py
poetry run python tools/prepare_walkrec.py
poetry run python tools/prepare_cambridge.py
poetry run python tools/normalize_azi350.py

dart run tools/replay_normalized.dart reports/public/running_imu_replay_inputs.json reports/public/running_imu_replay.json
dart run tools/replay_normalized.dart reports/public/zenodo_replay_manifest.json reports/public/zenodo_replay.json
dart run tools/replay_normalized.dart reports/public/clemson_replay_inputs.json reports/public/clemson_replay.json
dart run tools/replay_normalized.dart reports/public/walkrec_inputs.json reports/public/walkrec_replay.json
dart run tools/replay_normalized.dart reports/public/azi350_replay_inputs.json reports/public/azi350_replay.json
dart run tools/replay_normalized.dart reports/public/cambridge_replay_inputs.json reports/public/cambridge_replay.json
poetry run python tools/prepare_cambridge.py --check-windows reports/public/cambridge_replay.json
poetry run python tools/summarize_benchmarks.py
```

上述命令需要已下載原始檔；轉換工具遇到檔案遺失會失敗，沒有合成資料替代。每份 manifest 保留來源版本、雜湊、轉換與評分限制。Zenodo 重播預期 exit 1，因 Apple 原檔時間問題。其餘資料集的退出狀態與最新測試數見 `VALIDATION.md` 本次紀錄。

## 來源

- [AZI350](https://github.com/AZI350/Smartphone-IMU-Three-Positions-Dataset)：commit `348768b8034ccd7d01d696cd62cc1d673a34a186`。
- [Running_IMU](https://github.com/MyriamLubrano/Running_IMU)：commit `9eb366966caf008d62ecc3675b11fd1c48978ec2`。
- [Apple Watch](https://zenodo.org/records/17376717)：官方 ZIP MD5 `cc354ea010f622572a24ccd3e6dfd5a9`。
- [Harvard／Baker](https://zenodo.org/records/16541185)：官方 ZIP MD5 `d0ede3df73a04279e31e98a699bde86d`。
- [Clemson](http://cecas.clemson.edu/~ahoover/pedometer/)：Data.zip SHA256 `ce37832d5e234f6f014193a3a2af2f3162ab90905f303d473849512d690885da`。
- [WalkRec](https://gitlab.citius.gal/fernando.estevez/walking-recognition-dataset)：commit `2878087e552c48ee867bb5bf78c2998929496f96`。
- [Cambridge](https://www.repository.cam.ac.uk/items/8c12b8d3-86fd-4817-9f76-8316c96f675d)：官方 MD5 `e745f874cf15e15e5a3c0141b296647c`。本機 DNS 失敗後，用公開 DNS 解析並保留官方 TLS 主機名下載。
