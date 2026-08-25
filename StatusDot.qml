import QtQuick
import qs.Commons
import qs.Ui

// Small state light worn by the bar icon. Its own file rather than a colour
// swap on the glyph because the bar has no other cue for the mode: a plain
// headphones mark tells you nothing about whether ANC is on.
//
// Shape carries the state, not just colour: filled for ANC, hollow for
// transparency, drained when off or disconnected. That survives a monochrome
// bar and a colour-blind reader.
//
// Generic shapes, no brand reference.
Item {
  id: root

  property real dotSize: Style.space(7)
  property color accent: "#D71921"
  property color muted: Color.foreground

  // "anc" | "trans" | "off" | "" -- anything else reads as off.
  property string mode: ""

  // Painted behind the dot so it separates from the glyph it overlaps.
  property color outline: "transparent"
  property real outlineWidth: Math.max(1, dotSize * 0.22)

  readonly property bool transparencyMode: mode === "trans"
  readonly property bool ancMode: mode === "anc"

  width: dotSize
  height: dotSize
  implicitWidth: dotSize
  implicitHeight: dotSize

  Rectangle {
    anchors.centerIn: parent
    width: root.dotSize + root.outlineWidth * 2
    height: width
    radius: width / 2
    color: root.outline
  }

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: root.transparencyMode ? "transparent"
         : (root.ancMode ? root.accent
                         : Qt.rgba(root.muted.r, root.muted.g, root.muted.b, 0.5))
    border.width: root.transparencyMode ? Math.max(1, root.dotSize * 0.3) : 0
    border.color: root.accent

    Behavior on color { ColorAnimation { duration: 220 } }
  }
}
