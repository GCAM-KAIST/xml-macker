# Installer

The Releases page ships the portable single file. This folder builds an optional installer that adds a
Start-menu entry, an uninstaller, an optional desktop shortcut and an optional "Open with" entry for
`.xml` files.

1. Install [Inno Setup 6](https://jrsoftware.org/isinfo.php).
2. Publish the application (from the repository root):
   `dotnet publish src\xml-macker\xml-macker.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish`
3. Build the installer: `iscc installer\xml-macker.iss`, the result is `installer/Output/xml-macker-setup-<version>.exe`.

The installer runs per user by default (no administrator rights); the wizard offers an all-users install.
