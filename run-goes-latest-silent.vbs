' Silent wrapper for the GOES alias publisher (same pattern as the SSTV/FT8 ones):
' Task Scheduler launching python.exe directly still flashes a console window,
' because conhost is created before the process can hide itself.
Set sh = CreateObject("WScript.Shell")
sh.Run "python ""C:\w4ewb\W4EWB\goes_latest_publish.py""", 0, True
