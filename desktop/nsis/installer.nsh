# B39 installer process check (2026-11-21, plan task-10, kimi-planner).
#
# Purpose: make the NSIS "app is running" check use the EXACT executable-name branch
# provided by upstream allowOnlyOneInstallerInstance.nsh (tasklist + findstr /B exact match
# at :69-77, and exact-name termination at :96-100), instead of the $INSTDIR-prefix
# process matching branch.
#
# Why no custom logic here: upstream already ships that branch plus the full
# detect -> prompt -> graceful close -> retry -> fail flow (_CHECK_APP_RUNNING, :105-163).
# This file only forces the branch selection; it copies nothing and redefines nothing.
#
# Note: upstream inverts the flag semantics (:46 "0 = available, 1 = not available"),
# so writing 1 declares PowerShell unavailable and FIND_PROCESS / KILL_PROCESS fall back
# to the exact executable-name path.
#
# Keep this file ASCII-only: makensis -INPUTCHARSET does not apply to included files,
# and non-ASCII characters here abort the build with "Bad text encoding".

# Mirror the declarations upstream allowOnlyOneInstallerInstance.nsh makes at :5-8.
# electron-builder places this custom include in the shared script header, i.e. BEFORE
# installer.nsi includes that file, so its !ifmacrondef customCheckAppRunning guard is
# already false and upstream would skip both lines below. _CHECK_APP_RUNNING:106 then
# uses ${GetProcessInfo} (:21 of getProcessInfo.nsh) and $pid, so they must exist here.
# getProcessInfo.nsh has its own include guard (:15-16), so exactly one copy is emitted;
# if include order ever changes, a duplicate Var pid fails the build instead of silently
# changing behaviour.
!include "getProcessInfo.nsh"
Var pid
!macro customCheckAppRunning
  !insertmacro IS_POWERSHELL_AVAILABLE
  DetailPrint "Process check: using exact executable-name fallback"
  StrCpy $IsPowerShellAvailable 1
  !insertmacro _CHECK_APP_RUNNING
!macroend