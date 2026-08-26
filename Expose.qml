import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// macOS-style window overview. Summoned by the hot corner (HotCorner.qml)
// or `omarchy-shell shell toggle ronnie.expose`. Lists every mapped, non-special
// window as a card; typing filters by title/app id; Enter or click focuses
// the window (switching workspace if needed) and closes the overview; Space
// opens a Quick Look inspector for the highlighted card.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool quickLookOpen: false

  property var windows: []
  property var filteredWindows: []

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(40), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Style.space(28)
  property int contentSpacing: Style.spacing.md

  property int cellWidth: Style.space(240)
  property int cellHeight: Style.space(180)
  readonly property int columns: Math.max(1, Math.floor(resultGrid.width / Math.max(1, cellWidth)))

  // `hyprctl clients -j` output is entirely client-controlled: any app can
  // open arbitrarily many windows and/or set an arbitrarily long title/class,
  // and this is a long-running, shared shell process serving every plugin --
  // not a short-lived one we can let balloon and exit. maxRawBytes bounds
  // the string handed to JSON.parse (cheap check before the expensive part);
  // maxWindows bounds how many entries windowsFromClients() will build after
  // that, independent of how many were actually present in the JSON.
  readonly property int maxRawBytes: 5 * 1024 * 1024
  readonly property int maxWindows: 500

  // shell.appLibrary.iconSource() treats a value starting with "/", "file://",
  // or "image://" as a direct image source to load. Window app-ids (WM class)
  // are set by the client application itself -- any app, trusted or not --
  // so passing one through unsanitized would let a malicious window point our
  // Image at an arbitrary local file (existence/content disclosure) or an
  // arbitrary registered image provider. Reject anything path/URI-shaped
  // before it ever reaches iconSource; icon lookup by plain theme name is
  // the only intended use here.
  function safeAppId(appId) {
    var value = String(appId || "")
    if (value.length === 0) return ""
    if (value.indexOf("/") !== -1) return ""
    if (value.indexOf(":") !== -1) return ""
    return value
  }

  function iconSource(appId) {
    var safe = root.safeAppId(appId)
    return root.shell && root.shell.appLibrary ? root.shell.appLibrary.iconSource(safe) : ""
  }

  // Window titles/app-ids are attacker-controlled (any client sets its own
  // title/app-id) and QML Text defaults to Text.AutoText, which will detect
  // and render HTML-like markup in the string. Cap length too so a hostile
  // window can't hand the layout engine a pathological amount of text.
  function safeDisplayText(value, maxLen) {
    var s = String(value || "")
    var limit = maxLen || 300
    return s.length > limit ? s.slice(0, limit) + "…" : s
  }

  function windowMatches(w, text) {
    if (!text) return true
    var needle = text.toLowerCase()
    return w.title.toLowerCase().indexOf(needle) !== -1 || w.appId.toLowerCase().indexOf(needle) !== -1
  }

  // hyprctl clients -j, queried fresh on every open. HyprlandToplevel's
  // lastIpcObject (Quickshell.Hyprland) only reflects a window's state at
  // creation time and is never refreshed afterward, so size/floating/etc.
  // read from it go stale (e.g. a window's creation-time 0x0 size sticks
  // forever) -- a direct hyprctl query avoids that class of bug entirely.
  function windowsFromClients(list) {
    var out = []
    var limit = Math.min(list.length, root.maxWindows)
    for (var i = 0; i < limit; i++) {
      var w = list[i]
      if (w.mapped === false) continue
      if (w.hidden === true) continue
      var wsName = String((w.workspace && w.workspace.name) || "")
      if (wsName.indexOf("special") === 0) continue
      var wsId = (w.workspace && w.workspace.id !== undefined) ? w.workspace.id : 0
      var appId = root.safeDisplayText(w.class || "", 100)
      var title = root.safeDisplayText(w.title || appId || "Untitled", 300)
      var size = Array.isArray(w.size) ? w.size : [0, 0]
      var address = String(w.address || "")
      out.push({
        address: /^0x[0-9a-fA-F]+$/.test(address) ? address : "",
        title: title,
        appId: appId,
        workspaceId: wsId,
        workspaceName: root.safeDisplayText(wsName || String(wsId), 50),
        floating: !!w.floating,
        fullscreen: !!w.fullscreen,
        xwayland: !!w.xwayland,
        pid: w.pid || 0,
        wWidth: size[0] || 0,
        wHeight: size[1] || 0
      })
    }
    out.sort(function(a, b) {
      if (a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId
      return a.title.localeCompare(b.title)
    })
    return out
  }

  function rebuildDisplay() {
    root.filteredWindows = root.windows.filter(function(w) { return root.windowMatches(w, root.filterText) })

    displayModel.clear()
    for (var j = 0; j < root.filteredWindows.length; j++) {
      var w = root.filteredWindows[j]
      displayModel.append({
        address: w.address,
        title: w.title,
        appId: w.appId,
        workspaceName: w.workspaceName,
        floating: w.floating,
        fullscreen: w.fullscreen,
        xwayland: w.xwayland,
        pid: w.pid,
        wWidth: w.wWidth,
        wHeight: w.wHeight
      })
    }

    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
    root.cursorActive = displayModel.count > 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
    })
  }

  function refreshWindows() {
    if (clientsProc.running) return
    clientsProc.killedForSize = false
    clientsProc.running = true
  }

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.quickLookOpen = false
    root.cursorActive = true
    root.refreshWindows()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.quickLookOpen = false
  }

  function dismiss() {
    root.opened = false
    root.quickLookOpen = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ronnie.expose")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.quickLookOpen = false
    root.rebuildDisplay()
  }

  function select(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function selectRow(delta) {
    if (displayModel.count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
      resultGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
      return
    }
    var newIndex = selectedIndex + delta * root.columns
    if (newIndex < 0) newIndex = 0
    if (newIndex >= displayModel.count) newIndex = displayModel.count - 1
    selectedIndex = newIndex
    resultGrid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.filteredWindows.length) return
    var w = root.filteredWindows[index]
    if (!w) return
    // Defense in depth: windowsFromClients() already rejects any address
    // that isn't a plain "0x<hex>" token, but re-check here too before it
    // reaches the dispatch expression below.
    if (!/^0x[0-9a-fA-F]+$/.test(w.address)) {
      root.dismiss()
      return
    }
    // This Hyprland build's IPC socket only accepts its Lua dispatch-table
    // syntax (hl.dsp....), not classic "dispatcher args" strings -- so
    // Quickshell's own Hyprland.dispatch() (which sends the classic form)
    // gets rejected here. Shell out to `hyprctl dispatch` instead, the same
    // way Omarchy's first-party bar widgets do. w.address is validated
    // above as a bare "0x<hex>" token, so it's safe to place inside the Lua
    // string literal -- no shell is involved (argv element, not bash -c),
    // and no quote/backslash characters can occur in a hex address anyway.
    focusProc.command = ["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + w.address + "\" })"]
    focusProc.running = true
    root.dismiss()
  }

  function toggleQuickLook() {
    if (displayModel.count === 0) return
    root.cursorActive = true
    root.quickLookOpen = !root.quickLookOpen
  }

  ListModel { id: displayModel }

  Process { id: focusProc }

  Process {
    id: clientsProc
    // Was: StdioCollector { waitForEnd: true }, checking text.length only in
    // onStreamFinished. That check ran only after the collector had already
    // buffered the entire (potentially hostile-sized) stream -- a client
    // controls how many windows exist and how long its own title/class
    // strings are, so an unbounded producer means unbounded memory held by
    // this long-running, shared shell process before the check ever fires.
    // waitForEnd: false exposes `text` incrementally as chunks arrive, so we
    // can SIGKILL the producer the moment it crosses maxRawBytes instead of
    // waiting for it to finish on its own.
    property bool killedForSize: false
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        if (!clientsProc.killedForSize && text.length > root.maxRawBytes) {
          clientsProc.killedForSize = true
          clientsProc.signal(9) // SIGKILL -- stop the producer, don't let more accumulate
        }
      }
      onStreamFinished: {
        var parsed = []
        if (!clientsProc.killedForSize) {
          try { parsed = JSON.parse(String(text || "")) || [] } catch (e) { parsed = [] }
        }
        root.windows = root.windowsFromClients(Array.isArray(parsed) ? parsed : [])
        if (root.opened) root.rebuildDisplay()
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ronnie-expose"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.quickLookOpen ? root.toggleQuickLook() : root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(120), Style.space(1200))
      height: Math.min(parent.height - Style.space(120), Style.space(760))
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.quickLookOpen) root.quickLookOpen = false
            else if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Space) {
            root.toggleQuickLook()
            event.accepted = true
          } else if (root.quickLookOpen) {
            // Quick Look is open: swallow everything else so typing doesn't
            // silently edit the filter behind it.
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectRow(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectRow(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Type to search windows…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          GridView {
            id: resultGrid
            anchors.fill: parent
            model: displayModel
            clip: true
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: delegateRoot
              required property int index
              required property string address
              required property string title
              required property string appId
              required property string workspaceName
              required property bool floating
              required property bool fullscreen
              required property int wWidth
              required property int wHeight

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: root.cellWidth - Style.space(10)
              height: root.cellHeight - Style.space(10)
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"
              border.width: hasCursor ? 0 : 1
              border.color: Util.alpha(root.foreground, 0.12)

              Column {
                anchors.centerIn: parent
                spacing: Style.space(8)
                width: parent.width - Style.space(16)

                Image {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(56)
                  height: Style.space(56)
                  source: root.iconSource(delegateRoot.appId)
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  asynchronous: true
                }

                Text {
                  width: parent.width
                  text: delegateRoot.title
                  textFormat: Text.PlainText
                  color: delegateRoot.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: delegateRoot.workspaceName + (delegateRoot.floating ? " · float" : "") + (delegateRoot.fullscreen ? " · full" : "")
                  textFormat: Text.PlainText
                  color: delegateRoot.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.selectedIndex = delegateRoot.index
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = delegateRoot.index
                  root.activateIndex(delegateRoot.index)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: root.filterText ? ("No windows match “" + root.filterText + "”") : "No open windows"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        Text {
          width: parent.width
          height: root.footerHeight
          verticalAlignment: Text.AlignVCenter
          horizontalAlignment: Text.AlignHCenter
          text: "↵ focus window   ·   space quick look   ·   esc close"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Quick Look: an enlarged inspector for the highlighted window, in the
    // spirit of macOS Space-to-preview. There is no live window-thumbnail
    // capture available to the shell, so this shows the app icon at large
    // size plus full metadata rather than a pixel-accurate screenshot.
    Rectangle {
      id: quickLook
      visible: root.quickLookOpen && root.selectedIndex < root.filteredWindows.length
      anchors.centerIn: parent
      width: Style.space(520)
      height: Style.space(380)
      radius: root.cornerRadius
      color: root.background
      border.width: 1
      border.color: root.border

      readonly property var w: (root.quickLookOpen && root.selectedIndex < root.filteredWindows.length) ? root.filteredWindows[root.selectedIndex] : null

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.centerIn: parent
        spacing: Style.space(14)
        width: parent.width - Style.space(48)

        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(112)
          height: Style.space(112)
          source: quickLook.w ? root.iconSource(quickLook.w.appId) : ""
          fillMode: Image.PreserveAspectFit
          smooth: true
          asynchronous: true
        }

        Text {
          width: parent.width
          text: quickLook.w ? quickLook.w.title : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: quickLook.w ? quickLook.w.appId : ""
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: quickLook.w
            ? ("Workspace " + quickLook.w.workspaceName
               + "  ·  " + quickLook.w.wWidth + "×" + quickLook.w.wHeight
               + (quickLook.w.floating ? "  ·  floating" : "")
               + (quickLook.w.fullscreen ? "  ·  fullscreen" : "")
               + (quickLook.w.xwayland ? "  ·  XWayland" : "")
               + (quickLook.w.pid ? ("  ·  pid " + quickLook.w.pid) : ""))
            : ""
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
