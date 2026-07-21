import os
os.environ["QT_QPA_PLATFORM"] = "windows:wintab"

import sys
from pathlib import Path

# Ensure Reskia module directory is in path
_reskia_dir = Path(__file__).parent
if str(_reskia_dir) not in sys.path:
    sys.path.insert(0, str(_reskia_dir))

import PySide6.QtWidgets as QtWidgets

from MainWindow import MainWindow, load_or_create_project

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Reskia - Minimalist Animation Tool")
    parser.add_argument("project", nargs="?", help="Project directory path")
    args = parser.parse_args()

    app = QtWidgets.QApplication(sys.argv)

    # Load or create project if path provided
    project = None
    if args.project:
        project = load_or_create_project(args.project)

    window = MainWindow(project)
    window.show()
    sys.exit(app.exec())
