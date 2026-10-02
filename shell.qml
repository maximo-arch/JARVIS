import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
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
    // Esquema de Caelestia (Material You generado desde el fondo de pantalla). JARVIS_COLORS lo reemplaza.
    readonly property string colorsPath: Quickshell.env("JARVIS_COLORS")
        || ((Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/caelestia/scheme.json")

    // Paleta base M3 (oscura). Si existe el scheme.json de Caelestia se usa ese y cambia con el fondo de pantalla.
    readonly property var fallback: ({
        primary: "#D0BCFF", on_primary: "#381E72", primary_container: "#4F378B",
        on_primary_container: "#EADDFF", secondary_container: "#4A4458", on_secondary_container: "#E8DEF8",
        tertiary_container: "#633B48", on_tertiary_container: "#FFD8E4", surface: "#141218",
        surface_container_high: "#2B2930", on_surface: "#E6E0E9", on_surface_variant: "#CAC4D0",
        outline_variant: "#49454F", error: "#F2B8B5"
    })
    function c(name) {
        // acepta snake_case, camelCase o m3Pascal; dentro de "colours"/"colors" o en la raíz; con o sin "#"
        const parts = name.split("_")
        const camel = parts[0] + parts.slice(1).map(s => s[0].toUpperCase() + s.slice(1)).join("")
        const src = pal.colours || pal.colors || pal
        const v = src[name] || src[camel] || src["m3" + camel[0].toUpperCase() + camel.slice(1)]
        if (typeof v !== "string" || v === "") return fallback[name]
        return (v[0] === "#" || v.startsWith("rgb")) ? v : "#" + v
    }
    readonly property var emphasized: [0.05, 0.7, 0.1, 1, 1, 1]

    FileView {
        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { root.pal = JSON.parse(text()) } catch (e) {} }
    }

    ListModel { id: msgs }

    // --- Aparecer desde el cursor (Hyprland) ---
    property real glass: 0.30       // opacidad del cristal: más bajo = más transparente (se ve más el efecto del compositor)
    property real winX: 0
    property real winY: 120
    property real curY: 140         // Y del cursor dentro del monitor
    property real originX: 340      // punto de origen de la animación, relativo a la ventana
    property real originY: 0
    property bool useCursor: false
    property var monInfo: null

    Process {
        id: monProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const mons = JSON.parse(text)
                    root.monInfo = mons.find(m => m.focused) || mons[0]
                } catch (e) { root.monInfo = null }
                curProc.running = true
            }
        }
    }
    Process {
        id: curProc
        command: ["hyprctl", "-j", "cursorpos"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.placeAt(JSON.parse(text)) }
                catch (e) { root.dragX = 0; root.dragY = 0; root.originX = -1; root.curY = 140 }
                root.open = true
            }
        }
    }
    function requestOpen() { monProc.running = true }
    property real dragX: 0          // desplazamiento por arrastre (se reinicia al abrir)
    property real dragY: 0
    function placeAt(c) {
        dragX = 0; dragY = 0
        const m = root.monInfo
        if (!m) { originX = -1; curY = 140; return }
        originX = c.x - m.x
        curY = c.y - m.y
    }

    Socket {
        id: sock
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/jarvis.sock"
        connected: true
        parser: SplitParser {
            onRead: line => {
                try { root.onEvent(JSON.parse(line)) }
                catch (err) { console.log("[jarvis] bad event:", err, line) }
            }
        }
        onConnectedChanged: console.log("[jarvis] bridge connected:", connected)
    }
    Timer {
        interval: 2000; repeat: true; running: !sock.connected
        onTriggered: { sock.connected = false; sock.connected = true }
    }
    function send(o) {
        if (!sock.connected) {
            msgs.append({ kind: "error", text: "Not connected to the bridge. Start it with: jarvis-bridge" })
            mode = "idle"
            return false
        }
        sock.write(JSON.stringify(o) + "\n"); sock.flush()
        return true
    }
    function submit(t) {
        t = t.trim()
        if (!t) return
        if (!send({ type: "user", text: t })) return
        msgs.append({ kind: "user", text: t })
        mode = "thinking"
    }
    Timer {
        id: watchdog
        interval: 100000; running: root.mode === "thinking"
        onTriggered: { root.mode = "idle"; msgs.append({ kind: "error", text: "No response from the bridge (timeout)." }) }
    }
    function onEvent(e) {
        console.log("[jarvis] event:", e.type, e.state || "")
        watchdog.restart()
        if (e.type === "status") mode = e.state
        else if (e.type === "user") msgs.append({ kind: "user", text: e.text })
        else if (e.type === "assistant") msgs.append({ kind: "jarvis", text: e.text })
        else if (e.type === "tool") msgs.append({ kind: "tool", text: e.name + "  " + e.detail })
        else if (e.type === "tool_result") msgs.append({ kind: "tool", text: "→ " + e.text })
        else if (e.type === "error") msgs.append({ kind: "error", text: e.text })
    }

    function openFull() { open = false; fullWin.visible = true }

    IpcHandler {
        target: "jarvis"
        function full(): void { root.openFull() }
        function toggle(): void { if (root.open) root.open = false; else root.requestOpen() }
        function show(): void { root.requestOpen() }
        function hide(): void { root.open = false }
    }

    component IconBtn: Rectangle {
        property string icon
        property string family
        property color fg
        property color bg: "transparent"
        signal clicked
        implicitWidth: 40; implicitHeight: 40; radius: 20; color: bg
        Behavior on color { ColorAnimation { duration: 200 } }
        Rectangle {
            anchors.fill: parent; radius: parent.radius; color: parent.fg
            opacity: ma.pressed ? 0.14 : ma.containsMouse ? 0.08 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
        }
        Text {
            anchors.centerIn: parent; text: parent.icon; font.family: parent.family; font.pixelSize: 22; color: parent.fg
            scale: ma.pressed ? 0.82 : 1
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }

    FloatingWindow {
        id: fullWin
        visible: false
        title: "J.A.R.V.I.S."
        color: root.c("surface")
        implicitWidth: 980
        implicitHeight: 720
        onVisibleChanged: if (visible) fullField.forceActiveFocus()

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // Navigation rail M3
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 80
                color: Qt.alpha(root.c("surface_container_high"), 0.7)
                ColumnLayout {
                    anchors { fill: parent; topMargin: 24; bottomMargin: 20 }
                    spacing: 6
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        implicitWidth: 56; implicitHeight: 32; radius: 16
                        color: root.c("secondary_container")
                        Text { anchors.centerIn: parent; text: "chat"; font.family: root.iconFont; font.pixelSize: 24; color: root.c("on_secondary_container") }
                    }
                    Text { Layout.alignment: Qt.AlignHCenter; text: "Chat"; font.pixelSize: 12; color: root.c("on_surface") }
                    IconBtn {
                        Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 16
                        icon: "delete_sweep"; family: root.iconFont; fg: root.c("on_surface_variant")
                        onClicked: { msgs.clear(); root.send({ type: "clear" }) }
                    }
                    Item { Layout.fillHeight: true }
                    IconBtn {
                        Layout.alignment: Qt.AlignHCenter
                        icon: "close_fullscreen"; family: root.iconFont; fg: root.c("on_surface_variant")
                        onClicked: { fullWin.visible = false; root.requestOpen() }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Top app bar
                RowLayout {
                    Layout.fillWidth: true; Layout.margins: 20
                    Text { text: "J.A.R.V.I.S."; color: root.c("on_surface"); font.pixelSize: 22; font.weight: Font.Medium }
                    Rectangle {
                        radius: 10; color: root.c("secondary_container")
                        implicitWidth: fst.implicitWidth + 20; implicitHeight: 24
                        Text { id: fst; anchors.centerIn: parent; text: sock.connected ? root.mode : "offline"; font.pixelSize: 12; color: root.c("on_secondary_container") }
                    }
                    Item { Layout.fillWidth: true }
                }

                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: 4; clip: true
                    visible: root.mode !== "idle"
                    Rectangle {
                        id: fbar; height: 4; radius: 2; width: parent.width * 0.25; color: root.c("primary")
                        SequentialAnimation on x {
                            loops: Animation.Infinite; running: root.mode !== "idle"
                            NumberAnimation { from: -fbar.width; to: fbar.parent.width; duration: 1200; easing.type: Easing.InOutCubic }
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Text {
                        visible: msgs.count === 0
                        anchors.centerIn: parent
                        text: "Good day, Sir."; font.pixelSize: 34; color: root.c("on_surface_variant")
                    }
                    ListView {
                        id: fullList
                        anchors { top: parent.top; bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
                        width: Math.min(760, parent.width - 48)
                        clip: true; spacing: 8; model: msgs
                    add: Transition {
                        ParallelAnimation {
                            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 }
                            NumberAnimation { property: "scale"; from: 0.85; to: 1; duration: 320; easing.type: Easing.OutBack }
                        }
                    }
                    displaced: Transition {
                        NumberAnimation { property: "y"; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized }
                    }
                        onCountChanged: Qt.callLater(positionViewAtEnd)
                        delegate: Item {
                            width: ListView.view.width
                            height: fb.height
                            Rectangle {
                                id: fb
                                readonly property bool mine: model.kind === "user"
                                readonly property bool small: model.kind === "tool"
                                anchors.right: mine ? parent.right : undefined
                                anchors.left: mine ? undefined : parent.left
                                width: ft.width + 32
                                height: ft.implicitHeight + (small ? 12 : 24)
                                radius: small ? 12 : 22
                                border.width: 1; border.color: Qt.alpha("white", 0.16)
                                color: mine ? root.c("primary_container")
                                     : small ? root.c("tertiary_container")
                                     : model.kind === "error" ? Qt.alpha(root.c("error"), 0.28)
                                     : Qt.alpha(root.c("surface_container_high"), 0.9)
                                Text {
                                    id: ft
                                    x: 16; anchors.verticalCenter: parent.verticalCenter
                                    text: model.text
                                    wrapMode: Text.Wrap
                                    width: Math.min(implicitWidth, fullList.width * 0.8 - 32)
                                    font.pixelSize: small ? 13 : 16
                                    color: fb.mine ? root.c("on_primary_container")
                                         : fb.small ? root.c("on_tertiary_container") : root.c("on_surface")
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Math.min(760, parent.width - 48)
                    Layout.topMargin: 12; Layout.bottomMargin: 24
                    implicitHeight: 56; radius: 28
                    border.width: 1; border.color: Qt.alpha("white", 0.18)
                    color: Qt.alpha(root.c("surface_container_high"), 0.9)
                    RowLayout {
                        anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                        spacing: 6
                        IconBtn {
                            icon: "mic"; family: root.iconFont
                            fg: root.mode === "listening" ? root.c("on_primary") : root.c("on_secondary_container")
                            bg: root.mode === "listening" ? root.c("primary") : root.c("secondary_container")
                            onClicked: root.send({ type: "listen" })
                        }
                        TextInput {
                            id: fullField
                            Layout.fillWidth: true
                            color: root.c("on_surface"); font.pixelSize: 16
                            clip: true; selectByMouse: true
                            onAccepted: { root.submit(text); text = "" }
                            Text {
                                visible: !fullField.text
                                text: "Ask J.A.R.V.I.S."
                                color: root.c("on_surface_variant"); font: fullField.font
                            }
                        }
                        IconBtn {
                            icon: root.mode === "idle" ? "arrow_upward" : "stop"; family: root.iconFont
                            fg: root.c("on_primary"); bg: root.c("primary")
                            onClicked: {
                                if (root.mode !== "idle") root.send({ type: "cancel" })
                                else { root.submit(fullField.text); fullField.text = "" }
                            }
                        }
                    }
                }
            }
        }
    }

    PanelWindow {
        id: win
        visible: root.open || card.opacity > 0.01 || spark.opacity > 0.01
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }   // pantalla completa: la tarjeta se puede mover a cualquier lado (solo ella recibe clics)
        exclusionMode: ExclusionMode.Ignore
        mask: Region { item: card }
        WlrLayershell.namespace: "quickshell:jarvis"   // coincide con las reglas .*quickshell.* (blur + hyprglass)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Connections {
            target: root
            function onOpenChanged() {
                if (root.open) { field.forceActiveFocus(); sparkAnim.restart(); cardDelay.restart() }
                else { cardDelay.stop(); card.on = false }
            }
        }
        Timer { id: cardDelay; interval: 220; onTriggered: card.on = true }

        // Destello suave de cuatro puntas: nace en el cursor, acompaña a la gota y se disuelve en la píldora
        Shape {
            id: spark
            z: 2
            x: card.x + card.width / 2 - 64
            y: card.y + card.height / 2 - 64
            width: 128; height: 128
            opacity: 0; scale: 0
            layer.enabled: true
            layer.effect: MultiEffect {
                blurEnabled: true; blurMax: 12; blur: 0.12          // bordes suaves
                shadowEnabled: true; shadowColor: root.c("primary")
                shadowBlur: 1.0; shadowOpacity: 0.75                 // halo
            }
            ShapePath {
                strokeColor: root.c("primary")
                strokeWidth: 5                                      // con unión redonda: puntas redondeadas
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                fillGradient: LinearGradient {
                    x1: 36; y1: 36; x2: 92; y2: 92
                    GradientStop { position: 0.0; color: root.c("on_primary_container") }
                    GradientStop { position: 1.0; color: root.c("primary") }
                }
                startX: 64; startY: 36
                PathQuad { x: 92; y: 64; controlX: 68; controlY: 60 }
                PathQuad { x: 64; y: 92; controlX: 68; controlY: 68 }
                PathQuad { x: 36; y: 64; controlX: 60; controlY: 68 }
                PathQuad { x: 64; y: 36; controlX: 60; controlY: 60 }
            }
            SequentialAnimation {
                id: sparkAnim
                ParallelAnimation {
                    NumberAnimation { target: spark; property: "scale"; from: 0; to: 1; duration: 320; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized }
                    NumberAnimation { target: spark; property: "rotation"; from: -45; to: 0; duration: 440; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized }
                    NumberAnimation { target: spark; property: "opacity"; from: 0; to: 1; duration: 180 }
                }
                ParallelAnimation {
                    NumberAnimation { target: spark; property: "scale"; to: 0.6; duration: 380; easing.type: Easing.InOutCubic }
                    NumberAnimation { target: spark; property: "opacity"; to: 0; duration: 380; easing.type: Easing.InOutCubic }
                }
            }
        }

        Rectangle {
            id: card
            readonly property real fullW: Math.min(648, parent.width - 32)   // ancho de la tarjeta (la ventana ahora es de pantalla completa)
            readonly property real blob: 64
            property bool on: false
            readonly property bool flipUp: root.curY > win.height * 0.6
            readonly property real topEdge: Math.max(12, root.curY - 6)
            readonly property real bottomEdge: Math.min(root.curY + 8, win.height - 12)
            readonly property real maxH: Math.min(620, win.height - 24)
            property real fullH: Math.min(maxH, content.implicitHeight + 24)
            Behavior on fullH { SpringAnimation { spring: 3.2; damping: 0.3; epsilon: 0.25 } }

            // progreso del morfado: primero se estira el ancho (gota -> píldora), después el alto
            property real mx: on ? 1 : 0
            property real my: on ? 1 : 0
            Behavior on mx {
                NumberAnimation {
                    duration: card.on ? 560 : 220
                    easing.type: card.on ? Easing.BezierSpline : Easing.InOutCubic
                    easing.bezierCurve: root.emphasized
                }
            }
            Behavior on my {
                NumberAnimation {
                    duration: card.on ? 680 : 220
                    easing.type: card.on ? Easing.BezierSpline : Easing.InOutCubic
                    easing.bezierCurve: root.emphasized
                }
            }
            width: blob + (fullW - blob) * mx
            height: blob + (fullH - blob) * my
            readonly property real ox: root.originX < 0 ? parent.width / 2 : root.originX
            readonly property real finalCx: Math.max(fullW / 2 + 8, Math.min(ox + root.dragX, parent.width - fullW / 2 - 8))
            readonly property real finalCy: Math.max(fullH / 2 + 8, Math.min((flipUp ? bottomEdge - fullH : topEdge) + fullH / 2 + root.dragY, win.height - fullH / 2 - 8))
            x: (ox + (finalCx - ox) * mx) - width / 2
            y: (root.curY + (finalCy - root.curY) * my) - height / 2
            opacity: on ? 1 : 0
            radius: Math.min(32, Math.min(width, height) / 2)
            color: Qt.alpha(root.c("surface"), root.glass)    // translúcido: el blur/refracción del compositor se ve a través
            Behavior on opacity { NumberAnimation { duration: card.on ? 120 : 140 } }

            // brillo superior sutil (efecto vidrio)
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.alpha("white", 0.10) }
                    GradientStop { position: 0.35; color: Qt.alpha("white", 0.0) }
                }
            }

            // Brillo especular que sigue al puntero (con inercia), recortado a la forma de la tarjeta
            HoverHandler { id: hov }

            // Mover la tarjeta: arrastrá desde cualquier zona libre (márgenes, título) o desde la barrita de arriba
            DragHandler {
                id: dragger
                target: null
                property real x0: 0
                property real y0: 0
                onActiveChanged: if (active) { x0 = root.dragX; y0 = root.dragY }
                onTranslationChanged: if (active) { root.dragX = x0 + translation.x; root.dragY = y0 + translation.y }
            }
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0; width: 96; height: 12
                HoverHandler { cursorShape: dragger.active ? Qt.ClosedHandCursor : Qt.SizeAllCursor }
                Rectangle {
                    anchors.centerIn: parent
                    width: 36; height: 4; radius: 2
                    visible: card.my > 0.9
                    color: Qt.alpha(root.c("on_surface_variant"), dragger.active ? 0.9 : 0.45)
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
            Item { id: glintMask; anchors.fill: parent; visible: false; layer.enabled: true
                Rectangle { anchors.fill: parent; radius: card.radius; color: "black" }
            }
            Item {
                id: glint
                anchors.fill: parent
                opacity: hov.hovered ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
                layer.enabled: true
                layer.effect: MultiEffect { maskEnabled: true; maskSource: glintMask }
                Shape {
                    x: hov.point.position.x - 150
                    y: hov.point.position.y - 150
                    width: 300; height: 300
                    Behavior on x { SpringAnimation { spring: 4; damping: 0.4 } }
                    Behavior on y { SpringAnimation { spring: 4; damping: 0.4 } }
                    ShapePath {
                        strokeColor: "transparent"
                        fillGradient: RadialGradient {
                            centerX: 150; centerY: 150; centerRadius: 150
                            focalX: 150; focalY: 150
                            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.22) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
                        }
                        startX: 0; startY: 0
                        PathLine { x: 300; y: 0 }
                        PathLine { x: 300; y: 300 }
                        PathLine { x: 0; y: 300 }
                        PathLine { x: 0; y: 0 }
                    }
                }
            }

            ColumnLayout {
                id: content
                x: (card.width - width) / 2
                y: 12
                width: card.fullW - 24
                visible: opacity > 0.01
                spacing: 8
                opacity: card.on ? 1 : 0
                Behavior on opacity {
                    SequentialAnimation {
                        PauseAnimation { duration: card.on ? 260 : 0 }
                        NumberAnimation { duration: card.on ? 260 : 90 }
                    }
                }

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
                        Text { id: st; anchors.centerIn: parent; text: sock.connected ? root.mode : "offline"; font.pixelSize: 12; color: root.c("on_secondary_container") }
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
                    add: Transition {
                        ParallelAnimation {
                            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 }
                            NumberAnimation { property: "scale"; from: 0.85; to: 1; duration: 320; easing.type: Easing.OutBack }
                        }
                    }
                    displaced: Transition {
                        NumberAnimation { property: "y"; duration: 260; easing.type: Easing.BezierSpline; easing.bezierCurve: root.emphasized }
                    }
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
                            border.width: 1; border.color: Qt.alpha("white", 0.16)
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
                    border.width: 1; border.color: Qt.alpha("white", 0.18)
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
                            icon: "open_in_full"; family: root.iconFont
                            fg: root.c("on_surface_variant")
                            onClicked: root.openFull()
                        }
                        IconBtn {
                            icon: root.mode === "idle" ? "arrow_upward" : "stop"; family: root.iconFont
                            fg: root.c("on_primary"); bg: root.c("primary")
                            onClicked: {
                                if (root.mode !== "idle") root.send({ type: "cancel" })
                                else { root.submit(field.text); field.text = "" }
                            }
                        }
                    }
                }
            }
        }
    }
}
