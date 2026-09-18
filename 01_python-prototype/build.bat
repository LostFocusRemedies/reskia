REM pyinstaller --onefile --noconsole --distpath ./release --add-data "src;src" src/Reskia.py
pyinstaller --onefile --noconsole --distpath ./release --paths src --add-data "src;src" src/Reskia.py
