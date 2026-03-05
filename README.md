# SMB 掛載管理器 (SMB Mount Manager)

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)
![Swift 5](https://img.shields.io/badge/Swift-5.0-orange.svg)
![License MIT](https://img.shields.io/badge/License-MIT-green.svg)

> **SMB 掛載管理器** 是一個專為 macOS 設計的強大開源常駐選單列工具，旨在為 SMB 網路磁碟提供穩定、無縫且聰明的掛載體驗。

## 🌟 核心特色

- **智慧型網路連線偵測**：不再被無盡的「讀取中」卡死！軟體能瞬間偵測網路斷線 (毫秒級響應)，在 macOS Finder 跳出煩人的「伺服器連線中斷」警告視窗前，主動切斷卡死的連線。
- **無縫背景重連**：當您帶著 MacBook 改變網路環境或從睡眠中喚醒時，只要網路一恢復，所有配置好的磁碟都會在背景安靜、自動地重新連線。
- **特定 Wi-Fi (SSID) 限制**：您可以為每個掛載點設定「允許連線的 Wi-Fi 名稱」。例如：只在連上公司網路「Corp-WiFi」時才自動連線 Nas。離開公司時，系統會自動暫停掛載要求，防止在外網不斷嘗試連線造成的系統資源浪費。
- **狀態列直覺管理**：在 macOS 頂部選單列即時顯示所有掛載點的連線狀態（已連線、未連線、暫停中）、伺服器回應延遲 (Ping) 以及剩餘儲存容量。
- **強大的安全機制**：密碼不以明文儲存，完美整合 macOS 原生「鑰匙圈 (Keychain)」系統，確保企業級的資訊安全。
- **一鍵權限修復 (Helper Tool)**：內建特權輔助工具 (Privileged Helper Tool)，一鍵修復 macOS 常見的 `/Volumes` 掛載權限錯亂問題，保證掛載點穩定建立。
- **自動建立桌面捷徑**：掛載成功時，可選自動在桌面建立捷徑（Alias）；當網路中斷或退出時，自動清理移除桌面捷徑，保持桌面整潔。

## 📸 介面預覽

*(此處可替換為實際的截圖網址)*

| 選單列狀態 | 掛載點設定 | 詳細資訊介面 |
| :---: | :---: | :---: |
| `StatusMenuView` | `AddMountSheet` | `MountDetailView` |

## 🚀 安裝與執行

### 從 Release 下載安裝
1. 前往本專案的 [Releases](https://github.com/imstevelin/smbmountmanager/releases) 頁面。
2. 下載最新的 `SMB掛載管理器.zip`。
3. 解壓縮後將 `SMB掛載管理器.app` 拖曳至您的「應用程式 (Applications)」資料夾。
4. 首次開啟時，建議進入「設定」>「系統服務」點擊「安裝修復程式」，以獲得最佳的穩定性。

### 自行編譯 (開發者)
```bash
# 1. 複製專案
git clone https://github.com/imstevelin/smbmountmanager.git
cd smbmountmanager

# 2. 開啟 Xcode 專案
open SMBMountManager.xcodeproj
```
* **環境要求**：macOS 14.0 或以上版本，Xcode 15 或以上版本。
* 請確保在 Signing & Capabilities 中設定好您的開發者憑證。

## 🛠 功能總覽

1. **多節點伺服器支援**：可以對同一個掛載點設定多個 IP 或主機名稱（例如：`192.168.1.100, nas.local`）。軟體會自動測試並連線到速度最快、可存取的節點。
2. **容錯重試機制 (Exponential Backoff)**：若掛載失敗，引擎不會瘋狂重試，而是會採用遞增的延遲時間 (3s, 6s, 12s...) 進行背景嘗試，最高等待上限為 60 秒。
3. **無縫更新檢查**：內建自動檢查 GitHub Releases 功能，當有新版本釋出時，應用程式會主動提醒您並提供下載連結。
4. **精準除錯日誌**：內建完整的 Log 追蹤系統，在「詳細資訊」點擊「執行日誌」即可查看該掛載點從發起連線到驗證、或中斷的每一幀歷史軌跡。

## 🧠 架構設計說明

* **AppLifecycle**：處理 App 啟動、終止時的安全清理 (Clean up)。
* **MountManager (MainActor)**：主控台，負責儲存全域設定、統籌所有掛載引擎 (MountEngine)、並且以 Combine 即時監聽 `NetworkMonitorService`。
* **MountEngine (Actor)**：每個掛載點都有獨立的掛載引擎，所有的 I/O (FileManager、Process、stat) 都被分離到 `Task.detached` 中執行，**保證絕對不阻塞 UI**。
* **NetworkManager**：透過底層 `Network` framework 監控網路介面切換 (Wi-Fi 變化、乙太網路插拔)，零延遲回報網路可用性 (`isNetworkUp`)。

## 🤝 貢獻與反饋

我們非常歡迎任何形式的貢獻！如果您有遇到任何 Bug，或是希望加入新功能：
1. 請開啟一個 **Issue** 描述您的問題。
2. 或者 Fork 本專案，提交您的 **Pull Request**。

## 📄 授權協議

本專案採用 **MIT License**。您可以自由地使用、修改與散佈此軟體，詳情請見 [LICENSE](LICENSE) 檔案。
