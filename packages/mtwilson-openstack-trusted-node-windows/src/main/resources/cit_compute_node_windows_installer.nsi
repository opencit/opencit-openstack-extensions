; MUI 1.67 compatible ------
!include "MUI.nsh"

!define PRODUCT_NAME "CIT-compute-node"
!define PRODUCT_VERSION "1.0"
!define PRODUCT_PUBLISHER "Intel Corporation"
!define PRODUCT_WEB_SITE "http://www.intel.com"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
!define PRODUCT_UNINST_ROOT_KEY "HKLM"

; MUI Settings
!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

; MUI end ------

Name "${PRODUCT_NAME}"
OutFile "cit-compute-node-setup.exe"
InstallDir "$PROGRAMFILES\Intel"
ShowInstDetails show
ShowUnInstDetails show

; ------------------------------------------------------------------
; ***************************** PAGES ******************************
; ------------------------------------------------------------------

; Welcome page
!insertmacro MUI_PAGE_WELCOME
; License page
;!insertmacro MUI_PAGE_LICENSE ""
; Components page
;!insertmacro MUI_PAGE_COMPONENTS
; Directory page
!define MUI_PAGE_CUSTOMFUNCTION_SHOW DirectoryPageShow
!insertmacro MUI_PAGE_DIRECTORY
; Instfiles page
!insertmacro MUI_PAGE_INSTFILES
; Finish page
!define MUI_FINISHPAGE_NOAUTOCLOSE
;!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
;!define MUI_FINISHPAGE_SHOWREADME ""
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

; Language files
!insertmacro MUI_LANGUAGE "English"
; -------------------------------------------------------------------------
; ***************************** END OF PAGES ******************************
; -------------------------------------------------------------------------

; ----------------------------------------------------------------------------------
; *************************** SECTION FOR INSTALLING *******************************
; ----------------------------------------------------------------------------------

Section Install
  SetOverwrite try
  SetOutPath "$TEMP"
  File "trustagent-windows*.exe"
  File "mtwilson-policyagent-windows*.exe"
  File "tbootxm-windows*.exe"
  File "vrtm-windows*.exe"
  File "mtwilson-openstack-node-windows*.exe"
  CopyFiles $EXEDIR\system.ini $TEMP
SectionEnd

Section AdditionalIcons
  CreateDirectory "$SMPROGRAMS\Intel"
  CreateShortCut "$SMPROGRAMS\Intel\Uninstall.lnk" "$INSTDIR\uninst.exe"
SectionEnd

Section Post
  WriteUninstaller "$INSTDIR\uninst.exe"
  WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "UninstallString" "$INSTDIR\uninst.exe"
  WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
  WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
  WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
SectionEnd

Section InstallComponents
  ExecWait '$TEMP\mtwilson-trustagent-windows-installer-3.2-SNAPSHOT.exe'
  ExecWait '$TEMP\mtwilson-policyagent-windows-3.2-SNAPSHOT.exe'
  ExecWait '$TEMP\tbootxm-setup.exe'
  ExecWait '$TEMP\vrtm-setup.exe'
  ExecWait '$TEMP\mtwilson-openstack-node-windows-3.2-SNAPSHOT.exe'

  Delete "$TEMP\mtwilson-trustagent-windows-installer-3.2-SNAPSHOT.exe"
  Delete "$TEMP\mtwilson-policyagent-windows-3.2-SNAPSHOT.exe"
  Delete "$TEMP\tbootxm-setup.exe"
  Delete "$TEMP\vrtm-setup.exe"
  Delete "$TEMP\mtwilson-openstack-node-windows-3.2-SNAPSHOT.exe"
  Delete "$TEMP\system.ini"
SectionEnd

; ----------------------------------------------------------------------------------
; ************************** SECTION FOR UNINSTALLING ******************************
; ----------------------------------------------------------------------------------

Section Uninstall
  ExecWait '$INSTDIR\Openstack-extension\uninst.exe'
  ExecWait '$INSTDIR\vRTM\uninst.exe'
  ExecWait '$INSTDIR\tbootxm\uninst.exe'
  ExecWait '$INSTDIR\Policy Agent\uninst.exe'
  ExecWait '$INSTDIR\TrustAgent\Uninstall.exe'

  Delete "$INSTDIR\uninst.exe"
  Delete "$SMPROGRAMS\Intel\Uninstall.lnk"

  RMDir "$SMPROGRAMS\Intel"
  RMDir "$INSTDIR"

  DeleteRegKey ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}"
  SetAutoClose false
SectionEnd
; ----------------------------------------------------------------------------------
; ********************* END OF INSTALL/UNINSTALL SECTIONS **************************
; ----------------------------------------------------------------------------------

; ----------------------------------------------------------
; ********************* FUNCTIONS **************************
; ----------------------------------------------------------

Function .onInit
  SetRebootFlag true
  ReadRegStr $R0 ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "UninstallString"
  StrCmp $R0 "" done
  MessageBox MB_ICONEXCLAMATION|MB_OKCANCEL|MB_DEFBUTTON2 "$(^Name) is already installed. $\n$\nClick `OK` to remove the previous version or `Cancel` to cancel this upgrade." IDOK +2
  Abort
  Exec $INSTDIR\uninst.exe
  done:
FunctionEnd

Function un.onInit
  SetRebootFlag true
  MessageBox MB_ICONQUESTION|MB_YESNO|MB_DEFBUTTON2 "Are you sure you want to completely remove $(^Name) and all of its components?" IDYES +2
  Abort
FunctionEnd

Function un.onUninstSuccess
  HideWindow
  MessageBox MB_ICONINFORMATION|MB_OK "$(^Name) was successfully removed from your computer."
FunctionEnd

Function DirectoryPageShow
	FindWindow $R0 "#32770" "" $HWNDPARENT
	GetDlgItem $R1 $R0 1019
	EnableWindow $R1 0
	GetDlgItem $R1 $R0 1001
	EnableWindow $R1 0
FunctionEnd
; ----------------------------------------------------------
; ****************** END OF FUNCTIONS **********************
; ----------------------------------------------------------