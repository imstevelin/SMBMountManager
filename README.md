# SMB 掛載管理器 (For MacOS)

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)
![Swift 5](https://img.shields.io/badge/Swift-5.0-orange.svg)
![Release 1.4.0](https://img.shields.io/badge/Release-1.4.0-brightgreen.svg)
![License MIT](https://img.shields.io/badge/License-MIT-green.svg)

> **SMB 掛載管理器** 是一個專為 macOS 設計的開源常駐選單列工具。它能自動管理多個 SMB/NAS 掛載點、提供多線程斷點續傳的雙向檔案傳輸、智慧網路環境偵測，並以 Apple Liquid Glass 設計語言打造極致美觀的操作介面。

---

## ✨ 核心功能

### 📁 SMB 掛載點管理
- **多掛載點**：同時管理多個 NAS / SMB 伺服器的掛載連線
- **開機自動掛載**：系統啟動後自動連接所有已設定的掛載點
- **斷線自動重連**：持續監控掛載狀態，斷線後自動嘗試重新掛載
- **休眠喚醒保護**：筆電合蓋 / 休眠後喚醒時，自動處理掛載點恢復與網路切換
- **Keychain 整合**：帳號密碼安全儲存於 macOS 鑰匙圈，無需明碼保存

### ⚡ 多線程斷點續傳引擎
- **下載加速**：4 線程並發 Chunk 分段下載，充分利用網路頻寬
- **上傳引擎**：支援大檔案分段上傳，附帶進度追蹤與速度監控
- **斷點續傳**：網路中斷或 App 重啟後，自動接續已下載 / 已上傳的進度
- **Finder 右鍵整合**：在 Finder 中選取檔案，右鍵「快速動作」即可發起「SMB 專用下載」或「SMB 專用上傳」
- **即時速度顯示**：EMA 平滑演算法確保速度與 ETA 顯示穩定不跳動

### 🌐 智慧網路管理
- **Wi-Fi SSID 限制**：可設定掛載點僅在指定 Wi-Fi 環境下自動啟用
- **乙太網路支援**：支援偵測有線網路連接，自動切換至最佳連線
- **網路切換自適應**：Wi-Fi 與乙太網路切換時，自動重新建立 SMB 連線與傳輸任務

### 🎨 設計與體驗
- **Liquid Glass 介面**：毛玻璃卡片、動態進度環、景深邊框等現代 macOS 設計語言
- **選單列常駐**：不佔用 Dock 空間，在選單列即時顯示掛載數量與傳輸進度
- **全局進度環**：合併計算所有傳輸任務的進度，於選單列以單一動畫圓環呈現
- **系統通知整合**：傳輸完成、掛載成功 / 失敗等事件均有 macOS 原生通知提醒

### 🔄 靜默自動更新
- **背景自動更新**：勾選「啟動時自動檢查並更新」後，每次啟動時會背景檢查 GitHub 最新版本
- **無感升級**：有新版本時自動下載、解壓縮、替換應用程式並重啟，全程使用者無需操作
- **手動檢查**：也可隨時從選單手動觸發更新檢查

---

## 📥 安裝

### 從 Release 下載（推薦）
1. 前往 [Releases](https://github.com/imstevelin/SMBMountManager/releases) 頁面
2. 下載最新的 `SMBMountManager-v1.4.0.zip`
3. 解壓縮後將 `SMB掛載管理器.app` 拖入「應用程式」資料夾
4. **推薦**：首次開啟後，進入「設定」>「安裝權限修復服務」以獲得最佳穩定性

### 開發者編譯
```bash
git clone https://github.com/imstevelin/SMBMountManager.git
cd SMBMountManager/swift
xcodegen
open SMBMountManager.xcodeproj
```
**環境要求**：macOS 14.0+、Xcode 15+

---

## 🏗 專案架構

```
SMBMountManager/
├── SMBMountManagerApp.swift        # App 入口、AppDelegate、TransferProgressManager
├── Models/
│   └── DownloadTaskModel.swift     # 下載任務資料結構
├── Services/
│   ├── MountEngine.swift           # SMB 掛載核心引擎 (mount/unmount)
│   ├── MountManager.swift          # 掛載點狀態管理與自動重連
│   ├── NetworkMonitorService.swift # 網路狀態監控 (Wi-Fi/Ethernet)
│   ├── WiFiService.swift           # Wi-Fi SSID 偵測
│   ├── KeychainService.swift       # macOS 鑰匙圈整合
│   ├── NotificationService.swift   # 系統通知管理
│   ├── UpdateService.swift         # GitHub Release 自動更新引擎
│   ├── AppSettings.swift           # 使用者偏好設定
│   ├── AppLogger.swift             # 統一日誌系統
│   ├── LaunchdService.swift        # 開機自動啟動服務
│   ├── Download/
│   │   ├── DownloadManager.swift   # 下載任務佇列管理
│   │   └── ChunkDownloader.swift   # 多線程分段下載器
│   └── Upload/
│       ├── UploadManager.swift     # 上傳任務佇列管理
│       └── ChunkUploader.swift     # 多線程分段上傳器
└── Views/
    ├── MainSettingsView.swift      # 主設定介面 (掛載點、設定、關於)
    ├── AddMountSheet.swift         # 新增/編輯掛載點表單
    ├── MountDetailView.swift       # 掛載點詳細資訊
    ├── DownloadManagerView.swift   # 下載任務管理頁面
    ├── UploadManagerView.swift     # 上傳任務管理頁面
    ├── StatusMenuView.swift        # 選單列下拉選單
    ├── ConnectionTestView.swift    # 連線測試介面
    └── FlowLayout.swift            # 自訂流式佈局元件
```

---

## 🤝 貢獻
歡迎提交 **Issue** 回報問題或 **Pull Request** 貢獻程式碼！

## 📄 授權
本專案採用 [MIT License](LICENSE)。
