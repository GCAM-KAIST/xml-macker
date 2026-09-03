# xml-macker

An editor for very large XML files, built for
[GCAM](https://github.com/JGCRI/gcam-core) model files: hundreds of
megabytes, millions of lines. It opens what other editors refuse, and
stays responsive once it has.

It began as a macOS application and now runs on Windows as well. Both
versions are in this repository, share the same design and carry the
same features.

| | macOS | Windows |
|---|---|---|
| Source | [`macos/`](macos) | [`windows/`](windows) |
| Built with | Swift 6, AppKit, no dependencies | .NET 8, WPF |
| Needs | macOS 13 or newer, Apple Silicon | Windows 10 or 11, x64 |

## What it does

- **Huge files, quickly.** A 655 MB, 12.6-million-line file opens in
  about 20 seconds, and jumping anywhere in it is immediate. Several
  files in tabs, drag and drop, and "Open With" from the file manager.
- **Four workspaces.** Simple, Inspect, Full and Learn, one click each.
- **Six panes.** Tree, Source (a syntax-highlighted editor with a
  two-lane minimap: the left lane snaps to the elements at your current
  level, the right moves by line under a magnifier), Subtags, Hierarchy,
  and a details rail carrying Inspector, Chart, Preview and Errors. Any
  pane pops out into its own window, and the minimap can be hidden from
  the small button above it.
- **Editing that stays in sync.** Change an attribute in the Inspector,
  in Subtags, in Orbit or in the source itself, and every view follows,
  with undo.
- **Live validation.** Well-formedness problems are found as you type,
  with one-click fixes and a badge on the Errors tab.
- **Charts.** A chart of the numbers inside the selected element is
  drawn automatically, and one taken inside a region compares that
  region's own members rather than jumping to all regions. The chart
  builder walks the whole file through dropdowns to plot any value at
  any level, with image and CSV export.
- **Orbit.** A radial map: the selected element in the centre, its
  children around it, siblings above, and editing in place.
- **Diff.** Two files side by side, paired element by element, so the
  same sector meets the same sector even when the files list them in a
  different order. Walk the differences by block or line by line, copy
  either way, and undo the copy. A copy always moves complete elements,
  so the other file cannot be left broken.
- **Find and Replace.** Whole-word matching, an element scope, a
  results list and CSV export, plus a quick search in the toolbar.
- **Marker.** Take the pen and the pointer becomes a highlighter. Drag
  over words to paint them in four colours, walk from one mark to the
  next, and find them still there the next time you open the file.
- **Learn.** A chat site beside your file: send the selection or the
  current element with one click, open the file's folder to drag it
  into the chat, or copy the whole file.
- **Drag and drop.** Drag the text you selected, or an element straight
  out of the tree, into the chat page, back into the file at any point
  as one undoable edit, or into another program entirely.
- **Comfort.** Six themes, an application zoom plus a separate zoom for
  the window or pane under the pointer, a first-launch tour, a settings
  window, untitled documents, and your last files remembered.

## Install

Download the build for your system from
[Releases](../../releases).

**macOS.** Unzip and drag `xml-macker.app` into Applications. On the
first launch macOS warns about an unidentified developer: open
**System Settings, Privacy and Security**, click **Open Anyway** and
confirm.

**Windows.** Run `xml-macker-setup.exe` for a Start-menu entry and an
uninstaller, or take the portable `xml-macker.exe` and run it from
anywhere. Windows SmartScreen may warn about an unrecognised
publisher: choose **More info**, then **Run anyway**.

## Build from source

**macOS**, needing only the Xcode Command Line Tools
(`xcode-select --install`):

```bash
cd macos
./build-app.sh release     # SwiftPM build, then the .app bundle
open dist/xml-macker.app
```

**Windows**, needing the .NET 8 SDK:

```bat
cd windows
dotnet build xml-macker.sln -c Release
dotnet run --project src\xml-macker\xml-macker.csproj -c Release
```

The installer is built from `windows/installer/xml-macker.iss` with
[Inno Setup 6](https://jrsoftware.org/isinfo.php).

## Checking a build

Each version carries its own harness, so a build can be checked without
an IDE:

```bash
cd macos && ./tools/check.sh        # compiler, self-checks, diff engine, launch
cd macos && ./tools/check.sh --ui   # the above, plus a scripted pass over the interface
```

```bat
cd windows
dotnet run --project src\xml-macker-tests\xml-macker-tests.csproj -c Release
```

On macOS, `dist/xml-macker.app/Contents/MacOS/xml-macker --self-check` runs the assertions alone and exits.

## License

MIT. Developed by Ahmed SM Sobhy, KAIST IAM Group.
