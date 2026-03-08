# SMB 掛載管理器 (SMB Mount Manager)

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)
![Swift 5](https://img.shields.io/badge/Swift-5.0-orange.svg)
![Release 1.3.0](https://img.shields.io/badge/Release-1.3.0-brightgreen.svg)
![License MIT](https://img.shields.io/badge/License-MIT-green.svg)

> **SMB 掛載管理器** 是一個專為 macOS 設計的強大開源常駐選單列工具。經過連續的版本迭代，全新的 **v1.3.0 版本** 帶來了革命性的 **斷點續傳上傳與下載雙向引擎**、**單調遞增防護的全局進度環**、深度整合 macOS 的 **Finder 專屬右鍵傳輸擴充套件**，以 Apple Liquid Glass UI 的絕美姿態，讓您的 NAS 傳輸效率與視覺享受達到前所未有的高度。

## 🌟 核心特色 (v1.3.0 全新雙向傳輸引擎)

- **⚡ 雙向斷點續傳與 Finder 深度整合**：
  - **右鍵一鍵傳輸**：選取路徑後，透過滑鼠右鍵「快速動作」選單即可直接呼叫「**SMB 專用下載**」或「**SMB 專用上傳**」，無縫發起多線程傳輸任務。
  - **斷點接力續傳**：無論是更換 Wi-Fi 或是網路斷線，當伺服器重新連線或是 App 重啟時，所有傳輸中斷的任務都會**自動保存進度並接力續傳**，再大的檔案也不怕斷線。
  - **智慧監控與高速並發**：利用 macOS 原生 FileHandle 與 Chunk 分頻寫入技術迴避 Kernel 死鎖，確保在極端高速 IO 下 SMB 依然流暢不卡死。

- **✨ 全新 Apple Liquid Glass 視覺體驗**：
  - **極致美學**：全面導入 Liquid Glass（液態玻璃）設計語言，包含半透明毛玻璃卡片、細膩的景深發光邊框、動畫光澤進度條。
  - **完美的單一合併進度環**：精心設計的 **全局單調進度算法 (Monotonic Progress Manager)**，將同時進行的上傳與下載任務容量合併計算，徹底告別進度條「倒退走」或「反覆跳動」的突兀感，給您最絲滑唯美的進度圓環動畫。

- **🛡 筆電休眠喚醒防護 (Watchdog & Sleep Protection)**：
  - 完美監聽系統休眠事件，在筆電闔上蓋子斷網前主動「切斷傳輸」並「暫停任務」，徹底解決 macOS Watchdog 誤殺與 Libdispatch 級別的死鎖崩潰問題。

- **🎯 幽靈卡死防護與網路環境限制**：
  - 徹底解決 Finder 偷塞 `.DS_Store` 隱藏設定檔導致的假性佔用無限重連問題。
  - 支援設定「僅在指定 Wi-Fi SSID 或實體網路線 (Ethernet)」下自動掛載，離開指定環境自動暫停並暫停所有收發任務，聰明節省資源。

## 📥 安裝與執行

### 從 Release 下載安裝 (推薦)
1. 前往本專案的 [Releases](https://github.com/imstevelin/smbmountmanager/releases) 頁面。
2. 下載最新的 `SMB掛載管理器.zip` (v1.3.0)。
3. 解壓縮後將 `SMB掛載管理器.app` 拖曳至您的「應用程式 (Applications)」資料夾。
4. **推薦動作**：首次開啟時，進入「設定」> 點擊「安裝權限修復服務」，以獲得針對 `/Volumes` 資料夾的最高穩定性與權限修復。

### 開發者自行編譯
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

* **檔案傳輸引擎 (ChunkDownloader/ChunkUploader)**：突破了傳統封包傳輸，藉助作業系統已經掛載的底層機制，直接操作 macOS 原生 `FileHandle`，實現低延遲、高吞吐量的斷點續傳。
* **統一會話與進度管理 (TransferProgressManager)**：提前在 Finder 層級解析 `.fileSizeKey` 即時確立分母容量，配合 `activeSessionTaskIDs` 防跳躍鎖定，確保任何時刻都不會造成 UI 狀態撕裂。
* **無阻塞架構**：網路偵測、掛載狀態輪詢、大量任務刪除等高開銷操作全數封裝至 `Task.detached`，徹底解放主執行緒 (MainActor)。

## 🤝 貢獻與反饋
我們非常歡迎任何形式的貢獻！如果您遇到 Bug，或是希望加入新功能，請開啟 **Issue** 或發起 **Pull Request**。

## 📄 授權協議
本專案採用 **MIT License**。您可以自由地使用、修改與散佈此軟體，詳情請見 [LICENSE](LICENSE) 檔案。
