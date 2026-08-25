import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// Phosphor icons (MIT), regular weight, rendered from their own path data.
//
// The path strings below are lifted verbatim from phosphor-icons/core, so
// these are the real icons rather than approximations. They are drawn through
// QtQuick.Shapes instead of loading .svg files: Qt's SVG renderer is
// unreliable at small sizes, and this keeps the plugin self-contained with no
// asset files to ship or lose.
//
// Every Phosphor icon is authored on a 256x256 canvas, so one scale factor
// maps any of them to the requested size.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  // Key into `icons` below.
  property string icon: "ear"

  readonly property var icons: ({
    "headphones": "M201.89,54.66A103.43,103.43,0,0,0,128.79,24H128A104,104,0,0,0,24,128v56a24,24,0,0,0,24,24H64a24,24,0,0,0,24-24V144a24,24,0,0,0-24-24H40.36A88,88,0,0,1,128,40h.67a87.71,87.71,0,0,1,87,80H192a24,24,0,0,0-24,24v40a24,24,0,0,0,24,24h16a24,24,0,0,0,24-24V128A103.41,103.41,0,0,0,201.89,54.66ZM64,136a8,8,0,0,1,8,8v40a8,8,0,0,1-8,8H48a8,8,0,0,1-8-8V136Zm152,48a8,8,0,0,1-8,8H192a8,8,0,0,1-8-8V144a8,8,0,0,1,8-8h24Z",
    "ear": "M216,104a8,8,0,0,1-16,0,72,72,0,0,0-144,0c0,26.7,8.53,34.92,17.57,43.64C82.21,156,92,165.41,92,188a36,36,0,0,0,36,36c10.24,0,18.45-4.16,25.83-13.09a8,8,0,1,1,12.34,10.18C155.81,233.64,143,240,128,240a52.06,52.06,0,0,1-52-52c0-15.79-5.68-21.27-13.54-28.84C52.46,149.5,40,137.5,40,104a88,88,0,0,1,176,0Zm-38.13,57.08A8,8,0,0,0,166.93,164,8,8,0,0,1,152,160c0-9.33,4.82-15.76,10.4-23.2,6.37-8.5,13.6-18.13,13.6-32.8a48,48,0,0,0-96,0,8,8,0,0,0,16,0,32,32,0,0,1,64,0c0,9.33-4.82,15.76-10.4,23.2-6.37,8.5-13.6,18.13-13.6,32.8a24,24,0,0,0,44.78,12A8,8,0,0,0,177.87,161.08Z",
    "ear-slash": "M213.92,210.62a8,8,0,1,1-11.84,10.76l-35-38.45A24,24,0,0,1,136,160a40.83,40.83,0,0,1,1.21-10L96,104.66A8,8,0,0,1,80,104a47.84,47.84,0,0,1,2.22-14.46L64.5,70A71.47,71.47,0,0,0,56,104c0,26.7,8.53,34.92,17.57,43.64C82.21,156,92,165.41,92,188a36,36,0,0,0,36,36c10.24,0,18.45-4.16,25.83-13.09a8,8,0,1,1,12.34,10.18C155.81,233.64,143,240,128,240a52.06,52.06,0,0,1-52-52c0-15.79-5.68-21.27-13.54-28.84C52.46,149.5,40,137.5,40,104A87.26,87.26,0,0,1,53.21,57.62L42.08,45.38A8,8,0,1,1,53.92,34.62ZM91.09,42.17A72,72,0,0,1,200,104a8,8,0,0,0,16,0A88,88,0,0,0,82.87,28.44a8,8,0,1,0,8.22,13.73Zm69.23,85a8,8,0,0,0,10.78-3.44A41.93,41.93,0,0,0,176,104a48,48,0,0,0-63.57-45.42,8,8,0,0,0,5.19,15.14A32,32,0,0,1,160,104a26,26,0,0,1-3.12,12.34A8,8,0,0,0,160.32,127.12Z",
    "prohibit": "M128,24A104,104,0,1,0,232,128,104.11,104.11,0,0,0,128,24Zm88,104a87.56,87.56,0,0,1-20.41,56.28L71.72,60.4A88,88,0,0,1,216,128ZM40,128A87.56,87.56,0,0,1,60.41,71.72L184.28,195.6A88,88,0,0,1,40,128Z",
    "circle-dashed": "M96.26,37.05A8,8,0,0,1,102,27.29a104.11,104.11,0,0,1,52,0,8,8,0,0,1-2,15.75,8.15,8.15,0,0,1-2-.26,88.09,88.09,0,0,0-44,0A8,8,0,0,1,96.26,37.05ZM53.79,55.14a104.05,104.05,0,0,0-26,45,8,8,0,0,0,15.42,4.27,88,88,0,0,1,22-38.09A8,8,0,0,0,53.79,55.14ZM43.21,151.55a8,8,0,1,0-15.42,4.28,104.12,104.12,0,0,0,26,45,8,8,0,0,0,11.41-11.22A88.14,88.14,0,0,1,43.21,151.55ZM150,213.22a88,88,0,0,1-44,0,8,8,0,1,0-4,15.49,104.11,104.11,0,0,0,52,0,8,8,0,0,0-4-15.49ZM222.65,146a8,8,0,0,0-9.85,5.58,87.91,87.91,0,0,1-22,38.08,8,8,0,1,0,11.42,11.21,104,104,0,0,0,26-45A8,8,0,0,0,222.65,146Zm-9.86-41.54a8,8,0,0,0,15.42-4.28,104,104,0,0,0-26-45,8,8,0,1,0-11.41,11.22A88,88,0,0,1,212.79,104.45Z"
  })

  readonly property string pathData: icons[icon] !== undefined ? icons[icon] : ""
  readonly property real canvas: 256

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // Sized to Phosphor's own 256 canvas and scaled down, rather than sized to
  // the icon and scaled up. Note there is deliberately no layer.enabled here:
  // a layer rasterises the Shape at the item's size BEFORE the transform
  // runs, which clips 256-unit paths down to nothing. CurveRenderer gives the
  // antialiasing the layer would otherwise have provided.
  Shape {
    width: root.canvas
    height: root.canvas
    preferredRendererType: Shape.CurveRenderer

    transform: Scale {
      origin.x: 0
      origin.y: 0
      xScale: root.iconSize / root.canvas
      yScale: root.iconSize / root.canvas
    }

    ShapePath {
      fillColor: root.color
      // Phosphor ships filled shapes, not strokes.
      strokeWidth: -1
      fillRule: ShapePath.WindingFill

      PathSvg { path: root.pathData }
    }
  }
}
