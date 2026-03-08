# SMB 掛載管理器 (SMB Mount Manager)

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)
![Swift 5](https://img.shields.io/badge/Swift-5.0-orange.svg)
![Release 1.3.4](https://img.shields.io/badge/Release-1.3.4-brightgreen.svg)
![License MIT](https://img.shields.io/badge/License-MIT-green.svg)

> **SMB 掛載管理器** 是一個專為 macOS 設計的強大開源常駐選單列工具。經過連續的版本迭代，最新的 **v1.3.4 版本** 帶來了令人驚豔的 **Apple Liquid Glass UI 設計語言**、深度整合 macOS 的 **Finder 專屬右鍵下載擴充套件**，以及全面平滑化的下載監控體驗，讓您的 NAS 傳輸效率與視覺享受達到前所未有的高度。

## 🌟 核心特色 (v1.3.4 視覺與操作雙重升級)

- **✨ 全新 Apple Liquid Glass 視覺體驗**：
  - **極致美學**：全面導入 Liquid Glass（液態玻璃）設計語言，包含半透明毛玻璃卡片、細膩的景深發光邊框、動畫光澤進度條，以及能在列表滾動時映照出底層內容的動態導航列。
  - **自適應外觀**：完整支援 macOS 淺色 (Light)、深色 (Dark) 與透明 (Tinted) 模式，App Icon 與介面均能隨系統外觀智能切換，完美融入系統生態。

- **⚡ 高速並發下載引擎與 Finder 深度整合**：
  - **Finder 專屬擴充**：選取路徑後，透過滑鼠右鍵「快速動作」選單即可直接呼叫「**SMB 專用下載**」，無縫發起多線程傳輸任務。
  - **智慧監控與管理**：加入 3 秒移動平均演算法的平滑下載網速顯示。一鍵「刪除全部任務」採用並發機制 (Concurrent Processing)，無論多少任務都能瞬間毫秒級清空，徹底告別卡頓。
  - **斷線自動續傳**：無論是更換 Wi-Fi 或是網路斷線，當伺服器重新連線時，所有下載中斷的任務都會**自動接力續傳**。

- **🛡 筆電休眠喚醒防護 (Watchdog & Sleep Protection)**：
  - 完美監聽系統 `willSleepNotification`，在筆電闔上蓋子斷網前主動「切斷下載」並「解除掛載」，徹底解決 macOS Watchdog 誤殺與 Libdispatch 級別的死鎖崩潰問題。

- **🎯 幽靈卡死防護與網路環境限制**：
  - 徹底解決 Finder 偷塞 `.DS_Store` 隱藏設定檔導致的假性佔用無限重連問題。
  - 支援設定「僅在指定 Wi-Fi SSID 或實體網路線 (Ethernet)」下自動掛載，離開指定環境自動暫停，聰明節省資源。

- **🔑 桌面捷徑與選單列智能顯示**：
  - 掛載成功可於桌面釘選資料夾捷徑，網路斷開瞬間隱藏。有下載任務進行時，選單列圖示自動隱藏掛載點數量並展示精緻的圓環進度動畫。

## 📥 安裝與執行

### 從 Release 下載安裝 (推薦)
1. 前往本專案的 [Releases](https://github.com/imstevelin/smbmountmanager/releases) 頁面。
2. 下載最新的 `SMB掛載管理器.zip` (v1.3.4)。
3. 解壓縮後將 `SMB掛載管理器.app` 拖曳至您的「應用程式 (Applications)」資料夾。
4. **推薦動作**：首次開啟時，進入「設定」>「系統服務」點擊「安裝修復程式」，以獲得針對 `/Volumes` 資料夾的最高穩定性與權限修復。

### 開發者 自行編譯
```bash
# 1. 複製專案
git clone https://github.com/imstevelin/smbmountmanager.git
cd smbmountmanager/swift

# 2. 生成並開啟 Xcode 專案 (需安裝 xcodegen)
xcodegen
open SMBMountManager.xcodeproj
```
* **環境要求**：macOS 14.0 或以上版本，Xcode 15 或以上版本。

## 🧠 專業架構與穩定性設計

* **AppLifecycle & AppDelegate**：安全處理 App 啟動、終止、睡眠 (Sleep) 與喚醒 (Wake) 時的 TCP Socket 關閉與狀態保存，並透過 LaunchServices 註冊 Finder NSServices 擴充。
* **DownloadManager (MainActor)**：下載排程中心，負責調度併發任務與底層 `ChunkDownloader` (AMSMB2) 溝通，透過 **TaskGroup 併發模型** 解決大批量任務刪除時的主執行緒阻塞問題。
* **MountManager (MainActor)**：主控台，負責儲存全域設定並統籌 `MountEngine`。針對斷線解掛操作 (`umount`) 皆強制封裝於 `Task.detached` 中，**保證絕對不阻塞 UI 與觸發 Watchdog**。

## 🤝 貢獻與反饋
我們非常歡迎任何形式的貢獻！如果您遇到 Bug，或是希望加入新功能，請開啟 **Issue** 或發起 **Pull Request**。

## 📄 授權協議
本專案採用 **MIT License**。您可以自由地使用、修改與散佈此軟體，詳情請見 [LICENSE](LICENSE) 檔案。
