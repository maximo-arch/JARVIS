import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// J.A.R.V.I.S. popup — frosted glass + Material You.
// Correr:   qs -c jarvis            Mostrar/ocultar:   qs -c jarvis ipc call jarvis toggle
ShellRoot {
    id: root
    property bool open: false
    property string mode: "idle"      // idle | thinking | listening
    property var pal: ({})
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property string colorsPath: Quickshell.env("JARVIS_COLORS")
        || (Quickshell.env("HOME") + "/.local/state/quickshell/user/generated/colors.json")

    // Paleta base M3 (oscura). Si existe colors.json (matugen) se usa esa y cambia con el fondo de pantalla.
    readonly property var fallback: ({
        primary: "#D0BCFF", on_primary: "#381E72", primary_container: "#4F378B",
        on_primary_container: "#EADDFF", secondary_container: "#4A4458", on_secondary_container: "#E8DEF8",
        tertiary_container: "#633B48", on_tertiary_container: "#FFD8E4", surface: "#141218",
        surface_container_high: "#2B2930", on_surface: "#E6E0E9", on_surface_variant: "#CAC4D0",
        outline_variant: "#49454F", error: "#F2B8B5"
    })
    function c(name) {
        const camel = "m3" + name.split("_").map(s => s[0].toUpperCase() + s.slice(1)).join("")
        return pal[name] || pal[camel] || fallback[name]
    }
    readonly property var emphasized: [0.05, 0.7, 0.1, 1, 1, 1]

    FileView {
        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { root.pal = JSON.parse(text()) } catch (e) {} }
    }

    ListModel { id: msgs }

    Socket {
        id: sock
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/jarvis.sock"
        connected: true
        parser: SplitParser { onRead: line => root.onEvent(JSON.parse(line)) }
    }
    Timer {
        interval: 2000; repeat: true; running: !sock.connected
        onTriggered: { sock.connected = false; sock.connected = true }
    }
    function send(o) { sock.write(JSON.stringify(o) + "\n"); sock.flush() }
    function submit(t) {
        t = t.trim()
        if (!t) return
        msgs.append({ kind: "user", text: t })
        send({ type: "user", text: t })
        mode = "thinking"
    }
    function onEvent(e) {
        if (e.type === "status") mode = e.state
        else if (e.type === "user") msgs.append({ kind: "user", text: e.text })
        else if (e.type === "assistant") msgs.append({ kind: "jarvis", text: e.text })
        else if (e.type === "tool") msgs.append({ kind: "tool", text: e.name + "  " + e.detail })
        else if (e.type === "error") msgs.append({ kind: "error", text: e.text })
    }

    IpcHandler {
        target: "jarvis"
        function toggle(): void { root.open = !root.open }
        function show(): void { root.open = true }
        function hide(): void { root.open = false }
    }

    component IconBtn: Rectangle {
        property string icon
        property string family
        property color fg
        property color bg: "transparent"
        signal clicked
        implicitWidth: 40; implicitHeight: 40; radius: 20; color: bg
        Rectangle {
            anchors.fill: parent; radius: parent.radius; color: parent.fg
            opacity: ma.pressed ? 0.14 : ma.containsMouse ? 0.08 : 0
        }
        Text { anchors.centerIn: parent; text: parent.icon; font.family: parent.family; font.pixelSize: 22; color: parent.fg }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }

    PanelWindow {
        id: win
        visible: root.open || card.opacity > 0.01
        color: "transparent"
        anchors { top: true }
        margins { top: 120 }
        implicitWidth: 680
        implicitHeight: 660
        exclusionMode: ExclusionMode.Ignore
        mask: Region { item: card }
        WlrLayershell.namespace: "jarvis"      // <- apuntá el blur de Hyprland a este namespace
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Connections {
            target: root
            function onOpenChanged() { if (root.open) field.forceActiveFocus() }
        }

        Rectangle {
            id: card
            width: parent.width - 32
            anchors.horizontalCenter: parent.horizontalCenter
            height: Math.min(620, content.implicitHeight + 24)
            y: root.open ? 0 : 18
            opacity: root.open ? 1 : 0
            scale: root.open ? 1 : 0.96
            radius: 32
            color: Qt.alpha(root.c("surface"), 0.58)          // translúcido: el blur del compositor se ve a través
            border.width: 1
            border.color: Qt.alpha(root.c("on_surface"), 0.12)
            Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized } }
            Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized } }
            Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized } }
            Behavior on opacity { NumberAnimation { duration: 200 } }

            // brillo superior sutil (efecto vidrio)
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.alpha("white", 0.10) }
                    GradientStop { position: 0.35; color: Qt.alpha("white", 0.0) }
                }
            }

            ColumnLayout {
                id: content
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    visible: msgs.count > 0 || root.mode !== "idle"
                    Text {
                        text: "J.A.R.V.I.S."; Layout.leftMargin: 8
                        color: root.c("on_surface"); font.pixelSize: 16; font.weight: Font.Medium
                    }
                    Rectangle {
                        radius: 10; color: root.c("secondary_container")
                        implicitWidth: st.implicitWidth + 20; implicitHeight: 24
                        Text { id: st; anchors.centerIn: parent; text: root.mode; font.pixelSize: 12; color: root.c("on_secondary_container") }
                    }
                    Item { Layout.fillWidth: true }
                    IconBtn { icon: "delete_sweep"; family: root.iconFont; fg: root.c("on_surface_variant"); onClicked: { msgs.clear(); root.send({ type: "clear" }) } }
                    IconBtn { icon: "close"; family: root.iconFont; fg: root.c("on_surface_variant"); onClicked: root.open = false }
                }

                // barra de progreso indeterminada M3
                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: 4; clip: true
                    visible: root.mode !== "idle"
                    Rectangle {
                        id: bar; height: 4; radius: 2; width: parent.width * 0.3; color: root.c("primary")
                        SequentialAnimation on x {
                            loops: Animation.Infinite; running: root.mode !== "idle"
                            NumberAnimation { from: -bar.width; to: bar.parent.width; duration: 1100; easing.type: Easing.InOutCubic }
                        }
                    }
                }

                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 420)
                    visible: count > 0
                    clip: true; spacing: 6; model: msgs
                    onCountChanged: Qt.callLater(positionViewAtEnd)
                    delegate: Item {
                        width: ListView.view.width
                        height: bubble.height
                        Rectangle {
                            id: bubble
                            readonly property bool mine: model.kind === "user"
                            readonly property bool small: model.kind === "tool"
                            anchors.right: mine ? parent.right : undefined
                            anchors.left: mine ? undefined : parent.left
                            width: label.width + 28
                            height: label.implicitHeight + (small ? 12 : 20)
                            radius: small ? 12 : 20
                            color: mine ? root.c("primary_container")
                                 : small ? root.c("tertiary_container")
                                 : model.kind === "error" ? Qt.alpha(root.c("error"), 0.28)
                                 : Qt.alpha(root.c("surface_container_high"), 0.85)
                            Text {
                                id: label
                                x: 14; anchors.verticalCenter: parent.verticalCenter
                                text: model.text
                                wrapMode: Text.Wrap
                                width: Math.min(implicitWidth, list.width * 0.85 - 28)
                                font.pixelSize: small ? 12 : 15
                                color: bubble.mine ? root.c("on_primary_container")
                                     : bubble.small ? root.c("on_tertiary_container") : root.c("on_surface")
                            }
                        }
                    }
                }

                // campo de entrada tipo pastilla
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 56; radius: 28
                    color: Qt.alpha(root.c("surface_container_high"), 0.8)
                    RowLayout {
                        anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                        spacing: 6
                        IconBtn {
                            id: mic
                            icon: "mic"; family: root.iconFont
                            fg: root.mode === "listening" ? root.c("on_primary") : root.c("on_secondary_container")
                            bg: root.mode === "listening" ? root.c("primary") : root.c("secondary_container")
                            onClicked: root.send({ type: "listen" })
                            SequentialAnimation on scale {
                                loops: Animation.Infinite; running: root.mode === "listening"
                                NumberAnimation { to: 1.12; duration: 500; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutSine }
                            }
                        }
                        TextInput {
                            id: field
                            Layout.fillWidth: true
                            color: root.c("on_surface"); font.pixelSize: 16
                            clip: true; selectByMouse: true
                            onAccepted: { root.submit(text); text = "" }
                            Keys.onEscapePressed: root.open = false
                            Text {
                                visible: !field.text
                                text: "Ask J.A.R.V.I.S."
                                color: root.c("on_surface_variant"); font: field.font
                            }
                        }
                        IconBtn {
                            icon: "arrow_upward"; family: root.iconFont
                            fg: root.c("on_primary"); bg: root.c("primary")
                            onClicked: { root.submit(field.text); field.text = "" }
                        }
                    }
                }
            }
        }
    }
}
