# ForceLegacyUI 0.1.3 安裝與「找不到 App」排查

若你已在 iOS 26.6.2 上用企業簽名 3105 成功存取資料，請先看
[MHA 企業測試版教程](ENTERPRISE-MHA.zh-Hant.md)。該版本與 3105 使用相同 Bundle ID，安裝會替換 3105。

目前這是研究版。可以列出可見的 App、讀取診斷，以及測試備份與還原；
**尚未驗證能把其他已安裝 App 的外觀恢復成 iOS 18。真實快取寫入仍預設禁用。**

## 先更新 IPA

一般版直接下載：[ForceLegacyUI 0.1.3 IPA](https://github.com/Justintunsday/ForceLegacyUI/releases/download/v0.1.3/ForceLegacyUI-unsigned.ipa)。
下載後仍須用你的側載工具重新簽名。

也可以從建置紀錄取得：

1. 打開 [GitHub Actions](https://github.com/Justintunsday/ForceLegacyUI/actions/workflows/build.yml)，
   選擇版本為 **0.1.3** 的成功建置。
2. 登入 GitHub，在該次執行頁面的 **Artifacts** 下載壓縮檔。
3. 解壓縮後，使用 `dist/ForceLegacyUI-unsigned.ipa`。另外兩個 `CompatibilityProbe` 是對照測試 App。
4. 用原本的側載工具更新 ForceLegacyUI。保留 App Groups 權限，讓工具用你的帳戶重新簽名並配置描述檔。
5. 打開 **Diagnostics**，確認 **App version** 顯示 `0.1.3`。

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

0.1.3 的延伸搜尋會從容器路徑找快取，並儲存 inode 進度；再按同一按鈕會接續搜尋，
不會一直重掃前 8 秒。每次 inode 掃描的預算改為 20 秒，另有目錄搜尋及系統查詢時間。
日誌中的 `Inode checkpoint` 顯示下次起點；**Restart Inode Search** 可以重設進度。

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
