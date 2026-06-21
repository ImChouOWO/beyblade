# BeyTrail iOS 移植進度

> 給接續開發者（或新對話的 Claude）：此檔是唯一進度依據。
> Android 原始碼在 `d:\flutter`，功能規格見 `d:\flutter\ios_feature_checklist.md`。

## ✅ 全部主要元件已完成（2026-06-13）

### 骨架
- [x] README.md / project.yml（XcodeGen）/ Info.plist / BeyTrailApp.swift

### 核心邏輯
- [x] Effects/EffectType.swift（8 特效 + owned/delisted/devUnlocked 機制）
- [x] Effects/TrailPoint.swift、TrailEffectEngine.swift（時間戳驅動）
- [x] ML/DetectionResult.swift、BeybladeTracker.swift（匈牙利 + EMA + predictStep）
- [x] ML/InferenceEngine.swift（Mock 繞圈；Core ML 載入為 TODO stub，等模型）
- [x] Support/SettingsStore.swift

### Metal 渲染
- [x] Shaders.metal（全部 shader：相機/blit/通用/柔環/浪潮流體/鋼盾/爆刃/冰裂/火焰/火球/冰片/3 種點粒子）
- [x] RenderContext.swift（統一 TrailVertex 32B、dtScale、GeomHelper）
- [x] PipelineLibrary.swift（pipeline 集中建立 + encoder 繪製輔助）
- [x] CameraRenderer.swift（三 pass：場景離屏 → 螢幕 → 錄影裁切旋轉；推論節流 + Kalman）
- [x] Effects/：Generic、Wave、IronShield、Blade、IceShatter、CrimsonLotus（5+1 全數移植，
      含 dtScale、moveNorm 正規化、所有 Android 最終版參數）

### 相機 / 錄影（格式與 Android 一致）
- [x] CameraManager.swift（1920×1080 → 直向 BGRA、30/60fps activeFormat、torch、麥克風）
- [x] RecordingManager.swift（直拍 1080×1920 / 橫拍 1920×1080 烘焙旋轉 rotation=0、
      H.264 8M/12Mbps、AAC 44.1k 128k、暫存 → 確認後存「BeyBlade」相簿）

### UI / IAP / 影片處理
- [x] MainView.swift（相機、特效選單、錄影短按/長按倒數 3/5/10、countdown、torch、
      FPS/[硬體]/熱度 HUD、20 秒試用 HUD、方向監聽）
- [x] ReviewView.swift（循環播放、儲存/分享/捨棄）
- [x] ShopView.swift（bundle 卡全擁有自動隱藏、單品、已擁有 + 快捷 6 格、點 emoji 試用）
- [x] SettingsView.swift（60fps、客服表單、評分、恢復購買、隱私權、版本）
- [x] Billing/StoreManager.swift（StoreKit 2、entitlement 權威、退款自動上鎖、bundle 展開）
- [x] Video/VideoEffectProcessor.swift（Reader/Writer、推論+特效合成、音軌 passthrough、
      1080p 上限、rotation transform 透傳、進度/取消）
- [x] UI/VideoFxView.swift（PhotosPicker 選片、特效 chips、進度條）

## ⚠️ 與 Android 的已知差異 / 待辦

1. **首次編譯**：原始碼在 Windows 生成、未經 Xcode 編譯 — 第一次在 Mac build
   一定會有少量編譯錯誤要修（API 簽名/語法細節），屬正常流程
2. **模型**：InferenceEngine 的 Core ML 路徑是 stub；目前固定 Mock 模式。
   模型轉好放 Resources/Models/ 後要補 YOLO 輸出解碼 + NMS（照 Android runInference 移植）
3. ~~特效選單互動簡化~~ **✅ 已補齊（2026-06-13）**：特效快選與錄影鈕皆改為
   「短按開選單／長按 0.55s（外圈進度環）彈選單→按住拖到項目放開選取」，hover 高亮、
   點選備援；命中判定走 MenuItemFrameKey 收集 root 座標框（見 MainView.swift）
4. **溫度顯示**：iOS 無電池溫度 API → 用系統 thermalState 四級（正常/微熱/偏熱/過熱）
   ※ 這是平台限制，已是最佳替代，不需再改
5. ~~icon 跟隨實體旋轉~~ **✅ 已補齊（2026-06-13）**：iconRotation() 修飾器讓所有 icon
   glyph 跟 orientationDegrees 反向旋轉（250ms 動畫），錄影中凍結方向。選單面板維持直向
   以免拖曳命中判定要做旋轉換算。⚠️ 旋轉方向需實機驗證，若相反把 iconRotation 內負號拿掉
6. VideoFx 選片用 loadTransferable 複製暫存檔（大影片較慢），可改 PHAsset 直取優化
7. devUnlockedProductIds 含 crimsonlotus（同 Android，出 release 前清空）
8. ~~錄影中切換 app/來電的中斷處理~~ **✅ 已補齊（2026-06-13）**：scenePhase 退背景 +
   AVCaptureSessionWasInterrupted（來電/被搶相機）→ stopRecordingAndSave() 自動停錄並
   直接存相簿（不進預覽頁）；背景同時暫停相機、回前景恢復並重查購買（見 MainView.swift）

## 上架前 checklist（人工作業）

- [ ] Mac + Xcode、Apple Developer Program（US$99/年）
- [ ] `xcodegen` 產生專案、填 Team ID、真機測試
- [ ] App Store Connect：建 App + 5 個 IAP 商品（ID 見 README）
- [ ] SettingsView 兩個占位網址換成真的（客服表單、隱私權政策）
- [ ] EffectType.devUnlockedProductIds 清空
- [ ] 模型轉 Core ML 放入 + 補推論解碼
- [ ] App 圖示、截圖、商店文案
