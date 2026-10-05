' Silent wrapper for the SSTV gallery publisher.
' Task Scheduler calling powershell.exe -WindowStyle Hidden DIRECTLY still flashes a
' console window every run (conhost is created before PowerShell hides itself).
' Launching via wscript + sh.Run(..., 0, True) starts it truly hidden - same pattern
' as run_ft8_silent.vbs and run-rigctld-silent.vbs, which never flash.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\w4ewb\W4EWB\sstv_publish.ps1""", 0, True
