import QtQuick
import qs.Commons
import qs.Ui

// A yes/no question over the panel card. Adapted from the Omarchy shell's
// Ui/ConfirmDialog (MIT, see licenses/omarchy-LICENSE) with the buttons
// centred: the earbuds panel is narrow and a right-anchored pair looks
// pushed against the edge. The message stays left-aligned. Keyboard routing stays in the panel's key catcher
// (Esc cancels, Tab or Left/Right switch, Enter acts on `selectedIndex`).
Item {
  id: root

  property bool opened: false
  property string message: ""
  property string cancelText: "Cancel"
  property string confirmText: "Confirm"
  property int selectedIndex: 1
  property color background: Color.background
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int cornerRadius: Style.cornerRadius

  signal canceled()
  signal confirmed()

  visible: opened

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(root.background, 0.7)

    MouseArea { anchors.fill: parent; onClicked: root.canceled() }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(24), Style.space(370))
      height: card.contentTopInset + card.contentBottomInset
        + messageText.implicitHeight + Style.space(20) + Style.space(34)
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
      padding: Style.space(18)
      radius: root.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Text {
          id: messageText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          text: root.message
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          spacing: Style.space(10)

          Repeater {
            model: [root.cancelText, root.confirmText]

            BorderSurface {
              required property int index
              required property string modelData

              readonly property bool selected: root.selectedIndex === index
              readonly property bool destructive: index === 1

              width: Style.space(88)
              height: Style.space(34)
              color: selected
                ? (destructive ? Util.alpha(root.urgent, 0.22) : Util.alpha(root.foreground, 0.08))
                : "transparent"
              borderSpec: Border.flat(destructive
                ? (selected ? root.urgent : Util.alpha(root.urgent, 0.56))
                : (selected ? root.accent : Util.alpha(root.foreground, 0.38)), Style.normalBorderWidth)
              radius: 0

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: modelData
                color: destructive ? (selected ? root.urgent : root.foreground)
                                   : (selected ? root.accent : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = index
                onClicked: index === 0 ? root.canceled() : root.confirmed()
              }
            }
          }
        }
      }
    }
  }
}
