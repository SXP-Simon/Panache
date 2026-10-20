# 2026-10-20：自动更新与回滚不能终止同名的其他工作窗口。
!include "getProcessInfo.nsh"
Var pid

!macro customCheckAppRunning
  ${If} ${isUpdated}
    !insertmacro FIND_PROCESS "${APP_EXECUTABLE_FILENAME}" $R0
    ${If} $R0 != 1
    ${AndIf} $R0 != 603
      DetailPrint "Panache is still running. Close other windows before updating."
      SetErrorLevel 32
      Quit
    ${EndIf}
  ${Else}
    !insertmacro _CHECK_APP_RUNNING
  ${EndIf}
!macroend
