from __future__ import annotations

import re
import shutil
from datetime import datetime
from pathlib import Path


PROJECT_ROOT = Path(
    "/Users/zhouchenghan/Desktop/iosAPP/beyblade"
).resolve()

SOURCE_ROOT = PROJECT_ROOT / "beyblade"

CANONICAL_FILES = {
    "ContentView": (
        SOURCE_ROOT / "BeyTail/UI/ContentView.swift"
    ).resolve(),

    "MainViewModel": (
        SOURCE_ROOT / "BeyTail/UI/MainViewModel.swift"
    ).resolve(),

    "CameraPreviewView": (
        SOURCE_ROOT / "BeyTail/UI/ContentView.swift"
    ).resolve(),

    "CameraPreviewUIView": (
        SOURCE_ROOT / "BeyTail/UI/ContentView.swift"
    ).resolve(),

    "TrailOverlayRepresentable": (
        SOURCE_ROOT / "BeyTail/UI/ContentView.swift"
    ).resolve(),
}

DECLARATION_PATTERN = re.compile(
    r"""
    ^\s*
    (?:
        struct
        |
        final\s+class
        |
        class
    )
    \s+
    (
        ContentView
        |
        MainViewModel
        |
        CameraPreviewView
        |
        CameraPreviewUIView
        |
        TrailOverlayRepresentable
    )
    \b
    """,
    re.MULTILINE | re.VERBOSE,
)


def read_text(path: Path) -> str:
    return path.read_text(
        encoding="utf-8",
        errors="replace",
    )


def main() -> None:
    if not SOURCE_ROOT.is_dir():
        raise SystemExit(
            f"找不到原始碼目錄：{SOURCE_ROOT}"
        )

    timestamp = datetime.now().strftime(
        "%Y%m%d_%H%M%S"
    )

    quarantine_root = (
        PROJECT_ROOT
        / "tmp"
        / f"duplicate_swift_{timestamp}"
    )

    swift_files = sorted(
        SOURCE_ROOT.rglob("*.swift")
    )

    duplicate_files: list[
        tuple[Path, list[str]]
    ] = []

    print("掃描 Swift 型別宣告：\n")

    for swift_file in swift_files:
        resolved_file = swift_file.resolve()
        content = read_text(swift_file)

        declarations = sorted(
            set(
                DECLARATION_PATTERN.findall(
                    content
                )
            )
        )

        if not declarations:
            continue

        relative_path = swift_file.relative_to(
            PROJECT_ROOT
        )

        print(
            f"{relative_path}: "
            f"{', '.join(declarations)}"
        )

        invalid_declarations = [
            declaration
            for declaration in declarations
            if resolved_file
            != CANONICAL_FILES[declaration]
        ]

        if invalid_declarations:
            duplicate_files.append(
                (
                    swift_file,
                    invalid_declarations,
                )
            )

    print("\n檢查正式檔案內部宣告數量：")

    internal_duplicate_found = False

    for declaration, canonical_file in (
        CANONICAL_FILES.items()
    ):
        if not canonical_file.exists():
            print(
                f"[錯誤] 找不到："
                f"{canonical_file}"
            )
            internal_duplicate_found = True
            continue

        content = read_text(canonical_file)

        declaration_count = (
            DECLARATION_PATTERN
            .findall(content)
            .count(declaration)
        )

        print(
            f"{declaration}: "
            f"{declaration_count} 份"
        )

        if declaration_count != 1:
            internal_duplicate_found = True

    if internal_duplicate_found:
        print(
            "\n正式檔案內部也可能有重複內容。"
        )
        print(
            "腳本不會自動截斷正式檔案，"
            "避免刪除有效修改。"
        )

    if not duplicate_files:
        print(
            "\n沒有找到位於其他檔案的"
            "重複型別宣告。"
        )
        return

    print("\n準備移出的重複檔案：")

    for duplicate_file, declarations in (
        duplicate_files
    ):
        print(
            f"- "
            f"{duplicate_file.relative_to(PROJECT_ROOT)}"
            f"：{', '.join(declarations)}"
        )

    quarantine_root.mkdir(
        parents=True,
        exist_ok=True,
    )

    for duplicate_file, _ in duplicate_files:
        relative_path = duplicate_file.relative_to(
            SOURCE_ROOT
        )

        destination = (
            quarantine_root / relative_path
        )

        destination.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        shutil.move(
            str(duplicate_file),
            str(destination),
        )

        print(
            f"[已移出] "
            f"{duplicate_file.relative_to(PROJECT_ROOT)}"
        )

    print(
        "\n重複檔案已移至："
    )
    print(quarantine_root)
    print(
        "\n該目錄位於 tmp 下，"
        "不會被 Xcode 自動加入編譯。"
    )


if __name__ == "__main__":
    main()