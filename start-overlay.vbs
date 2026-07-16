' Starts the usage overlay with no terminal window at all.
' On Windows 11 "powershell -WindowStyle Hidden" still flashes a Windows
' Terminal window; launching through wscript with window style 0 does not.
' Double-click this file, or point a shortcut at it.
Dim sh, fso, here
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\usage-overlay.ps1""", 0, False
