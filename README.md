# SMB 掛載管理器 (SMB Mount Manager)

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)
![Swift 5](https://img.shields.io/badge/Swift-5.0-orange.svg)
![Release 1.1.0](https://img.shields.io/badge/Release-1.1.0-brightgreen.svg)
![License MIT](https://img.shields.io/badge/License-MIT-green.svg)

> **SMB 掛載管理器** 是一個專為 macOS 設計的強大開源常駐選單列工具。經過深度重構的 v1.1.0 版本，不僅帶來了極致穩定的無縫掛載體驗，更內建了 **企業級的高速背景下載引擎**，讓您的 NAS 傳輸體驗獲得史無前例的進化。

## 🌟 核心特色 (v1.1.0 重磅升級)

- **⚡ 高速並發下載引擎 (Download Manager)**：
  - **斷線自動續傳**：無論是更換 Wi-Fi 或是網路斷線，當伺服器重新連線時，所有下載中斷的任務（包含大型資料夾內的數千個檔案）都會**自動接力續傳**。
  - **多線程並發下載**：支援大型資料夾批次下載，背景採用資料互斥鎖 (`NSLock`) 與畫面節流器 (Throttler)，即使一次下載上萬個檔案，CPU 佔用率依然極低且絕不崩潰。
  - **精準的進度控制**：支援任務的「全部暫停」、「全部開始」與「全部刪除」，提供最高優先權的「防彈跳機制 (Anti-Bounce)」，確保您的操作絕對精準。
- **🛡 筆電休眠喚醒防護 (Watchdog & Sleep Protection)**：
  - macOS 會在筆電闔上蓋子時強制切斷網路。本軟體會監聽系統的 `willSleepNotification`，在斷網前一秒鐘主動「切斷所有下載連線」並「解除背景掛載阻塞」，徹底解決 macOS **Watchdog 凍結誤殺** 與 **Libdispatch C 語言級死鎖閃退**。
- **🎯 幽靈卡死防護 (Ghost .DS_Store Blocker)**：
  - 徹底解決 Finder 偷塞 `.DS_Store` 隱藏設定檔導致掛載點看似被佔用而落入「無限連線中」的鬼打牆問題。
- **🌐 智慧網路環境限制 (SSID & Interface Restrictions)**：
  - 自訂每個掛載點的可用網路！您可以設定「僅在公司 Wi-Fi 或插上實體網路線 (Ethernet) 時自動掛載 NAS」，離開公司時自動暫停，節省系統資源。
- **🔑 桌面捷徑與自動清理機制**：
  - 掛載成功時可將資料夾捷徑釘選在桌面，網路斷開時瞬間自動隱藏。

## 📥 安裝與執行

### 從 Release 下載安裝 (推薦)
1. 前往本專案的 [Releases](https://github.com/imstevelin/smbmountmanager/releases) 頁面。
2. 下載最新的 `SMB掛載管理器.zip` (v1.1.0)。
3. 解壓縮後將 `SMB掛載管理器.app` 拖曳至您的「應用程式 (Applications)」資料夾。
4. **推薦動作**：首次開啟時，進入「設定」>「系統服務」點擊「安裝修復程式」，以獲得針對 `/Volumes` 資料夾的最高穩定性與權限修復。

### 開發者 自行編譯
```bash
# 1. 複製專案
git clone https://github.com/imstevelin/smbmountmanager.git
cd smbmountmanager

# 2. 開啟 Xcode 專案
open SMBMountManager.xcodeproj
```
* **環境要求**：macOS 14.0 或以上版本，Xcode 15 或以上版本。

## 🧠 專業架構與穩定性設計

* **AppLifecycle & AppDelegate**：安全處理 App 啟動、終止、睡眠 (Sleep) 與喚醒 (Wake) 時的 TCP Socket 關閉與狀態保存。
* **DownloadManager (MainActor)**：全新導入的下載排程中心。負責調度佇列任務，與底層 `ChunkDownloader` (AMSMB2) 溝通，透過 **屬性安全合併 (Merge)** 解決異步封包造成的資料競爭 (Data Race) 閃退。
* **MountManager (MainActor)**：主控台，負責儲存全域設定並統籌 `MountEngine`。針對斷線解掛操作 (`umount`) 皆強制封裝於 `Task.detached` 中，**保證絕對不阻塞 UI 與觸發 Watchdog**。

## 🤝 貢獻與反饋
我們非常歡迎任何形式的貢獻！如果您遇到 Bug，或是希望加入新功能，請開啟 **Issue** 或發起 **Pull Request**。

## 📄 授權協議
本專案採用 **MIT License**。您可以自由地使用、修改與散佈此軟體，詳情請見 [LICENSE](LICENSE) 檔案。
