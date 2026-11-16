# 0.1.3：企業簽名 MHA 測試版

此版本依據你在 iOS 26.6.2（23G90）上以企業簽名 3105 成功存取 App 資料的實測，
加入保留原始 MobileHouseArrest 身分的 LaunchServices 只讀存取路徑。
它尚未在這台手機驗證讀到 lsd 快取，也尚未驗證能改變其他 App 的外觀。

## 選擇安裝檔

* [ForceLegacyUIHouseArrest-unsigned.ipa](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.3/ForceLegacyUIHouseArrest-unsigned.ipa)：
  使用你給 3105 簽名的企業簽名方式，保留 `com.apple.mobile.MobileHouseArrest`。
  這個版本與 **3105 使用同一個 Bundle ID，安裝會替換現有 3105，無法同時保留兩個 App**。
  安裝前保留 3105 的原 IPA 與需要的資料。ForceLegacyUI 的新檔案放在
  `Documents/ForceLegacyUI`，不自動清理既有資料。
* [ForceLegacyUI-unsigned.ipa](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.3/ForceLegacyUI-unsigned.ipa)：
  一般 App Group 版本，可沿用先前側載方式，與 3105 共存。
  現在也包含限定路徑的 traversal 後備嘗試及可續掃的 inode 搜尋。

兩個下載檔都需要重新簽名。MHA 版本不要求專用 App Group；其前提是原始 Bundle ID
在簽名後仍保持不變。若工具把它改成 `com.apple.mobile.MobileHouseArrest.你的TeamID`，
程式會顯示身分不符，而不執行 MHA 查詢。

## 安裝後

1. 關閉 Demo laboratory，確認版本為 `0.1.3`。
2. MHA 版的 Diagnostics → Access backend 應為 `MobileHouseArrest`。
3. 點 **Run Read-Only Inspection**。此版本會嘗試 lsd 的 class 10／12 容器 lease，
   保留查詢及授權直到讀取結束；後續只開啟符合名稱與大小限制的 LS 快取。
4. 若仍為 0，點 **Extended Store Discovery**。搜尋會辨識容器路徑，
   不必剛好掃中 `.csstore` 檔案的 inode；每次 inode 掃描的時間預算為 20 秒。
5. 若尚未找到，再點同一按鈕會從儲存的 cursor 繼續。日誌會顯示搜尋範圍與下一個 inode。
   **Restart Inode Search** 可重設進度。範圍上限仍為 4,000 萬，達上限後重設；這不是全磁碟完整性的保證。
6. 仍失敗時複製新版完整日誌。MHA 查詢、目錄是否可讀、traversal 後備結果及搜尋進度都會列出。

系統查詢可能使執行時間超出掃描預算。程式不會刪除系統或其他 App 的資料；
實際修改仍需已驗證的快取格式與外觀證據，目前真實寫入 allowlist 為空。

## 為何之前 worse_query 回傳 0 個 App

`worse_query` 上游列出的範圍包含 iOS 26，但不同目錄的可存取性不同。
你提供的 0.1.2 日誌中：

* App Group 已可用；不需要再修正該群組。
* `alternate 6` 表示曾成功消耗 token，接著的 `errno 2` 表示那個指定位置開啟時不存在。
* 父目錄的 `-6` 只表示那幾個查詢未取得 token。
* inode 掃描在 4,319,232 就達到 8 秒上限，未覆蓋設定的 4,000 萬範圍；舊版每次又從頭開始。

0.1.3 改用純字串路徑比較，避免 Foundation 的 `standardizingPath` 依實際檔案系統
改寫 `/private` 前綴而跳過候選；另外納入 3105 使用的 mobile `Data/System` 路徑。
取得 token、找到檔案、通過格式／checksum 驗證，以及觀察到外觀變化，仍是分開檢查的結果。

來源：[3105](https://github.com/YangJiiii/3105/tree/a72617ed4c764a65d8aac1e91aca95231e72a2cb)、
[worse_query](https://github.com/forcequitOS/worse_query/tree/d1540e20cd82b974d891e0551ced6d6aeb570ac2)、
[bad_query](https://github.com/forcequitOS/bad_query/tree/73ef6da1adabef0982fd00e36cb85f21b8f8194a)、
[Apple 路徑處理說明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/ManipulatingPaths.html)。

3105 公開的支援表只列到 26.6.1；你提供的 26.6.2 實測記錄為使用者回報的 App 資料存取結果，
不以公開表格否定該結果，也不把它延伸宣稱為已驗證的 lsd 快取或外觀修改結果。
