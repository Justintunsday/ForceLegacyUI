# ForceLegacyUI 0.1.8 安裝與「找不到 App」排查

已讀到 App、準備測試修改時，先看 [單 App 實驗教程](SINGLE-APP.zh-Hant.md)。
你的 0.1.4 一般版已成功讀取快取，可沿用目前的 App Group 簽名方式。

若你已在 iOS 26.6.2 上用企業簽名 3105 成功存取資料，請先看
[MHA 企業測試版教程](ENTERPRISE-MHA.zh-Hant.md)。該版本與 3105 使用相同 Bundle ID，安裝會替換 3105。

目前這是研究版。可以列出可見的 App、讀取診斷，以及測試備份與還原；
**尚未驗證能把其他已安裝 App 的外觀恢復成 iOS 18。真實快取寫入仍預設禁用。**

## 先更新 IPA

一般版直接下載：[ForceLegacyUI 0.1.8 IPA](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.8/ForceLegacyUI-unsigned.ipa)。
下載後仍須用你的側載工具重新簽名。

也可以從建置紀錄取得：

1. 打開 [0.1.8（build 10）的成功建置](https://github.com/Justintunsday/ForceLegacyUI/actions/runs/44079799734)。
2. 登入 GitHub，在該次執行頁面的 **Artifacts** 下載壓縮檔。
3. 解壓縮後，使用 `dist/ForceLegacyUI-unsigned.ipa`。另外兩個 `CompatibilityProbe` 是對照測試 App。
4. 用原本的側載工具更新 ForceLegacyUI。保留 App Groups 權限，讓工具用你的帳戶重新簽名並配置描述檔。
5. 打開 **Diagnostics**，確認 **App version** 顯示 `0.1.8`；Technical log 另列 build 10。

檔名中的 `unsigned` 表示沒有 Apple 核發的安裝簽名，仍須由側載工具簽名。
0.1.1 起先以 ad-hoc 簽名攜帶請求的 App Group 資訊，供重新簽名工具讀取；
這個 ad-hoc 簽名本身不會授予真機權限。

0.1.0 的舊產物缺少可執行檔簽名區塊，側載工具無法從簽名中讀到所需的
App Group entitlement。不要繼續用舊產物排查這個問題。

## 你使用 SideStore／AltStore／Sideloadly 時

* **SideStore／AltStore**：匯入新版 IPA，讓工具處理這個 App 請求的 App Groups。
  若有移除額外權限的提示，保留 `com.apple.security.application-groups`。
  工具可能重寫群組名稱；0.1.1 會辨識與 ForceLegacyUI 對應的已改名群組，並核對容器是否真的可用。
* **Sideloadly**：用新版 IPA 重新簽名，避免移除 App Groups。
  若生成的簽名或描述檔仍無這項授權，App 會繼續顯示 `missing`；
  需要使用能配置該群組的描述檔／簽名流程，而不是只修改 plist 字串。

工具可以讀到請求的權限，不代表 Apple 已授權該權限。
實際結果以 App 的 **Diagnostics → App Group signing** 為準。
這些操作只更新 ForceLegacyUI，不要求重裝或重簽你想研究的其他 App。

## 安裝後先看這個畫面

打開 **Diagnostics → App Group signing**：

| 欄位／狀態 | 意義與下一步 |
| --- | --- |
| `Configured` | 原本編譯時設定的群組名稱 |
| `Reported groups` | 從目前簽名或內嵌描述檔讀到的名稱；來源另列在畫面上 |
| `Detected` | 與這個 App 對應、且容器實際可用的群組 |
| `ready` | 原設定群組的容器可用，接著執行只讀檢查 |
| `renamed` | 已找到側載工具改名後的對應群組，接著執行只讀檢查 |
| `missing` | 沒有可用的匹配群組；核對簽名及描述檔的 App Groups 授權 |
| `ambiguous` | 多個對應群組都可用；需明確設定這個 App 專用的一個群組 |

不要改用 SideStore／AltStore 本身的共用群組。程式不會自動挑選不相關的群組。

## 找不到 App 時

1. 關閉 **Demo laboratory**。
2. 點 **Run Read-Only Inspection**。
3. 返回 **Applications**。新版會依序嘗試多種 LaunchServices 列舉方式。
   系統不提供列表、但快取可以讀取時，會嘗試只讀快取後備列舉。
4. 若仍為 0，回到 Diagnostics 點一次 **Extended Store Discovery**。
5. 仍失敗就按 **Copy Diagnostic Log**，提供複製的文字。
   其中應包含 Bundle ID、Configured App Group、Reported groups、Group state，
   以及每一個列舉方式的原始記錄數和可見 App 數。

0.1.4 參考 [ForceDuoApp 1.2](https://github.com/34306/ForceDuoApp/releases/tag/1.2)，
改從新建暫存檔的 inode 附近向下搜尋，不再從低位逐一向上掃。
每次會重查最近區段並接續較舊的進度，時間預算為 20 秒，另有目錄搜尋及系統查詢時間。
日誌中的 `Inode outcome` 顯示下次起點；**Restart Inode Search** 可以重設進度。
取得 token 後仍須成功以只讀方式開啟目錄；第一組旗標無效時會釋放 token 並重試另一組。

如果你的日誌已顯示 `Group state: renamed; selected: ...`，表示側載改名後的群組容器已可用，
不用繼續更改群組設定。`0 raw records` 與 `Mapped store candidates: 0` 是下一層的存取／搜尋問題。

0.1.2 開始修正了這個情況下直接結束搜尋的遺漏：一般檢查會補試已知 lsd 位置；延伸檢查會
嘗試限定的系統容器目錄，僅列舉符合條件的 `Library/Caches`，時間預算 10 秒，
最多 256 個候選目錄；0.1.3 納入 mobile Data/System 路徑，仍無結果才做分段 inode 搜尋。
系統查詢本身可能需要額外時間。這些路徑不保證在每個 iOS build 上可存取。

新版日誌也會包含完整 iOS 版本／build、掃描模式、每個查詢與授權結果。
`Grant ... -5` 表示容器查詢被拒絕；`-6` 表示沒有取得 token；
`-4` 表示專用群組的快取設定被拒絕，例如 Caches 非空。程式會保留該目錄內容，請勿刪除系統容器資料。
若所有授權都被拒絕，這條路徑在目前裝置上仍不可用，不能靠重複刷新保證解決。

0.1.1 曾把 `iPhone17,3` 之類的機型代號顯示在 Architecture；0.1.2 改讀目前執行檔的
Mach-O CPU 架構。這項修正避免後續架構比對錯誤，但不會自行開啟快取權限或真實寫入。

`ready/renamed` 只證明 App Group 容器可用，不證明 worse_query 的系統快取授權成功。
後續仍可能因 OS 限制、查詢被拒絕或未知資料格式而無法讀取。

只讀快取後備結果會標示 `Read-only cache registrations`，
其 SDK 會保持 `unavailable`；程式不會猜測 SDK 位移，也不將快取登記當成目前安裝狀態的保證。

## 已讀到 App，但不能修改

0.1.4 的使用者日誌已顯示：一般 App Group 版在 26.6.2（23G90）找到一般名稱的 LS
快取、成功開啟目錄、通過系統 checksum／格式驗證，並讀出 134 筆登記。
這個結果表示搜尋與讀取已成功，並不等於寫入權限或 SDK 欄位已驗證。
0.1.4 沒有可用格式且真實寫入被整體禁用。0.1.5 改為在裝置上核對候選格式與獨立 SDK，
通過後才可開啟單 App 實驗；仍不會在缺少證據時強制解除按鈕。

0.1.5 的後續日誌確認快取仍可讀，但 12 次 App Bundle 開啟均回報 `errno 2`，獨立 SDK 數為 0。
0.1.6 補上同 UUID 容器的實際名稱解析、Info.plist／執行檔讀取失敗後的授權重試，以及
完整路徑、grant 和候選尺寸日誌。執行檔 SDK 與快取欄位狀態會分開顯示。
這些修正尚待真機檢驗；[單 App 教程](SINGLE-APP.zh-Hant.md#有-app-清單但-sdk-仍是-unavailable) 說明各行日誌的意義。

0.1.6 後續回報已讀到自身 SDK，其他 Bundle 仍被 `EPERM` 和兩組 `-6` 擋住。
0.1.7 在 Bundle 讀取也接上 traversal 後備，包括同 UUID 及固定 Bundle 根目錄的授權嘗試。
你後來提供的 ZIP 顯示這兩個後備仍回報 `-104`（沒有 token）。0.1.8 因此加入另一組
上游旗標重試，並根據實際快照加入 23G90／arm64 的 572 格式候選。只有一份 native SDK
時可顯示候選快取值；寫入仍須三個 App／兩種 SDK 的獨立觀察。尚未驗證新旗標能改善真機存取。

若 0.1.5 的候選格式仍未通過，要進一步核對這個 build 的欄位，需要實際快取內容；
只有 Technical log 的 hash 與登記數不足以決定欄位：

1. 關閉 **Demo laboratory**，執行 **Run Read-Only Inspection**。
2. 點 **Save Report and Raw Snapshot**。
3. 在 iPhone 的「檔案」App 找到 **ForceLegacyUI → Diagnostics → 最新資料夾**。
4. 取出 `report.json`、`snapshot.csstore`，以及用來核對的 `snapshot.sha256`。

0.1.5 的 **Share Report and Snapshot** 會分享包含上述三檔的 ZIP，可直接使用。
0.1.4 的 **Share Report** 仍只分享 `report.json`，需從「檔案」附上原始快取。
MHA 版的相同資料夾多一層 `ForceLegacyUI`。原始快取可包含 App 登記等私人 metadata，
可先自行檢查再提供。

分析後仍須核對真實 SDK 欄位、產生只改指定欄位的 dry run，才可接通單一 App 的
實驗寫入與備份還原。出現相容性 key 字串不表示可以把那段字串直接當成 Boolean 修改。

## 測試已完成的 Demo 功能

1. **Diagnostics → Demo laboratory** 開啟。
2. 回 **Applications**，選一個 Sample。
3. 保持 **Dry run** 開啟，點 **Preview Changes**。
4. 預覽成功後，關閉 **Dry run**，再點 **Apply Changes**。
5. Sample 的 SDK 應變成 `18.0.0`。
6. 到 **Restore**，點這筆備份的 **Restore Original Configuration**。

此流程只改 App 自己的合成資料。其他已安裝 App 的外觀不會因此改變。

## 手動簽名工作流

若已有包含正確 App Group 的描述檔，可使用倉庫的 GitHub Actions 手動簽名。
所需證書、描述檔及 Secrets 設定見 [BUILDING.md](BUILDING.md)。
`FLAppGroupIdentifier`、簽名中的 `com.apple.security.application-groups`、
以及描述檔允許的群組必須相容；只有字串相同但未授權仍然無法使用。

參考：[Apple App Groups 說明](https://developer.apple.com/documentation/xcode/configuring-app-groups)、
[Apple 描述檔建立說明](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/)、
[SideStore 的重新簽名流程](https://github.com/SideStore/SideStore/blob/develop/SideStore/Core/Operations/PipelineOperations/ResignAppOperation.swift)。
