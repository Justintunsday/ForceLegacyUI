# 0.1.7：企業簽名 MHA 測試版

本次發佈為 **0.1.7，build 9**；[建置與驗證紀錄](VALIDATION.md)。
一般 App Group 版已在使用者 0.1.4 日誌中成功讀到快取；已有該結果時可繼續使用一般版。
0.1.5 的 [單 App 實驗](SINGLE-APP.zh-Hant.md) 另要求至少三份可讀的 Bundle／SDK 證據；MHA 身分不會豁免這個條件。

此版本依據你在 iOS 26.6.2（23G90）上以企業簽名 3105 成功存取 App 資料的實測，
加入保留原始 MobileHouseArrest 身分的 LaunchServices 只讀存取路徑。
它尚未在這台手機驗證讀到 lsd 快取，也尚未驗證能改變其他 App 的外觀。

## 選擇安裝檔

* [ForceLegacyUIHouseArrest-unsigned.ipa](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.7/ForceLegacyUIHouseArrest-unsigned.ipa)：
  使用你給 3105 簽名的企業簽名方式，保留 `com.apple.mobile.MobileHouseArrest`。
  這個版本與 **3105 使用同一個 Bundle ID，安裝會替換現有 3105，無法同時保留兩個 App**。
  安裝前保留 3105 的原 IPA 與需要的資料。ForceLegacyUI 的新檔案放在
  `Documents/ForceLegacyUI`，不自動清理既有資料。
* [ForceLegacyUI-unsigned.ipa](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.7/ForceLegacyUI-unsigned.ipa)：
  一般 App Group 版本，可沿用先前側載方式，與 3105 共存。
  現在也包含限定路徑的 traversal 後備嘗試及可續掃的 inode 搜尋。

兩個下載檔都需要重新簽名。MHA 版本不要求專用 App Group；其前提是原始 Bundle ID
在簽名後仍保持不變。若工具把它改成 `com.apple.mobile.MobileHouseArrest.你的TeamID`，
程式會顯示身分不符，而不執行 MHA 查詢。

## 安裝後

1. 關閉 Demo laboratory，確認版本為 `0.1.7`。MHA 版桌面名稱為 **ForceLegacyUI MHA**。
2. MHA 版的 Diagnostics → Access backend 應為 `MobileHouseArrest`。
3. 點 **Run Read-Only Inspection**。此版本會嘗試 lsd 的 class 10／12 容器 lease，
   保留查詢及授權直到讀取結束；後續只開啟符合名稱與大小限制的 LS 快取。
4. 若仍為 0，點 **Extended Store Discovery**。搜尋會辨識容器路徑，
   不必剛好掃中 `.csstore` 檔案的 inode；每次 inode 掃描的時間預算為 20 秒。
5. 0.1.4 參考 ForceDuoApp 1.2，從 App 自己新建暫存檔的 inode 附近向下搜尋，
   不再從 16 開始掃。有效暫存檔 inode 可超過舊的 4,000 萬上限；無法取得時才用該值作後備起點。
   再點同一按鈕會重查最近區段並接續較舊的進度。日誌中的 `Inode outcome` 顯示時間限制與下一個起點；
   **Restart Inode Search** 可重設進度。這是有界限的搜尋策略，不保證覆蓋整個磁碟。
6. 仍失敗時複製新版完整日誌。MHA 查詢、目錄是否可讀、traversal 後備結果及搜尋進度都會列出。

## 0.1.3 的 API unavailable 與帶前綴的快取

0.1.3 把物件啟用與手動 token 流程的必要函式混在一起檢查，導致缺少手動函式時，
也提早跳過了 MHA 物件路徑。0.1.4 分別判斷這些能力：MHA 查詢不強制要求可選的
`set_part` 或手動 token 函式；物件啟用後仍以只讀開啟確認目錄是否可用。
手動消耗 token 則要求對應 release 函式可用，並從明確的系統 dylib 補試符號查找。
這次也修正先前載入的錯誤函式名稱，改用實際的 `container_query_operation_set_part`
與 `container_query_operation_set_part_domain`。這能修正程式提前跳過後備流程的問題，
仍須由新日誌確認該裝置的查詢及讀取結果。

新版日誌會列出 `MHA lookup symbols`、`MHA object activation symbols`、
`Manual token symbols` 和 `Traversal query symbols`，缺少的函式會直接列出名稱。
單一流程不可用不代表所有存取方法都不可用。

你的 0.1.3 日誌還觀察到 `SystemDataOnly-com.apple.LaunchServices-…-v2.csstore`。
其完整目錄用途與內容尚未驗證。0.1.4 支援將單一可讀的帶前綴快取作為**只讀診斷來源**：
仍須通過檔案、大小、格式與 checksum 檢查；不以檔名推定它是完整 App 清單。
這個來源的 SDK 規劃、寫入與還原會被拒絕，即使匯入 profile 也一樣。
延伸搜尋仍會繼續找一般名稱的快取，不會因找到帶前綴來源就停止。

如果只讀到帶前綴來源，Diagnostics 的 **Cache source** 會標示用途未驗證。
App 數量可能仍是 0；請提供新日誌中的符號清單、`MHA lsd class` 與讀取／驗證結果。

## 批量 App API 回傳 0 時的清單後備來源

MHA 版會再嘗試 class-2 的**資料容器登記 metadata**列舉，最多 4,096 個唯一 ID；
這個查詢不啟用容器權限，也不讀寫其他 App 的資料檔案。
接著最多對 512 個已取得的 ID 個別查詢 LaunchServices，補上實際回傳的名稱、Bundle 路徑與 SDK。
沒有回傳的欄位仍顯示 unavailable，不把資料容器路徑當成 App Bundle 路徑。

Diagnostics 的 App list source 會標示 `MCM app-data registrations + individual LS lookups`。
資料登記可能殘留，並不保證目前仍安裝；清單也不保證完整。
這個清單可與快取搜尋各自得到結果，因此快取存取失敗時仍可能看到部分登記項目。

系統查詢可能使執行時間超出掃描預算。程式不會刪除系統或其他 App 的資料；
單 App SDK 實驗需通過其獨立格式、SDK、預覽及寫入驗證；批量操作仍需後續外觀證據。

## 為何之前 worse_query 回傳 0 個 App

`worse_query` 上游列出的範圍包含 iOS 26，但不同目錄的可存取性不同。
你提供的 0.1.2 日誌中：

* App Group 已可用；不需要再修正該群組。
* `alternate 6` 表示曾成功消耗 token，接著的 `errno 2` 是 ENOENT；該指定路徑沒有成功開啟，不能推論裝置上沒有快取。
* 父目錄的 `-6` 只表示那幾個查詢未取得 token。
* inode 掃描在 4,319,232 就達到 8 秒上限，未覆蓋設定的 4,000 萬範圍；舊版每次又從頭開始。

0.1.3 改用純字串路徑比較，避免 Foundation 的 `standardizingPath` 依實際檔案系統
改寫 `/private` 前綴而跳過候選；另外納入 3105 使用的 mobile `Data/System` 路徑。
取得 token、找到檔案、通過格式／checksum 驗證，以及觀察到外觀變化，仍是分開檢查的結果。

來源：[ForceDuoApp 1.2](https://github.com/34306/ForceDuoApp/releases/tag/1.2)、
[3105](https://github.com/YangJiiii/3105/tree/a72617ed4c764a65d8aac1e91aca95231e72a2cb)、
[worse_query](https://github.com/forcequitOS/worse_query/tree/d1540e20cd82b974d891e0551ced6d6aeb570ac2)、
[bad_query](https://github.com/forcequitOS/bad_query/tree/73ef6da1adabef0982fd00e36cb85f21b8f8194a)、
[Apple 路徑處理說明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/ManipulatingPaths.html)。

3105 公開的支援表只列到 26.6.1；你提供的 26.6.2 實測記錄為使用者回報的 App 資料存取結果，
不以公開表格否定該結果，也不把它延伸宣稱為已驗證的 lsd 快取或外觀修改結果。
