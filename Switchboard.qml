import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel
import "Keybinds.js" as Keybinds
import "UiScale.js" as UiScale

// Switchboard — a grid launcher for Omarchy.
//
// Same menu definition as the built-in menu (default + user
// omarchy-menu.jsonc, guards, providers, apps), different surface:
//
//   * items sit in a grid; typing always searches the current menu and its
//     children, arrows move, Enter opens, Escape clears / goes up / closes
//   * tiles show the global Hyprland shortcut that opens the same thing
//   * `!cmd` runs a shell command in a new terminal; `~/path` or `/path`
//     opens it with xdg-open
//   * the footer shows a rotating shortcut tip
//
// It also serves the `select` / `input` payloads that `omarchy-menu-select`
// and friends send to `omarchy.menu`, since enabling this plugin routes that
// id here (see manifest `omarchy.clonedFrom`).
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  // The injected manifest is the public copy, which strips __sourceDir, so
  // locate the plugin's scripts/ from this QML file's own URL instead.
  readonly property string pluginDir: {
    var fromManifest = manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
    if (fromManifest) return fromManifest
    var url = String(Qt.resolvedUrl("."))
    return url.length > 0 && url.indexOf("file://") === 0 ? url.slice(7) : ""
  }

  // --------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    if (payload.mode === "select" || payload.mode === "input") {
      root.openDmenu(payload)
    } else {
      root.openRoute(payload.initialMenu || payload.menu || "root")
    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    root.loadMenuFile(defaultMenuProc, root.defaultMenuPath)
    root.loadMenuFile(userMenuProc, root.userMenuPath)
    root.loadKeybinds(true)
    root.loadStatus()
    return "ok"
  }

  function ping() { return "ok" }

  function scaleInfo() {
    return JSON.stringify({ scale: root.uiScale, cardWidth: root.cardWidth,
      bodySize: root.scaledSize(Style.font.body) })
  }

  function appMonogram(label) {
    var words = String(label || "").replace(/([a-z])([A-Z])/g, "$1 $2").trim().split(/[\s._-]+/)
    var first = Array.from(words[0] || "")[0] || "?"
    var last = words.length > 1 ? (Array.from(words[words.length - 1])[0] || "") : ""
    return (first + last).toUpperCase()
  }

  function appMonogramColor(appId) {
    var hash = 0
    var value = String(appId || "")
    for (var i = 0; i < value.length; i++) hash = (hash * 31 + value.charCodeAt(i)) | 0
    // A stable hue per desktop ID, with a dark background for white lettering.
    return Qt.hsla((hash >>> 0) % 360 / 360, 0.48, 0.28, 1)
  }

  // Read the existing shell.json entry; no separate plugin config file.
  // Some shell versions do not inject a persistent API into menu plugins.
  property var fallbackBarConfig: ({})
  readonly property var scaleBarConfig: root.shell && root.shell.barConfig
    ? root.shell.barConfig : root.fallbackBarConfig
  readonly property real uiScale: UiScale.fromBarConfig(root.scaleBarConfig, "krall.switchboard")

  function loadScaleConfig(text) {
    try {
      var config = text.length <= 1024 * 1024 ? JSON.parse(text) : null
      root.fallbackBarConfig = config && config.version === 1 ? config.bar || ({}) : ({})
    } catch (e) { root.fallbackBarConfig = ({}) }
  }

  FileView {
    id: scaleConfigFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadScaleConfig(text())
    onFileChanged: reload()
    onLoadFailed: root.fallbackBarConfig = ({})
  }

  function scaledSize(px) { return UiScale.size(px, root.uiScale) }
  function scaledSpace(px) { return root.scaledSize(Style.space(px)) }

  // Row positions are stored in the model rather than bound to tileHeight.
  // Coalesce changes so live resizing also relays out search and select rows.
  onTileHeightChanged: Qt.callLater(root.relayoutDisplay)
  onTileGapChanged: Qt.callLater(root.relayoutDisplay)
  onDividerHeightChanged: Qt.callLater(root.relayoutDisplay)

  function relayoutDisplay() {
    if (root.rowsLoaded) root.rebuildDisplay()
  }

  // ---------------------------------------------------------------- tunables

  readonly property int keybindRefreshSeconds: 30

  // Input bounds. Everything the launcher parses comes from a helper script,
  // a provider, a guard batch, or a menu file — all producer-controlled — so
  // nothing is retained past these caps and no producer can hold the shell.
  readonly property int maxProcessChars: 256 * 1024   // per process output (UTF-16 units; ≤ 1 MiB of UTF-8)
  readonly property int maxProcessRecords: 4000       // lines kept per process
  readonly property int maxMenuFileBytes: 1024 * 1024 // per omarchy-menu.jsonc
  readonly property int providerTimeoutMs: 10 * 1000
  readonly property int guardTimeoutMs: 10 * 1000
  readonly property int helperTimeoutMs: 15 * 1000
  readonly property int updatesTimeoutMs: 120 * 1000
  readonly property int updateCheckMinutes: 30

  // ------------------------------------------------------------------- state

  property string fontFamily: Style.font.menuFamily
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool opened: false
  property string mode: "menu"
  readonly property bool dmenuActive: mode === "select" || mode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property bool requestActive: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property int requestSerial: 0
  property int applySerial: 0
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0
  property int layoutSerial: 0

  // Grid geometry produced by decorateRows(); read by the view.
  property int columns: 2
  property int rowCount: 0
  property int gridContentHeight: 0

  // Global shortcut hints and the footer tip.
  property var binds: []
  property var bindDefaults: ({})
  property var menuShortcuts: ({})
  property var appShortcuts: ({})
  property var tip: null
  property double keybindsLoadedAt: 0

  // Header facts.
  property string themeName: ""
  property string versionText: ""
  property int updateCount: 0

  // Some shell versions leave third-party menus without an injected shell
  // API. Instantiate the packaged library in that case to retain the same
  // app filtering, icons, launch feedback, and removal behavior.
  readonly property var sharedAppLibrary: root.shell ? root.shell.appLibrary : null
  readonly property var appLibrary: sharedAppLibrary || fallbackAppLibrary.item
  Loader {
    id: fallbackAppLibrary
    active: !root.sharedAppLibrary
    source: root.omarchyPath + "/shell/services/AppLibrary.qml"
  }
  onAppLibraryChanged: {
    if (root.rowsLoaded && root.appLibrary) root.mergeAppRows()
  }
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  onOpenedChanged: if (!opened) { deleteConfirmOpen = false; deleteTarget = null }

  // ------------------------------------------------------------------ theme
  //
  // Everything visual comes from the theme's [menu] section in shell.toml,
  // exactly like the built-in menu, so a theme that styles one styles both.

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, root.scaledSpace(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property int cornerRadius: root.scaledSize(Style.cornerRadius)
  readonly property int tileRadius: Math.min(root.cornerRadius, root.scaledSpace(10))
  readonly property real mutedOpacity: 0.5

  // ---------------------------------------------------------------- metrics

  property int contentMargin: root.scaledSize(Style.spacing.panelPadding) + root.scaledSpace(6)
  property int contentSpacing: root.scaledSpace(10)
  property int headerHeight: Math.max(root.scaledSpace(24), root.scaledSize(Style.font.title) + root.scaledSpace(6))
  property int searchHeight: Math.max(root.scaledSpace(38), root.scaledSize(Style.font.heading) + root.scaledSize(Style.spacing.inputPaddingY) * 2 + root.scaledSpace(6))
  property int footerHeight: Math.max(root.scaledSpace(16), root.scaledSize(Style.font.caption) + root.scaledSpace(4))
  property int baseTileHeight: Math.max(root.scaledSpace(36), root.scaledSize(Style.font.body) + root.scaledSize(Style.spacing.rowPaddingX) * 2 - root.scaledSpace(4))
  property int detailTileHeight: Math.max(root.scaledSpace(50), root.scaledSize(Style.font.body) + root.scaledSize(Style.font.caption) + root.scaledSize(Style.spacing.rowPaddingX) * 2 - root.scaledSpace(4))
  property int tileGap: root.scaledSpace(4)
  property int dividerHeight: root.scaledSpace(28)
  property int emptyHeight: root.scaledSpace(96)

  readonly property bool detailRows: root.dmenuActive ? root.dmenuHasDetail : root.filterText.trim().length > 0
  property bool dmenuHasDetail: false
  readonly property int tileHeight: root.detailRows ? root.detailTileHeight : root.baseTileHeight

  property int cardWidth: Math.min(root.dmenuActive ? root.scaledSpace(root.dmenuWidth) : root.scaledSpace(680), panel.width - Style.gapsOut * 2)
  readonly property int chromeHeight: contentMargin * 2 + headerHeight + contentSpacing + searchHeight
    + (root.mode === "input" ? 0 : contentSpacing) + contentSpacing + footerHeight
  readonly property int gridHeight: root.mode === "input" ? 0
    : (displayModel.count === 0 ? root.emptyHeight : Math.min(root.gridContentHeight, root.availableGridHeight))
  readonly property int availableGridHeight: {
    var serial = root.layoutSerial
    // Symmetric: a full-height card leaves the same gap below as above.
    var available = panel.height - panel.cardTop * 2 - root.chromeHeight
    if (root.dmenuActive && root.dmenuMaxHeight > 0) available = Math.min(available, root.scaledSpace(root.dmenuMaxHeight))
    return Math.max(root.baseTileHeight, available)
  }
  readonly property int cardHeight: root.chromeHeight + root.gridHeight

  // ---------------------------------------------------------------- helpers

  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) {
      root.opened = false
      return
    }

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    if (selection === null || selection === undefined) {
      resultProc.command = ["bash", "-c", ": > " + Util.shellQuote(activeDoneFile)]
    } else {
      resultProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(selection) + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    }
    resultProc.running = true
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return
    Util.execDetached(command)
  }

  function item(id) {
    return root.items[id] || null
  }

  function parseMenuJsonc(raw) {
    return MenuModel.parseMenuJsonc(raw)
  }

  function rebuildItemsFromSources() {
    var mergedMenu = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = mergedMenu.items
    root.itemOrder = mergedMenu.itemOrder
    root.rowsLoaded = true
    root.evaluateGuards()
    root.rebuildShortcutIndexes()
    if (root.opened) {
      root.ensureAppRows()
      root.rebuildDisplay()
      if (!root.dmenuActive) {
        if (root.filterText.trim()) root.loadProvidersForSearch()
        else root.loadProviderForMenu(root.activeMenu)
      }
    }
  }

  // ------------------------------------------------------------- providers
  //
  // Identical to the built-in menu: bash enumerators for fonts and power
  // profiles, and the shared AppLibrary for applications.

  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "󰐋",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function mergeAppRows() {
    if (!root.appLibrary) return

    var rows = root.appLibrary.sortedEntries("")
    var appRows = []
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var subtext = root.appLibrary.entrySubtext(entry)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      appRows.push({
        id: "apps." + appId,
        parent: "apps",
        kind: "app",
        icon: "",
        appIcon: String(entry.icon || ""),
        appId: appId,
        label: root.appLibrary.entryName(entry),
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        when: "",
        checked: "",
        order: 0
      })
    }

    var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.rebuildAppShortcuts()
    if (root.opened) root.rebuildDisplay()
  }

  // Searching from the root spans Apps, so app rows are needed before the
  // user ever enters Apps. Loading them is a one-time in-memory merge.
  function ensureAppRows() {
    if (!root.appLibrary || root.providersLoaded["apps"]) return
    root.providersLoaded["apps"] = true
    root.mergeAppRows()
  }

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps") {
      root.providersLoaded[id] = true
      root.mergeAppRows()
      return
    }
    var spec = root.providers[entry.provider]
    if (!spec) return

    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      var rowId = menuId + "." + MenuModel.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startNextProvider() {
    if (providerProc.running) return
    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue
      root.startProviderForMenu(id)
      return
    }
  }

  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps") {
      root.startProviderForMenu(id)
      return
    }
    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }
    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    var active = root.item(root.activeMenu) ? root.activeMenu : "root"
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || !entry.provider || root.providersLoaded[entry.id]) continue
      if (active !== "root" && entry.id !== active && !root.isDescendantOf(entry.id, active)) continue
      root.loadProviderForMenu(entry.id)
    }
  }

  function pathFor(id) { return MenuModel.pathFor(root.items, id) }
  function parentPathFor(id) { return MenuModel.parentPathFor(root.items, id) }
  function isDescendantOf(id, ancestorId) { return MenuModel.isDescendantOf(root.items, id, ancestorId) }
  function isVisible(entry) { return MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry) }
  function matchesQuery(entry, query) { return MenuModel.matchesQuery(entry, query, root.isVisible(entry)) }
  function searchScore(entry, query) { return MenuModel.searchScore(root.items, entry, query) }
  function displayRow(entry, detail, score, section) {
    return MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, detail, score, section)
  }
  function resolveRoute(input) { return MenuModel.resolveRoute(root.items, root.itemOrder, input) }

  // ---------------------------------------------------------- shortcut hints

  function loadKeybinds(force) {
    if (!root.pluginDir || keybindsProc.running) return
    var now = Date.now()
    if (!force && root.keybindsLoadedAt && now - root.keybindsLoadedAt < root.keybindRefreshSeconds * 1000) return
    root.keybindsLoadedAt = now
    keybindsProc.command = [root.pluginDir + "/scripts/keybinds"]
    keybindsProc.running = true
  }

  function applyKeybinds(text) {
    var parsed = Keybinds.parseRecords(text)
    root.binds = parsed.binds
    root.bindDefaults = parsed.defaults
    root.rebuildShortcutIndexes()
    root.pickTip()
    if (root.opened) root.rebuildDisplay()
  }

  function rebuildShortcutIndexes() {
    if (!root.binds.length || !root.rowsLoaded) return
    root.menuShortcuts = Keybinds.menuIndex(root.items, root.itemOrder, root.binds, root.resolveRoute)
    root.rebuildAppShortcuts()
  }

  function rebuildAppShortcuts() {
    if (!root.binds.length || !root.appLibrary) return
    var rows = root.appLibrary.sortedEntries("")
    var entries = []
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      entries.push({ id: String(entry.id || ""), name: String(entry.name || ""), execString: String(entry.execString || "") })
    }
    root.appShortcuts = Keybinds.appIndex(entries, root.binds, root.bindDefaults)
  }

  function pickTip() {
    root.tip = Keybinds.randomTip(root.binds, null)
  }

  function shortcutFor(row) {
    if (row.kind === "app") return root.appShortcuts[row.appId] || ""
    return root.menuShortcuts[row.itemId] || ""
  }

  // ---------------------------------------------------------------- display

  ListModel { id: displayModel }
  ListModel { id: dividerModel }

  // Two columns everywhere, so the card never changes width between menus;
  // select/input payloads are a single list.
  function columnsFor() {
    return root.dmenuActive ? 1 : 2
  }

  function sectionTitle(section) {
    return ""
  }

  // Assigns shortcut hints, then lays the rows out on a grid. Sections
  // (main / drilldown search hits)
  // each start on a fresh row with a divider above them, so a section never
  // shares a row.
  function decorateRows(rows) {
    var cols = root.columnsFor()
    var tileH = root.tileHeight
    var gap = root.tileGap
    dividerModel.clear()

    var y = 0
    var row = 0
    var col = 0
    var previousSection = null

    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      var section = r.section || ""
      var titled = root.sectionTitle(section).length > 0
      if ((previousSection !== null && section !== previousSection) || (previousSection === null && titled)) {
        if (col > 0) { col = 0; row += 1; y += tileH + gap }
        dividerModel.append({ offsetY: y, label: root.sectionTitle(section) })
        y += root.dividerHeight
      }
      r.row = row
      r.col = col
      r.cellY = y
      r.shortcut = root.shortcutFor(r)
      col += 1
      if (col >= cols) { col = 0; row += 1; y += tileH + gap }
      previousSection = section
    }

    root.columns = cols
    root.rowCount = col > 0 ? row + 1 : row
    root.gridContentHeight = rows.length === 0 ? 0 : (col > 0 ? y + tileH : y - gap)
  }

  function appendRows(rows) {
    root.decorateRows(rows)
    for (var k = 0; k < rows.length; k++) {
      var r = rows[k]
      displayModel.append({
        itemId: String(r.itemId || ""),
        kind: String(r.kind || ""),
        icon: String(r.icon || ""),
        iconFont: String(r.iconFont || ""),
        appIcon: String(r.appIcon || ""),
        appId: String(r.appId || ""),
        label: String(r.label || ""),
        target: String(r.target || ""),
        detail: String(r.detail || ""),
        path: String(r.path || ""),
        action: String(r.action || ""),
        childCount: Number(r.childCount || 0),
        section: String(r.section || ""),
        shortcut: String(r.shortcut || ""),
        row: Number(r.row || 0),
        col: Number(r.col || 0),
        cellY: Number(r.cellY || 0)
      })
    }
    root.layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function rebuildDmenuDisplay() {
    displayModel.clear()
    if (root.mode === "input") {
      dividerModel.clear()
      root.gridContentHeight = 0
      root.layoutSerial += 1
      return
    }

    var query = root.filterText.trim().toLowerCase()
    var rows = []
    var anyDetail = false
    for (var i = 0; i < root.dmenuOptions.length; i++) {
      var parts = String(root.dmenuOptions[i] || "").split("\t")
      var icon = parts.length > 1 ? parts.shift() : ""
      var label = parts.shift() || ""
      var detail = parts.join("\t")
      if (query && label.toLowerCase().indexOf(query) < 0
          && detail.toLowerCase().indexOf(query) < 0) continue
      if (detail) anyDetail = true
      rows.push({
        itemId: "dmenu." + i,
        kind: "dmenu",
        icon: icon,
        iconFont: "",
        appIcon: "",
        appId: "",
        label: label,
        target: "",
        detail: detail,
        path: "",
        childCount: 0,
        action: "",
        provider: "",
        score: i,
        section: ""
      })
    }
    root.dmenuHasDetail = anyDetail
    root.appendRows(rows)
  }

  function rebuildDisplay() {
    if (root.dmenuActive) {
      root.rebuildDmenuDisplay()
      return
    }

    displayModel.clear()
    if (!root.rowsLoaded) return

    var active = root.item(root.activeMenu) ? root.activeMenu : "root"
    root.activeMenu = active
    var rows = []
    var query = root.filterText.trim()

    var command = root.commandRow(query)
    if (command) {
      root.appendRows([command])
      return
    }

    if (query) {
      var currentRows = []
      var drilldownRows = []

      for (var i = 0; i < root.itemOrder.length; i++) {
        var entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "root") continue
        if (!root.isDescendantOf(entry.id, active)) continue
        if (!root.matchesQuery(entry, query)) continue

        var detail = root.parentPathFor(entry.id)
        var row = root.displayRow(entry, detail, root.searchScore(entry, query))
        if (entry.parent === active) currentRows.push(row)
        else drilldownRows.push(row)
      }

      var searchSort = function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        return a.path.localeCompare(b.path)
      }
      currentRows.sort(searchSort)
      drilldownRows.sort(searchSort)
      if (currentRows.length > 0 && drilldownRows.length > 0) {
        for (var d = 0; d < drilldownRows.length; d++) drilldownRows[d].section = "drilldown"
      }
      rows = currentRows.concat(drilldownRows)
    } else {
      for (var j = 0; j < root.itemOrder.length; j++) {
        var child = root.item(root.itemOrder[j])
        if (!child || child.parent !== active) continue
        if (!root.isVisible(child)) continue
        rows.push(root.displayRow(child, child.description, child.order))
      }

      if (active === "apps") {
        rows.sort(function(a, b) {
          var aLabel = String(a.label || "").toLowerCase()
          var bLabel = String(b.label || "").toLowerCase()
          if (aLabel < bLabel) return -1
          if (aLabel > bLabel) return 1
          return String(a.itemId || "").localeCompare(String(b.itemId || ""))
        })
      }

    }

    root.appendRows(rows)
  }

  // ---------------------------------------------------------------- commands

  // Two typed escapes, both single tiles that replace the search results:
  //   !cmd    run `cmd` in a new terminal (in the active terminal's directory,
  //           the shell stays open afterwards so the output is readable)
  //   ~/path  open the path with xdg-open (also /path)
  function commandRow(query) {
    if (query.charAt(0) === "!") {
      var cmd = query.slice(1).trim()
      if (!cmd) return null
      return { itemId: "!run", kind: "run", icon: "", label: cmd, detail: "Run in terminal", action: cmd }
    }
    if (query === "~" || query.indexOf("~/") === 0 || query.charAt(0) === "/") {
      return { itemId: "!open", kind: "open", icon: "", label: query, detail: "Open", action: query }
    }
    return null
  }

  function runCommand(kind, action) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    if (kind === "run") {
      Util.execDetached("omarchy-launch-terminal bash -c " + Util.shellQuote('eval "$1"; exec "${SHELL:-bash}"') + " _ " + Util.shellQuote(action))
    } else {
      var path = String(action)
      if (path === "~" || path.indexOf("~/") === 0) path = Quickshell.env("HOME") + path.slice(1)
      Util.execDetached("xdg-open " + Util.shellQuote(path))
    }
  }

  // ------------------------------------------------------------- navigation

  function revealCursor() {
    if (displayModel.count === 0) return
    if (root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var r = displayModel.get(root.selectedIndex)
    var top = r.cellY
    var bottom = r.cellY + root.tileHeight
    // Keep a sliver of the neighbouring row visible so the fold reads as one.
    var reach = Math.round(root.tileHeight * 0.4)
    var maxY = Math.max(0, gridFlick.contentHeight - gridFlick.height)
    if (bottom + reach > gridFlick.contentY + gridFlick.height)
      gridFlick.contentY = Math.min(bottom + reach - gridFlick.height, maxY)
    if (top - reach < gridFlick.contentY)
      gridFlick.contentY = Math.max(top - reach, 0)
  }

  function moveHorizontal(delta) {
    delta = Number(delta) || 0
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    revealCursor()
  }

  function moveVertical(delta) {
    delta = Number(delta) || 0
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
      revealCursor()
      return
    }
    if (root.rowCount <= 1) return
    var current = displayModel.get(selectedIndex)
    var targetRow = (current.row + delta + root.rowCount) % root.rowCount
    // Same column if the row has one, else the closest column to the left.
    var best = -1
    var bestCol = -1
    var first = -1
    for (var i = 0; i < displayModel.count; i++) {
      var r = displayModel.get(i)
      if (r.row !== targetRow) continue
      if (first < 0) first = i
      if (r.col === current.col) { best = i; break }
      if (r.col < current.col && r.col > bestCol) { best = i; bestCol = r.col }
    }
    if (best < 0) best = first
    if (best >= 0) selectedIndex = best
    revealCursor()
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = root.mode !== "input"
    root.disarmPointer()
    if (!root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory, fromPointer) {
    if (!root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    gridFlick.contentY = 0
    if (fromPointer) pointerGate.allowInitialSample()
    else root.disarmPointer()
    root.rebuildDisplay()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
  }

  function goBack() {
    if (root.activeMenu === "root") return false
    if (root.navStack.length > 0) {
      var previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
      root.setActiveMenu(previous, false)
      return true
    }
    var active = root.item(root.activeMenu)
    root.setActiveMenu((active && active.parent) ? active.parent : "root", false)
    return true
  }

  function activateIndex(index, fromPointer) {
    if (root.deleteConfirmOpen) return
    if (root.dmenuActive) {
      if (root.mode === "input") {
        root.applyDmenuSelection(root.filterText)
        return
      }
      if (index < 0 || index >= displayModel.count) return
      var picked = displayModel.get(index)
      root.applyDmenuSelection(picked.detail ? picked.label + "\t" + picked.detail : picked.label)
      return
    }

    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    if (row.kind === "menu" || row.kind === "link") {
      root.setActiveMenu(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "run" || row.kind === "open") {
      root.runCommand(row.kind, row.action)
    } else if (row.kind === "app") {
      var appId = row.appId
      var label = row.label
      applySerial = requestSerial
      opened = false
      filterText = ""
      if (root.appLibrary) root.appLibrary.launch(appId, label)
    } else {
      root.applySelected(row.itemId, row.action)
    }
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "app") return
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target) return
    root.cancel()
    if (root.appLibrary) root.appLibrary.remove(target.appId, target.label)
  }

  function applyDmenuSelection(value) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.finishRequest(value)
  }

  function applySelected(id, action) {
    if (!id) { cancel(); return }
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.runAction(action)
  }

  function cancel() {
    if (root.dmenuActive) root.finishRequest(null)
    opened = false
    filterText = ""
  }

  function openExistingMenu(initialMenu) {
    requestSerial += 1
    mode = "menu"
    requestActive = false
    selectionFile = ""
    doneFile = ""
    activeMenu = root.item(initialMenu) ? initialMenu : "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = true
    gridFlick.contentY = 0
    root.disarmPointer()
    root.evaluateGuards()
    root.ensureAppRows()
    root.pickTip()
    opened = true
    rebuildDisplay()
    invalidateVolatileProvider(activeMenu)
    loadProviderForMenu(activeMenu)
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.loadKeybinds(false)
    root.loadStatus()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openDmenu(payload) {
    requestSerial += 1
    mode = payload.mode === "input" ? "input" : "select"
    dmenuPrompt = String(payload.prompt || (mode === "input" ? "Input" : "Select"))
    dmenuOptions = Array.isArray(payload.options) ? payload.options : []
    selectionFile = String(payload.selectionFile || "")
    doneFile = String(payload.doneFile || "")
    requestActive = !!doneFile
    dmenuWidth = Math.max(1, Number(payload.width || 300))
    dmenuMaxHeight = Math.max(0, Number(payload.maxHeight || 0))
    activeMenu = "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = mode !== "input"
    gridFlick.contentY = 0
    root.disarmPointer()
    opened = true
    rebuildDisplay()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openRoute(initialMenu) {
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    if (entry && entry.kind === "action" && entry.action) {
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    root.openExistingMenu(id)
    return "ok"
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function headerTitle() {
    if (root.dmenuActive) return root.dmenuPrompt
    if (root.activeMenu === "root" || !root.item(root.activeMenu)) return "Omarchy"
    return root.pathFor(root.activeMenu)
  }

  function statusText() {
    if (root.dmenuActive) return ""
    var parts = []
    if (root.themeName) parts.push(root.themeName)
    if (root.versionText) parts.push("v" + root.versionText)
    if (root.updateCount > 0) parts.push("󰚰 " + root.updateCount + (root.updateCount === 1 ? " update" : " updates"))
    return parts.join("  ·  ")
  }

  function footerHint() {
    if (root.mode === "input") return "⏎ confirm   esc cancel"
    if (root.dmenuActive) return "type to filter   ↑↓ move   ⏎ select   esc cancel"
    if (root.filterText.charAt(0) === "!") return "⏎ run in terminal   esc clear"
    if (root.filterText) return "↑↓←→ move   ⏎ open   esc clear"
    var hint = "type to search   ↑↓←→ move   ⏎ open"
    return hint + "   esc " + (root.activeMenu === "root" ? "close" : "back")
  }

  function tipText() {
    if (root.dmenuActive || !root.tip) return ""
    return "󰛨 " + root.tip.pretty + " → " + root.tip.description
  }

  function searchPlaceholder() {
    if (root.mode === "input") return root.dmenuPrompt + "…"
    if (root.dmenuActive) return "Filter " + root.dmenuPrompt.toLowerCase() + "…"
    var active = root.item(root.activeMenu)
    return (root.activeMenu === "root" || !active) ? "Search" : "Search " + (active.title || active.label)
  }

  // -------------------------------------------------------------- processes

  // Every producer runs through this. Output is kept line by line only up to
  // maxProcessChars / maxProcessRecords; past either cap the producer is
  // killed and its output dropped. A deadline kills producers that never
  // exit. Consumers read `collected` only when `ok` is true.
  component BoundedProcess: Process {
    id: proc
    property int deadlineMs: root.helperTimeoutMs
    property string collected: ""
    property int records: 0
    property bool overflow: false
    property bool timedOut: false
    readonly property bool ok: !overflow && !timedOut

    stdout: SplitParser {
      onRead: function(data) {
        if (proc.overflow || proc.timedOut) return
        if (proc.records >= root.maxProcessRecords || proc.collected.length + data.length + 1 > root.maxProcessChars) {
          proc.overflow = true
          proc.collected = ""
          proc.running = false
          return
        }
        proc.collected += data + "\n"
        proc.records += 1
      }
    }

    onRunningChanged: {
      if (running) {
        collected = ""
        records = 0
        overflow = false
        timedOut = false
        deadline.restart()
      } else {
        deadline.stop()
      }
    }

    // A typed property rather than a child: Process has no default property.
    property Timer deadline: Timer {
      interval: proc.deadlineMs
      onTriggered: {
        proc.timedOut = true
        proc.collected = ""
        proc.running = false
      }
    }
  }

  BoundedProcess {
    id: providerProc
    deadlineMs: root.providerTimeoutMs
    property string menuId: ""
    property string providerKey: ""
    property int revision: 0
    onExited: {
      if (providerProc.ok && providerProc.revision === root.providerRevision) {
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
        if (root.filterText.trim()) root.loadProvidersForSearch()
      }
      providerProc.collected = ""
      root.startNextProvider()
    }
  }

  Process {
    id: resultProc
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  BoundedProcess {
    id: keybindsProc
    onExited: {
      if (keybindsProc.ok) root.applyKeybinds(keybindsProc.collected)
      keybindsProc.collected = ""
    }
  }

  BoundedProcess {
    id: statusProc
    onExited: {
      if (!statusProc.ok) return
      var lines = statusProc.collected.split("\n")
      statusProc.collected = ""
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split("\t")
        if (parts[0] === "theme") root.themeName = String(parts[1] || "").trim().slice(0, 80)
        else if (parts[0] === "version") root.versionText = String(parts[1] || "").trim().slice(0, 40)
      }
    }
  }

  BoundedProcess {
    id: updatesProc
    deadlineMs: root.updatesTimeoutMs
    onExited: {
      if (!updatesProc.ok) return
      var n = parseInt(updatesProc.collected.trim(), 10)
      updatesProc.collected = ""
      root.updateCount = isFinite(n) && n >= 0 ? Math.min(n, 9999) : 0
    }
  }

  // Menu definitions are read through scripts/read-file, which refuses
  // symlinks, non-regular files, and anything over maxMenuFileBytes, and
  // opens with O_NOFOLLOW. The FileViews below only watch for changes; they
  // never load the file themselves (preload: false).
  function loadMenuFile(proc, path) {
    if (!root.pluginDir || !path) return
    if (proc.running) { proc.reloadPending = true; return }
    proc.reloadPending = false
    proc.command = [root.pluginDir + "/scripts/read-file", path, String(root.maxMenuFileBytes)]
    proc.running = true
  }

  BoundedProcess {
    id: defaultMenuProc
    property bool reloadPending: false
    onExited: function(exitCode) {
      root.defaultMenuItems = (defaultMenuProc.ok && exitCode === 0) ? root.parseMenuJsonc(defaultMenuProc.collected) : []
      defaultMenuProc.collected = ""
      root.rebuildItemsFromSources()
      if (defaultMenuProc.reloadPending) Qt.callLater(function() { root.loadMenuFile(defaultMenuProc, root.defaultMenuPath) })
    }
  }

  BoundedProcess {
    id: userMenuProc
    property bool reloadPending: false
    onExited: function(exitCode) {
      root.userMenuItems = (userMenuProc.ok && exitCode === 0) ? root.parseMenuJsonc(userMenuProc.collected) : []
      userMenuProc.collected = ""
      root.rebuildItemsFromSources()
      if (userMenuProc.reloadPending) Qt.callLater(function() { root.loadMenuFile(userMenuProc, root.userMenuPath) })
    }
  }

  // The bar already checks for updates at startup; wait a bit so two
  // `checkupdates` runs don't race, then keep the count fresh.
  Timer {
    id: updatesTimer
    interval: 90 * 1000
    repeat: true
    running: root.pluginDir !== ""
    onTriggered: {
      root.loadUpdates()
      interval = root.updateCheckMinutes * 60 * 1000
    }
  }

  function loadStatus() {
    if (!root.pluginDir || statusProc.running) return
    statusProc.command = [root.pluginDir + "/scripts/status"]
    statusProc.running = true
  }

  function loadUpdates() {
    if (!root.pluginDir || updatesProc.running) return
    updatesProc.command = [root.pluginDir + "/scripts/updates"]
    updatesProc.running = true
  }

  // Give the shell a beat after (re)loading the plugin before spawning the
  // helper scripts; starting them inside the load itself fails intermittently.
  Timer {
    id: bootTimer
    interval: 250
    onTriggered: {
      root.loadMenuFile(defaultMenuProc, root.defaultMenuPath)
      root.loadMenuFile(userMenuProc, root.userMenuPath)
      root.loadKeybinds(true)
      root.loadStatus()
    }
  }
  onPluginDirChanged: if (root.pluginDir) bootTimer.restart()

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.mergeAppRows()
      else root.rebuildAppShortcuts()
    }
  }

  FileView {
    id: defaultMenuWatch
    path: root.defaultMenuPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.loadMenuFile(defaultMenuProc, root.defaultMenuPath)
  }

  FileView {
    id: userMenuWatch
    path: root.userMenuPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.loadMenuFile(userMenuProc, root.userMenuPath)
  }

  // ------------------------------------------------------------------ guards
  //
  // `when:` / `checked:` are batched into one bash run, same as the built-in
  // menu. See MenuModel.guardScript for the details.

  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false

  function evaluateGuards() {
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  BoundedProcess {
    id: guardProc
    deadlineMs: root.guardTimeoutMs
    onExited: function(exitCode, exitStatus) {
      if (!guardProc.ok || exitCode !== 0 || exitStatus !== 0) {
        guardProc.collected = ""
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardProc.collected.split("\n")
      guardProc.collected = ""
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (root.opened) root.rebuildDisplay()
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  // --------------------------------------------------------------- surface

  PanelWindow {
    id: panel
    visible: root.opened && root.rowsLoaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The card hangs from a fixed line in the upper part of the screen and
    // grows downward, so moving between menus never makes it jump.
    readonly property int cardTop: Math.max(Style.gapsOut, Math.round(height * 0.20))

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut - panel.cardTop)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.cardTop
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.deleteConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.dmenuActive) root.cancel()
            else if (root.filterText) root.setFilter("")
            else if (!root.goBack()) root.cancel()
            event.accepted = true
          } else if (event.key === Qt.Key_Delete && !root.filterText) {
            root.requestDeleteSelected()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace) {
            if (!root.dmenuActive) root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveVertical(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveVertical(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.moveHorizontal(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.moveHorizontal(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.moveHorizontal(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Backtab) {
            root.moveHorizontal(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.moveVertical(-3)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.moveVertical(3)
            event.accepted = true
          } else if (event.key === Qt.Key_Home && !root.filterText) {
            root.cursorActive = true; root.selectedIndex = 0; root.revealCursor()
            event.accepted = true
          } else if (event.key === Qt.Key_End && !root.filterText) {
            root.cursorActive = true; root.selectedIndex = Math.max(0, displayModel.count - 1); root.revealCursor()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.mode === "input") root.applyDmenuSelection(root.filterText)
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.activateIndex(0)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: deleteConfirm
          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Do you want to uninstall " + ((root.deleteTarget && root.deleteTarget.label) || "") + "?"
          confirmText: "Uninstall"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ---- header: logo, title / breadcrumb, status
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: logo
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            font.family: "omarchy"
            font.pixelSize: root.scaledSize(Style.font.icon)
            color: root.selectedText
          }

          Text {
            anchors.left: logo.right
            anchors.leftMargin: root.scaledSpace(8)
            anchors.right: statusLabel.left
            anchors.rightMargin: root.scaledSpace(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.headerTitle()
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.scaledSize(Style.font.title)
            font.weight: Font.Medium
            elide: Text.ElideLeft
          }

          Text {
            id: statusLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * 0.55)
            text: root.statusText()
            color: root.foreground
            opacity: root.mutedOpacity
            font.family: root.fontFamily
            font.pixelSize: root.scaledSize(Style.font.caption)
            elide: Text.ElideLeft
            horizontalAlignment: Text.AlignRight
          }
        }

        // ---- search box
        BorderSurface {
          id: searchBox
          width: parent.width
          height: root.searchHeight
          radius: root.tileRadius
          readonly property bool active: root.filterText.length > 0
          color: Util.alpha(root.foreground, active ? 0.06 : 0.03)
          borderSpec: Border.flat(active ? root.selectedText : Util.alpha(root.foreground, 0.22), Math.max(1, Style.normalBorderWidth))

          Text {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: root.scaledSpace(12)
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: searchBox.active ? root.selectedText : root.foreground
            opacity: searchBox.active ? 1 : 0.6
            font.family: root.fontFamily
            font.pixelSize: root.scaledSize(Style.font.title)
          }

          Text {
            id: searchText
            anchors.left: searchGlyph.right
            anchors.leftMargin: root.scaledSpace(10)
            anchors.right: parent.right
            anchors.rightMargin: root.scaledSpace(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || root.searchPlaceholder()
            color: root.foreground
            opacity: root.filterText ? 1 : 0.45
            font.family: root.fontFamily
            font.pixelSize: root.scaledSize(Style.font.heading)
            elide: Text.ElideRight
          }

          Rectangle {
            id: caret
            visible: true
            x: searchText.x + (root.filterText ? Math.min(searchText.contentWidth, searchText.width) + root.scaledSpace(2) : 0)
            width: Math.max(1, root.scaledSpace(2))
            height: root.scaledSize(Style.font.heading) + root.scaledSpace(4)
            anchors.verticalCenter: parent.verticalCenter
            color: root.selectedText
            SequentialAnimation on opacity {
              running: caret.visible
              loops: Animation.Infinite
              NumberAnimation { to: 0; duration: 500 }
              NumberAnimation { to: 1; duration: 500 }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: keyCatcher.forceActiveFocus()
          }
        }

        // ---- grid
        Item {
          id: gridArea
          width: parent.width
          height: root.gridHeight
          visible: root.mode !== "input"

          readonly property int cellWidth: Math.max(1, Math.floor((width - (root.columns - 1) * root.tileGap) / root.columns))

          Flickable {
            id: gridFlick
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: root.gridContentHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Repeater {
              model: dividerModel
              delegate: Item {
                required property int offsetY
                required property string label

                y: offsetY
                width: gridFlick.width
                height: root.dividerHeight

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: dividerLabel.visible ? dividerLabel.left : parent.right
                  anchors.rightMargin: dividerLabel.visible ? root.scaledSpace(10) : 0
                  anchors.verticalCenter: parent.verticalCenter
                  height: root.scaledSize(Style.spacing.hairline)
                  color: Util.alpha(root.foreground, 0.18)
                }

                Text {
                  id: dividerLabel
                  visible: label.length > 0
                  anchors.right: parent.right
                  anchors.rightMargin: root.scaledSpace(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: label
                  color: root.foreground
                  opacity: root.mutedOpacity
                  font.family: root.fontFamily
                  font.pixelSize: root.scaledSize(Style.font.caption)
                  font.letterSpacing: 1
                  font.capitalization: Font.AllUppercase
                }
              }
            }

            Repeater {
              model: displayModel
              delegate: BorderSurface {
                id: tile
                required property int index
                required property string itemId
                required property string kind
                required property string icon
                required property string iconFont
                required property string appIcon
                required property string appId
                required property string label
                required property string detail
                required property string shortcut
                required property int col
                required property int cellY

                readonly property bool hasCursor: root.cursorActive && tile.index === root.selectedIndex
                readonly property bool isApp: tile.kind === "app"
                readonly property bool isMenu: tile.kind === "menu" || tile.kind === "link"
                readonly property bool hasIcon: tile.icon.length > 0 || tile.isApp
                readonly property color textColor: hasCursor ? root.selectedText : root.foreground

                x: tile.col * (gridArea.cellWidth + root.tileGap)
                y: tile.cellY
                width: gridArea.cellWidth
                height: root.tileHeight
                radius: root.tileRadius
                color: tile.hasCursor ? root.selectedBackground : "transparent"
                borderSpec: tile.hasCursor ? root.selectedBorderSpec : Border.none()

                Text {
                  id: iconText
                  visible: tile.hasIcon && !tile.isApp
                  text: tile.icon
                  color: tile.textColor
                  font.family: tile.iconFont.length > 0 ? tile.iconFont : root.fontFamily
                  font.pixelSize: root.scaledSize(Style.font.icon)
                  width: root.scaledSpace(24)
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  anchors.left: parent.left
                  anchors.leftMargin: root.scaledSpace(10)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Image {
                  id: appImage
                  visible: tile.isApp && status === Image.Ready
                  width: root.scaledSize(Style.font.iconLarge)
                  height: root.scaledSize(Style.font.iconLarge)
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  source: tile.isApp && root.appLibrary ? root.appLibrary.iconSource(tile.appIcon) : ""
                  asynchronous: true
                  anchors.left: iconText.left
                  anchors.leftMargin: (root.scaledSpace(24) - width) / 2
                  anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                  // Keep the slot filled while loading, and retain the badge
                  // for missing or broken icons without retrying failed URLs.
                  visible: tile.isApp && appImage.status !== Image.Ready
                  anchors.centerIn: appImage
                  width: appImage.width
                  height: appImage.height
                  radius: width * 0.22
                  color: root.appMonogramColor(tile.appId || tile.label)

                  Text {
                    anchors.fill: parent
                    text: root.appMonogram(tile.label)
                    color: "#ffffff"
                    font.family: root.fontFamily
                    font.pixelSize: parent.height * (text.length > 1 ? 0.46 : 0.6)
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                  }
                }

                Column {
                  id: labelColumn
                  anchors.left: tile.hasIcon ? iconText.right : parent.left
                  anchors.leftMargin: tile.hasIcon ? root.scaledSpace(6) : root.scaledSpace(10)
                  anchors.right: trail.left
                  anchors.rightMargin: root.scaledSpace(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: root.scaledSpace(2)

                  Text {
                    width: parent.width
                    text: tile.label
                    color: tile.textColor
                    font.family: root.fontFamily
                    font.pixelSize: root.scaledSize(Style.font.body)
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: root.detailRows && tile.detail.length > 0
                    text: tile.detail
                    color: root.foreground
                    opacity: root.mutedOpacity
                    font.family: root.fontFamily
                    font.pixelSize: root.scaledSize(Style.font.caption)
                    elide: Text.ElideRight
                  }
                }

                Row {
                  id: trail
                  anchors.right: parent.right
                  anchors.rightMargin: root.scaledSpace(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: root.scaledSpace(6)

                  Text {
                    visible: tile.shortcut.length > 0
                    text: tile.shortcut
                    // The label comes first; a hint that would eat it gets clipped.
                    width: Math.min(implicitWidth, Math.floor(tile.width * 0.45))
                    elide: Text.ElideRight
                    color: tile.textColor
                    opacity: tile.hasCursor ? 0.8 : root.mutedOpacity
                    font.family: root.fontFamily
                    font.pixelSize: root.scaledSize(Style.font.caption)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    visible: tile.isMenu
                    text: "›"
                    color: tile.textColor
                    opacity: tile.hasCursor ? 0.8 : 0.36
                    font.family: root.fontFamily
                    font.pixelSize: root.scaledSize(Style.font.heading)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: mouseArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectFromPointer(tile.index, tile, { x: mouseArea.mouseX, y: mouseArea.mouseY })
                  onPositionChanged: function(mouse) { root.selectFromPointer(tile.index, tile, mouse) }
                  onClicked: {
                    root.cursorActive = true
                    root.selectedIndex = tile.index
                    root.activateIndex(tile.index, true)
                  }
                }
              }
            }
          }

          // Fold scrims: fade the clipped edge once content hides past it.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(root.scaledSpace(24), parent.height / 2)
            visible: opacity > 0
            opacity: gridFlick.contentHeight > gridFlick.height ? Math.max(0, Math.min(1, gridFlick.contentY / height)) : 0
            gradient: Gradient {
              GradientStop { position: 0; color: root.background }
              GradientStop { position: 1; color: Util.alpha(root.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(root.scaledSpace(24), parent.height / 2)
            visible: opacity > 0
            opacity: gridFlick.contentHeight > gridFlick.height
              ? Math.max(0, Math.min(1, (gridFlick.contentHeight - gridFlick.height - gridFlick.contentY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.background, 0) }
              GradientStop { position: 1; color: root.background }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: root.scaledSpace(6)
            visible: displayModel.count === 0

            Text {
              text: "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: root.scaledSize(Style.font.displayLarge)
              horizontalAlignment: Text.AlignHCenter
              width: gridArea.width
            }

            Text {
              text: root.filterText ? "No matches for “" + root.filterText + "”" : "Nothing here yet"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: root.scaledSize(Style.font.subtitle)
              horizontalAlignment: Text.AlignHCenter
              width: gridArea.width
            }
          }
        }

        // ---- footer: key hints and a shortcut worth learning
        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            id: hintLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: tipLabel.visible ? tipLabel.left : parent.right
            anchors.rightMargin: root.scaledSpace(12)
            text: root.footerHint()
            color: root.foreground
            opacity: root.mutedOpacity
            font.family: root.fontFamily
            font.pixelSize: root.scaledSize(Style.font.caption)
            elide: Text.ElideRight
          }

          Text {
            id: tipLabel
            visible: text.length > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * 0.5)
            text: root.tipText()
            color: root.selectedText
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: root.scaledSize(Style.font.caption)
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }
}
