; Viora Windows 安装包（Inno Setup 6）
; CI 调用：iscc /DAppVersion=0.1.0 /DSourceDir=<flutter 构建输出目录> /DOutputDir=<输出目录> viora.iss
;
; - 按用户安装（无需管理员权限 / UAC），装到 %LOCALAPPDATA%\Programs\Viora
; - 应用内更新以 /SILENT 运行本安装包：自动关闭旧进程、覆盖安装、完成后重新打开 Viora

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

[Setup]
; AppId 固定不变，否则覆盖安装会被当成另一个程序
AppId={{1E6A7C84-E0FD-473C-8D9B-D76936AB5E5B}
AppName=Viora
AppVersion={#AppVersion}
AppVerName=Viora {#AppVersion}
AppPublisher=Viora
DefaultDirName={localappdata}\Programs\Viora
DefaultGroupName=Viora
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Viora-{#AppVersion}-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
UninstallDisplayIcon={app}\Viora.exe
UninstallDisplayName=Viora

[Languages]
#if FileExists(CompilerPath + "Languages\ChineseSimplified.isl")
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#else
Name: "en"; MessagesFile: "compiler:Default.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 清掉旧版本残留的 Flutter 资源，避免新旧文件混用
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\Viora"; Filename: "{app}\Viora.exe"
Name: "{autodesktop}\Viora"; Filename: "{app}\Viora.exe"; Tasks: desktopicon

[Run]
; 没有 skipifsilent：应用内静默更新完成后也会自动重新打开
Filename: "{app}\Viora.exe"; Description: "{cm:LaunchProgram,Viora}"; Flags: nowait postinstall
