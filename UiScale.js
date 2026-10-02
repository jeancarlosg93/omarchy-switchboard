.pragma library

// Keep shell.json as the sole source of per-plugin configuration.
function entryFromBarConfig(config, id) {
  var layout = config && config.layout
  var sections = ["left", "center", "right"]
  for (var s = 0; layout && s < sections.length; s++) {
    var entries = layout[sections[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (entry && entry.id === id) return entry
    }
  }
  return ({})
}

function fromBarConfig(config, id) {
  // Reject strings, null, NaN and infinities instead of surprising coercion.
  var scale = entryFromBarConfig(config, id).scale
  return typeof scale === "number" && isFinite(scale)
    ? Math.max(0.75, Math.min(2, scale)) : 1
}

function alignmentFromBarConfig(config, id) {
  return entryFromBarConfig(config, id).verticalAlignment === "center" ? "center" : "top"
}

function size(px, scale) {
  return px > 0 ? Math.max(1, Math.round(px * scale)) : 0
}
