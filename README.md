# Teleo（中文名：縮地，專案代號 VirtualLoc）

在 iPhone 本機上模擬定位的 App（SwiftUI）。使用 Apple 開發者服務的 LocationSimulation，
和 Xcode 的「模擬位置」是同一機制，不需越獄。

## 功能

- 單點定位：點地圖或輸入座標、搜尋地名、貼上座標、複製座標（小數六位）
- 路線：匯入 GPX、貼上座標清單、點地圖加入路線點；可選「依貼上順序」或「自動排成最短路線」
  （最近鄰＋2-opt）；循環、調速、上一點／下一點、指定起跑點、預估剩餘時間
- 輸入多筆座標：路線頁的「輸入多筆座標」，每行一個「緯度, 經度」（也接受括號、度數符號），
  可預覽辨識數量、從剪貼簿貼上、接在目前路線後面，不需要 GPX
- 花農繞圈：種花路線頁的「花農繞圈」。輸入多朵花的座標後，依序繞每朵花走圈（半徑、圈數、每圈點數可調），
  繞完換下一朵；每個圓的入口朝向上一朵花、出口朝向下一朵花，花與花之間的路最短。
  可選「花與花之間直接瞬移」，也可依最短順序排列花；全部的花可走多輪，畫面顯示「第 N / M 朵花」
- 跳躍收果：種花路線頁的「跳躍收果」。輸入多個座標（不用 GPX），依序直接跳到每個點、停留指定秒數再跳下一個；
  輸入框下方的「各點停留秒數」可個別調整每個點停留幾秒，可走多輪、可依最短順序排列
- 虛擬搖桿：離中心越遠越快
- 路線中切換單點或搖桿會保留進度，之後「回到暫停點並繼續」
- 斷線自動重連（最多 10 分鐘），成功後回到最後位置接著走
- 每 4 秒重送一次定位，維持模擬狀態
- 原始位置（紫色旗幟）記錄與一鍵回到原位、恢復真實定位
- 背景保活（持續定位）
- 收藏（地標／路線各 500 筆）、歷史紀錄（200 筆）
- 錯誤日誌（可複製）、簽名到期提醒

沒有做的（需要伺服器或帳號系統）：雲端備份、團體房間、語音、授權驗證、浮動視窗。

## 重要：這份程式尚未編譯與實機測試

我沒有 Xcode 與 iPhone，程式只靠讀 idevice 原始碼撰寫，**第一次編譯可能會有錯誤**。
CI 失敗時會自動上傳 `build-logs`，把裡面的錯誤貼給我即可修正。

## 需要的東西

1. iPhone iOS 17.4 以上。App 本身（SwiftUI 介面）在 iOS 26、27 上也能跑，最低版本沒有限制。
   但 iOS 26.4 以上（含 27）目前卡在以下兩個外部工具，不是本 App 能解決的：
   - **配對檔要重新產生**：舊版配對檔在 iOS 26.4 以上會失效
   - **StikDebug 等 DDI 掛載工具，截至其 3.1.0 版仍無法在新版 iOS 上掛載開發者磁碟映像**
     （官方已承認是已知問題，下一版才會修），沒有掛載就連不上開發者服務
   - LocalDevVPN 的本機回環通道協定也隨 iOS 26.4 改變，要看它有沒有更新跟上
   - 本專案釘住的 idevice 函式庫版本已是目前最新，已包含新版配對協定（rppairing）的支援，
     這部分不需要更新；卡點在上面兩個外部工具本身
2. 開發者模式已開啟（設定 → 隱私權與安全性 → 開發者模式）
3. **開發者磁碟映像（DDI）已掛載**。這是 App 目前沒有自己處理的部分：
   - 沒掛載時，連線會在「連接開發者服務」這一步失敗，錯誤日誌會寫出原因。
   - 重新開機後需要重新掛載。
   - 掛載方式我尚未確認，請先試其他側載工具（例如 StikDebug）是否會幫你掛載，並回報結果。
4. LocalDevVPN（App Store），開啟並連上 VPN；手機要連 Wi-Fi，只有行動網路不行
5. 這支手機的**配對檔**（`.plist` 或 `.mobiledevicepairing`），用電腦取得一次
   （Windows 可用 [idevice_pair](https://github.com/jkcoxson/idevice_pair)）

## 取得 .ipa

.ipa 必須在 macOS 編譯，無法在 Linux 產生。用 GitHub Actions（免 Mac）：

1. 在 GitHub 建新儲存庫，把本資料夾全部內容推上去（含 `.github`）
2. Actions → Build unsigned IPA → Run workflow（首次約 10～20 分鐘，要先編譯 Rust）
3. 完成後有兩個地方可以拿 `.ipa`：
   - 這次 Run 的頁面下方 Artifacts 的 `VirtualLoc-ipa`（90 天後會過期）
   - 儲存庫右側 **Releases**，會多一個 `build-N` 的版本，裡面的 `VirtualLoc.ipa` 不會過期，之後簽名到期要重裝時直接回來這裡下載最新的就好，不用再跑一次 Actions
4. 失敗時下載 `build-logs`，把錯誤貼給我
5. 用 Sideloadly 簽名安裝到 iPhone；免費 Apple ID 每 7 天要重新簽名

## 使用

1. 開 LocalDevVPN → 開 VirtualLoc → 設定 → 匯入配對檔 → 連線
2. 狀態變「已連線」後，到「定位」「路線」「搖桿」使用
3. 結束按「恢復真實定位」

## 專案結構

```
project.yml                  XcodeGen 專案設定（連結 libidevice_ffi.a）
.github/workflows/           CI：先編 idevice，再編 App
VirtualLoc/
  Device/DeviceLink.swift    idevice 橋接：配對檔→10.7.0.1→CoreDeviceProxy→RSD→LocationSimulation
  Device/PairingStore.swift  配對檔存放
  Models/SimulationEngine.swift  狀態機、路線、搖桿、心跳、重連
  Models/GPXParser.swift
  Support/                   Geo、Store、AppLog、KeepAlive、ExpiryReminder
  Views/                     地圖與五個分頁
```

## 使用風險

用於皮克敏或其他遊戲、服務時，可能違反該服務的使用條款而被停權；短時間跳到很遠的地方（包含「花與花之間直接瞬移」）更容易被判定為位置異常。配對檔等同這支手機的開發者權限，請勿分享。
