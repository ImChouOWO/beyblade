from pathlib import Path
from PIL import Image
import json
import zipfile
import shutil

source_path = Path("/mnt/data/icon.png")
output_root = Path("/mnt/data/BeyTail_AppIcon_Fixed")
appicon_dir = output_root / "AppIcon.appiconset"
zip_path = Path("/mnt/data/BeyTail_AppIcon_Fixed.zip")

if output_root.exists():
    shutil.rmtree(output_root)
appicon_dir.mkdir(parents=True, exist_ok=True)

image = Image.open(source_path).convert("RGBA")

# App Store icons should not contain alpha. Flatten transparent pixels onto black,
# which matches the uploaded icon's dark background.
background = Image.new("RGBA", image.size, (0, 0, 0, 255))
background.alpha_composite(image)
base = background.convert("RGB")

def save_icon(filename: str, size: int) -> None:
    resized = base.resize((size, size), Image.Resampling.LANCZOS)
    resized.save(appicon_dir / filename, format="PNG", optimize=True)

# iOS universal icons
save_icon("AppIcon-iOS-Default-1024.png", 1024)
save_icon("AppIcon-iOS-Dark-1024.png", 1024)
save_icon("AppIcon-iOS-Tinted-1024.png", 1024)

# macOS icons
mac_icons = [
    ("AppIcon-mac-16.png", 16, "16x16", "1x"),
    ("AppIcon-mac-32-from16.png", 32, "16x16", "2x"),
    ("AppIcon-mac-32.png", 32, "32x32", "1x"),
    ("AppIcon-mac-64.png", 64, "32x32", "2x"),
    ("AppIcon-mac-128.png", 128, "128x128", "1x"),
    ("AppIcon-mac-256-from128.png", 256, "128x128", "2x"),
    ("AppIcon-mac-256.png", 256, "256x256", "1x"),
    ("AppIcon-mac-512-from256.png", 512, "256x256", "2x"),
    ("AppIcon-mac-512.png", 512, "512x512", "1x"),
    ("AppIcon-mac-1024.png", 1024, "512x512", "2x"),
]

for filename, pixel_size, _, _ in mac_icons:
    save_icon(filename, pixel_size)

contents = {
    "images": [
        {
            "filename": "AppIcon-iOS-Default-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        },
        {
            "appearances": [
                {
                    "appearance": "luminosity",
                    "value": "dark"
                }
            ],
            "filename": "AppIcon-iOS-Dark-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        },
        {
            "appearances": [
                {
                    "appearance": "luminosity",
                    "value": "tinted"
                }
            ],
            "filename": "AppIcon-iOS-Tinted-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        }
    ] + [
        {
            "filename": filename,
            "idiom": "mac",
            "scale": scale,
            "size": logical_size
        }
        for filename, _, logical_size, scale in mac_icons
    ],
    "info": {
        "author": "xcode",
        "version": 1
    }
}

(appicon_dir / "Contents.json").write_text(
    json.dumps(contents, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8"
)

readme = """BeyTail AppIcon 修正版

使用方式：
1. 關閉 Xcode。
2. 將專案中的：
   beyblade/Assets.xcassets/AppIcon.appiconset
   整個資料夾備份後刪除。
3. 將本資料夾內的 AppIcon.appiconset 複製到：
   beyblade/Assets.xcassets/
4. 重新開啟 Xcode。
5. 執行 Product > Clean Build Folder。
6. 刪除模擬器或實機上的舊 App，再重新安裝。

處理內容：
- 原圖由 1930x1930 轉成 iOS 所需 1024x1024。
- 產生 macOS 所需 16、32、64、128、256、512、1024 像素版本。
- 移除透明通道，避免 App Store icon alpha 驗證問題。
- Default、Dark、Tinted 暫時使用相同圖案，可之後在 Xcode 個別替換。
"""
(output_root / "README.txt").write_text(readme, encoding="utf-8")

if zip_path.exists():
    zip_path.unlink()

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(output_root.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(output_root))

print(f"已建立：{zip_path}")
print(f"圖標檔案數：{len(list(appicon_dir.glob('*.png')))}")
