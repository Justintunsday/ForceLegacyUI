# 0.1.8：單一 App SDK 實驗

0.1.5（build 7）加入真正的單 App SDK 寫入路徑。它修改 LaunchServices 的 SDK metadata，
**尚未驗證能把 UIKit／SwiftUI 恢復成 iOS 18 外觀**。找到快取、欄位驗證、取得寫入存取、
寫入後核對，以及畫面是否改變，會分別檢查。

目前版本為 **0.1.8（build 10）**。0.1.6 補上 SDK 讀取的路徑名稱解析、子檔案授權重試與詳細錯誤。
它會在同一個 UUID 容器內核對實際 `.app` 名稱，再讀 Info.plist 與執行檔；
未在真機確認修正效果，未知快取格式仍須獨立驗證。

**已分析你提供的 ZIP，0.1.8 加入 23G90／arm64 的 572-byte 格式候選。**
自身執行檔 SDK `26.2.0` 唯一對應到 payload `0x40`；這仍只有一個獨立觀察。
快照中缺少安裝佔位路徑的系統記錄會排除，非空但損壞的路徑仍拒絕。
有一份新鮮 native 觀察且欄位相符時，清單可顯示 `Cache SDK … · candidate`；
候選值不能選取、不能當作獨立觀察，也不會開啟 Apply。
[欄位與限制紀錄](LAYOUT-572.md)／[候選 JSON](../Layouts/candidate-572-23G90-arm64.json)。

ZIP 內的 0.1.7 日誌顯示 UUID 與固定根目錄 traversal 都回報 `-104`（沒有 token）。
0.1.8 對拒絕／無 token 的 Bundle 查詢加入 `0x800000000` 旗標重試；
尚未在手機驗證此重試能讀到其他執行檔。先沿用目前簽名更新一般版即可。

後續收到的 0.1.8 ZIP 已確認：572 候選成功解碼，134 筆登記都有候選 SDK；
一般版對其他 Bundle 的兩組 traversal 旗標仍都沒有 token，獨立觀察數維持 1。
[實測紀錄](feedback-0.1.8.md)。這時應比較同一企業簽名、保留原始身分的
[MHA 版](ENTERPRISE-MHA.zh-Hant.md)，再判斷存取能力；它尚未證實能解決 Bundle 讀取。

你的 0.1.4 日誌已顯示一般 App Group 版成功讀取 134 筆登記。可沿用目前側載方式，
更新 [一般版 IPA](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.8/ForceLegacyUI-unsigned.ipa)，
保留 App Groups，讓工具重新簽名。無須因這個結果改換 MHA 版。

## 先看驗證結果

1. 關閉 **Demo laboratory**，確認版本為 `0.1.8`（build 10）。
2. 執行 **Run Read-Only Inspection**；需要重新找位置時用 **Extended Store Discovery**。
3. 看 **Independent SDK observations** 與 Technical log。程式最多嘗試 12 個 App Bundle，
   從只讀的 Info.plist 與執行檔 load commands 取得獨立的 build SDK，並核對 Bundle ID。
   SDK 觀察有 8 秒的呼叫間時間預算；同步系統呼叫本身可能更久。
   會優先讀取目前 ForceLegacyUI 自己的實際 Bundle，其他目標依同一 UUID 內的名稱解析。
   個別 LS 查詢的 URL 只作名稱提示，仍須讀到真實檔案並核對 Bundle ID。
4. 程式會核對這次 23G90／arm64 的 572 候選，以及上游公開的 592／604 候選。寫入前，每份候選都必須與本機 OS build、
   架構、真實記錄內容、至少 3 個 App 和 2 種 build SDK 吻合，SDK triple 也不可有歧義。
   記錄大小相同不會單獨啟用寫入。未知格式可匯入經核對的 exact-build profile，再跑相同驗證。
5. 格式與 SDK 證據通過後，程式會嘗試 `O_RDWR` 開啟並讀回同一份快取，**此探測不寫任何位元組**。
   這是存取檢查，真正的 Apply 仍須備份、寫後比對與系統 checksum 驗證。

若候選均被拒絕、獨立觀察不足，或 writable-open probe 失敗，按鈕會保持不可用，日誌會寫明原因。
不會只因你開啟實驗選項就繞過這些檢查。

### 有 App 清單但 SDK 仍是 unavailable

清單只證明快取可讀。0.1.5 的使用者日誌曾顯示 134 筆登記，卻有 12 次 Bundle 開啟
回報 `errno 2`，獨立 SDK 觀察數為 0。只有這份文字無法確定是名稱大小寫、舊 UUID 路徑，
還是授權／解析問題；0.1.6 補上同容器名稱解析及每個失敗階段，便於區分。

* `Bundle SDK ... requested ... cache ...`：列出實際嘗試路徑、檔案階段與 grant 回傳值。
* `Independent executable SDK ... resolved ...`：Info.plist 身分和 Mach-O SDK 已讀到。
* `Candidate ... skipped: required record size ... is absent`：這份快取沒有該候選尺寸，仍需原始快照核對。
* 清單的 `Executable SDK ...; cache field unverified` 只顯示執行檔 SDK；選擇開關仍等待快取欄位驗證。

若仍失敗，使用本頁末尾的 ZIP 匯出流程。保持目前已能讀取快取的 App Group 簽名方式即可。

0.1.6 的後續日誌已確認：自身 SDK `26.2.0` 可讀；其他 UUID 容器回報 `EPERM`，
兩組 worse_query 都未提供 token。0.1.7 因此加入兩個 traversal 後備：先嘗試同一 UUID，
再嘗試固定的 `Bundle/Application` 根目錄授權。後者對照 3105 的 metadata 讀取方式；
實際讀檔仍限於已驗證的目標 UUID、唯一匹配 `.app`、Info.plist 與 Mach-O headers，
每次讀取結束即釋放 handle。尚未驗證能在這台手機取得其他 App 的 SDK。

新日誌中的 `Traversal UUID-container grant`、`Bundle-root traversal` 會顯示後備結果。
`-105` 表示無法先確認既有 nonsymlink 目錄；`-103` 表示查詢無結果；`-104` 表示沒有 token。
非負 handle 仍要成功讀出 native SDK 才算有效；0.1.8 的 572 候選還需三個 App／兩種 SDK 的新鮮觀察，才能進入寫入實驗。

## 一個 App 的預覽與寫入

1. 在 **Diagnostics → Single-app SDK experiment** 開啟 **Enable single-app experiment**。
2. 回 **Applications**，只選一個 App。建議先用 Modern Probe 作為對照實驗。
3. 保持 **Dry run** 開啟，點 **Preview Changes**。核對 App ID、原始 SDK、目標 `18.0.0` 與雜湊。
   此步只在 ForceLegacyUI 自己的 CopyExperiments 資料夾保存原始／候選副本。
4. 保持相同選擇，關閉 **Dry run**，點 **Apply Changes**。
   程式會重新讀取 SDK 證據與快取；若和預覽不一致，要求重做預覽。
5. Apply 先保存原始快取、SDK 值、格式與 metadata 指紋，再只寫選定的 24-byte SDK 欄位及 checksum。
   它保留檔案 inode，完成 fsync、完整候選比對與系統驗證；可證明屬於本次操作的失敗寫入會回滾。

寫入成功後，App 清單應顯示 receipt 核對的當前 SDK。一次實驗後先還原，再進行下一次測試。
程式不會替你終止目標 App 或 lsd。請自行完整關閉被測試 App 再開啟，記錄 UIKit／SwiftUI 的實際畫面。
SDK 變成 18.0.0 仍不代表舊外觀生效。

## 還原

在 **Restore** 選擇本次備份，點 **Restore Original Configuration**。
備份包含原始格式與獨立 SDK 證據；重開 ForceLegacyUI 後仍可使用，不必重新匯入 profile 或再次開啟實驗選項。
還原會重查目標 Bundle 的 Info.plist／load-command 指紋、路徑、SDK 和當前記錄。
App 被重裝／更新、OS build 改變或內容出現無法解釋的差異時會拒絕舊備份覆蓋。
一般還原保留其他新登記；中斷寫入的復原則另要求相同 inode、大小及完整可解釋的差異。

## 驗證未通過時

點 **Save Report and Raw Snapshot**，再點 **Share Report and Snapshot**。
0.1.5 會分享一個 `ForceLegacyUI-evidence.zip`，內含 `report.json`、`snapshot.csstore` 與 `snapshot.sha256`；
報告包含獨立 SDK 觀察，可用來核對欄位。快取若已在檢查後改變，先重新執行 inspection 再匯出。
原始快取可能包含私人 App 登記 metadata，分享前可先自行查看。

分析工具只提供候選欄位與跨記錄的交集，不會產生可強制寫入的 profile，也不會把數字碰巧等於 string key
當成欄位用途的證明。`SystemDataOnly-` 來源仍只供診斷，批量寫入仍不開放。
