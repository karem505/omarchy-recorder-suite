import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtMultimedia
import QtQuick.Dialogs
import "Export.js" as Export

// Montage — a very simple video editor for screen recordings, styled after
// omacut and themed from the active Omarchy theme: image overlay layer, cut
// ranges, zoomable filmstrip timeline, ffmpeg export.
// Launched by ~/.local/bin/montage-editor, which probes the video and passes
// facts through MONTAGE_* environment variables.
ShellRoot {
  id: rootScope

  readonly property string videoFile: Quickshell.env("MONTAGE_FILE") || ""
  readonly property int videoW: parseInt(Quickshell.env("MONTAGE_W") || "0") || 1920
  readonly property int videoH: parseInt(Quickshell.env("MONTAGE_H") || "0") || 1080
  readonly property bool hasAudio: (Quickshell.env("MONTAGE_HAS_AUDIO") || "") === "1"
  // Hardware encoding, probed by the launcher (empty when unsupported).
  readonly property string hwType: Quickshell.env("MONTAGE_HWENC") || ""
  readonly property string hwDev: Quickshell.env("MONTAGE_VAAPI_DEV") || ""

  FloatingWindow {
    id: win

    title: "Montage — " + (rootScope.videoFile.split("/").pop() || "no file")
    implicitWidth: 1150
    implicitHeight: 760
    color: Theme.background

    property real durationS: player.duration > 0 ? player.duration / 1000
      : parseFloat(Quickshell.env("MONTAGE_DUR") || "0")
    readonly property real positionS: player.position / 1000
    property real pendingIn: -1

    property string overlayPath: Quickshell.env("MONTAGE_OVERLAY") || ""
    property real ovFx: 0.68
    property real ovFy: 0.06
    property real ovFw: 0.25
    property real ovStart: 0
    property real ovEnd: 0 // <= 0 means "until the end"
    readonly property real effOvEnd: ovEnd > 0 ? ovEnd : durationS

    property bool exporting: false
    property real exportProgress: 0
    property real exportTotalS: 1
    // Turned off after a failed hardware encode so the retry (and any later
    // exports this session) use the CPU path.
    property bool hwAllowed: true
    property bool lastExportUsedHw: false
    property string statusText: rootScope.videoFile === ""
      ? "No video file — run: montage-editor <file>" : ""
    property string outFile: ""

    readonly property string thumbDir: Quickshell.env("MONTAGE_THUMBS")
      || (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/montage-thumbs"
    property bool thumbsReady: false
    property bool primed: false

    function togglePlay() {
      player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
    }
    function seek(s) {
      player.position = Math.round(Math.max(0, Math.min(durationS, s)) * 1000)
    }
    function markIn() { pendingIn = positionS }
    function markOut() {
      if (pendingIn >= 0 && positionS > pendingIn + 0.05) {
        cutsModel.append({ s: pendingIn, e: positionS })
        pendingIn = -1
      }
    }
    function fmtTime(s) {
      if (isNaN(s) || s < 0) s = 0
      var m = Math.floor(s / 60)
      var sec = s - m * 60
      return m + ":" + (sec < 10 ? "0" : "") + sec.toFixed(1)
    }

    function startExport() {
      if (exporting || durationS <= 0) return
      var cuts = []
      for (var i = 0; i < cutsModel.count; i++) {
        var c = cutsModel.get(i)
        cuts.push({ s: c.s, e: c.e })
      }
      var useOv = overlayPath !== ""
      if (!useOv && cuts.length === 0) {
        statusText = "Nothing to export — add an image layer or mark cuts first"
        return
      }
      outFile = rootScope.videoFile.replace(/\.[^.\/]+$/, "") + "-montage.mp4"
      var opts = {
        video: rootScope.videoFile,
        out: outFile,
        hasAudio: rootScope.hasAudio,
        W: rootScope.videoW,
        H: rootScope.videoH,
        cuts: cuts,
        overlay: useOv ? {
          path: overlayPath,
          w: Math.max(2, Math.round(ovFw * rootScope.videoW / 2) * 2),
          x: Math.round(ovFx * rootScope.videoW),
          y: Math.round(ovFy * rootScope.videoH),
          s: ovStart,
          e: effOvEnd
        } : null
      }
      var useHw = rootScope.hwType === "vaapi" && rootScope.hwDev !== "" && hwAllowed
      opts.hw = useHw ? { device: rootScope.hwDev } : null
      lastExportUsedHw = useHw
      var cutTotal = 0
      for (var j = 0; j < cuts.length; j++) cutTotal += cuts[j].e - cuts[j].s
      exportTotalS = Math.max(0.1, durationS - cutTotal)
      exportProgress = 0
      exporting = true
      statusText = "Exporting… (" + (useHw ? "GPU" : "CPU") + ")"
      player.pause()
      exportProc.command = Export.buildArgs(opts)
      exportProc.running = true
    }

    ListModel { id: cutsModel }

    // Where the video actually paints inside the preview. Before the first
    // frame renders contentRect is empty, which used to collapse the image
    // overlay to zero size — fall back to the whole preview area.
    readonly property rect videoRect: videoOut.contentRect.width > 0
      ? videoOut.contentRect
      : Qt.rect(0, 0, previewArea.width, previewArea.height)

    MediaPlayer {
      id: player
      source: rootScope.videoFile !== "" ? "file://" + rootScope.videoFile : ""
      audioOutput: AudioOutput { id: audioOut }
      videoOutput: videoOut
      // The ffmpeg backend paints nothing until playback starts, so a fresh
      // window (or a seek while stopped) shows black. Play muted for a beat
      // so a real frame lands, then pause back at the start. Also kicks off
      // filmstrip thumbnail generation.
      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.LoadedMedia && !win.primed) {
          win.primed = true
          audioOut.muted = true
          play()
          primeTimer.start()
          if (win.durationS > 0 && !thumbProc.running) {
            thumbProc.command = ["bash", "-c",
              'rm -rf "$0" && mkdir -p "$0" && exec ffmpeg -y -i "$1" ' +
              '-vf "fps=$2,scale=-1:64" "$0/t%03d.png" -loglevel error',
              win.thumbDir, rootScope.videoFile,
              (timeline.thumbCount / win.durationS).toFixed(6)]
            thumbProc.running = true
          }
        }
      }
    }

    Timer {
      id: primeTimer
      interval: 200
      onTriggered: {
        player.pause()
        player.position = 0
        audioOut.muted = false
      }
    }

    Process {
      id: thumbProc
      onExited: code => { if (code === 0) win.thumbsReady = true }
    }

    Process {
      id: exportProc
      stdout: SplitParser {
        onRead: data => {
          var m = String(data).match(/out_time_ms=(\d+)/)
          if (m) win.exportProgress =
            Math.min(1, (parseInt(m[1]) / 1e6) / win.exportTotalS)
        }
      }
      onExited: (code, status) => {
        win.exporting = false
        if (code === 0) {
          win.exportProgress = 1
          win.statusText = "Saved: " + win.outFile
          Quickshell.execDetached(["omarchy-notification-send", "-t", "8000",
            "Montage exported", win.outFile])
        } else if (win.lastExportUsedHw) {
          win.hwAllowed = false
          win.statusText = "GPU encode failed — retrying on CPU"
          win.startExport()
        } else {
          win.statusText = "Export failed (ffmpeg exit " + code + ")"
        }
      }
    }

    FileDialog {
      id: imgDialog
      nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.bmp)"]
      onAccepted: {
        win.overlayPath = decodeURIComponent(
          String(selectedFile).replace(/^file:\/\//, ""))
      }
    }

    Shortcut { sequence: "Space"; onActivated: win.togglePlay() }
    Shortcut { sequence: "I"; onActivated: win.markIn() }
    Shortcut { sequence: "O"; onActivated: win.markOut() }
    Shortcut { sequence: "Left"; onActivated: win.seek(win.positionS - 1) }
    Shortcut { sequence: "Right"; onActivated: win.seek(win.positionS + 1) }
    Shortcut { sequence: "+"; onActivated: timeline.zoomIn() }
    Shortcut { sequence: "="; onActivated: timeline.zoomIn() }
    Shortcut { sequence: "-"; onActivated: timeline.zoomOut() }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 12
      spacing: 10

      // ---------------------------------------------------------- preview
      Rectangle {
        id: previewArea
        Layout.fillWidth: true
        Layout.fillHeight: true
        color: Qt.darker(Theme.background, 1.3)
        radius: 8
        clip: true

        VideoOutput {
          id: videoOut
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectFit
        }

        MouseArea {
          anchors.fill: parent
          onClicked: win.togglePlay()
        }

        DropArea {
          anchors.fill: parent
          onDropped: drop => {
            if (drop.hasUrls && drop.urls.length > 0) {
              var p = decodeURIComponent(String(drop.urls[0]).replace(/^file:\/\//, ""))
              if (/\.(png|jpe?g|webp|bmp)$/i.test(p)) win.overlayPath = p
            }
          }
        }

        // The image overlay layer: drag to place, wheel to resize. Dim when
        // the playhead is outside its active time range.
        Image {
          id: ovImg
          visible: win.overlayPath !== ""
          source: win.overlayPath !== "" ? "file://" + win.overlayPath : ""
          x: win.videoRect.x + win.ovFx * win.videoRect.width
          y: win.videoRect.y + win.ovFy * win.videoRect.height
          width: win.ovFw * win.videoRect.width
          height: sourceSize.width > 0 ? width * sourceSize.height / sourceSize.width : width
          opacity: ovMa.pressed
            || (win.positionS >= win.ovStart && win.positionS <= win.effOvEnd) ? 1 : 0.25

          Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.color: ovMa.containsMouse || ovMa.pressed ? Theme.yellow : "transparent"
            border.width: 1
          }

          MouseArea {
            id: ovMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.SizeAllCursor
            drag.target: ovImg
            onReleased: {
              var cr = win.videoRect
              if (cr.width > 0) {
                win.ovFx = (ovImg.x - cr.x) / cr.width
                win.ovFy = (ovImg.y - cr.y) / cr.height
              }
              ovImg.x = Qt.binding(() =>
                win.videoRect.x + win.ovFx * win.videoRect.width)
              ovImg.y = Qt.binding(() =>
                win.videoRect.y + win.ovFy * win.videoRect.height)
            }
            onWheel: wheel => {
              win.ovFw = Math.max(0.03, Math.min(1,
                win.ovFw + (wheel.angleDelta.y > 0 ? 0.04 : -0.04)))
            }
          }

          // Corner resize grip: drag to change the layer's size directly.
          Rectangle {
            id: grip
            visible: ovMa.containsMouse || gripMa.containsMouse || gripMa.pressed
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: -2
            width: 13
            height: 13
            radius: 3
            color: gripMa.pressed || gripMa.containsMouse ? Theme.accent : Theme.yellow
            border.color: Theme.background
            border.width: 1

            MouseArea {
              id: gripMa
              anchors.fill: parent
              anchors.margins: -8
              hoverEnabled: true
              cursorShape: Qt.SizeFDiagCursor
              preventStealing: true
              property real startW: 0
              property real startX: 0
              onPressed: mouse => {
                startW = ovImg.width
                startX = mapToItem(videoOut, mouse.x, mouse.y).x
              }
              onPositionChanged: mouse => {
                if (!pressed) return
                var dx = mapToItem(videoOut, mouse.x, mouse.y).x - startX
                var cr = win.videoRect
                if (cr.width > 0)
                  win.ovFw = Math.max(0.03, Math.min(1, (startW + dx) / cr.width))
              }
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: rootScope.videoFile === ""
          text: "No video file\nmontage-editor <file>"
          color: Theme.muted
          font.family: Theme.fontFamily
          font.pixelSize: 18
          horizontalAlignment: Text.AlignHCenter
        }
      }

      // ------------------------------------------- play | timeline | export
      RowLayout {
        Layout.fillWidth: true
        spacing: 12

        IconButton {
          icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play"
          size: 46
          onClicked: win.togglePlay()
        }

        Timeline {
          id: timeline
          Layout.fillWidth: true
          Layout.preferredHeight: 92
          durationS: win.durationS
          positionS: win.positionS
          pendingIn: win.pendingIn
          cutsModel: cutsModel
          hasOverlay: win.overlayPath !== ""
          ovStart: win.ovStart
          ovEnd: win.effOvEnd
          thumbDir: win.thumbDir
          thumbsReady: win.thumbsReady
          onSeekTo: s => win.seek(s)
          onRemoveCut: index => cutsModel.remove(index)
        }

        IconButton {
          icon: "export"
          size: 46
          primary: true
          enabled: !win.exporting
          onClicked: win.startExport()
        }
      }

      // ----------------------------------------------------------- controls
      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
          text: win.fmtTime(win.positionS) + " (" + win.fmtTime(win.durationS) + ")"
          color: Theme.fg
          font.family: Theme.fontFamily
          font.pixelSize: 13
        }
        Rectangle { width: 1; height: 20; color: Theme.panelHi }
        MButton { text: "Cut in (I)"; onClicked: win.markIn() }
        MButton {
          text: "Cut out (O)"
          enabled: win.pendingIn >= 0
          onClicked: win.markOut()
        }
        Text {
          visible: win.pendingIn >= 0
          text: "cutting from " + win.fmtTime(win.pendingIn)
          color: Theme.yellow
          font.family: Theme.fontFamily
          font.pixelSize: 11
        }
        Rectangle { width: 1; height: 20; color: Theme.panelHi }
        MButton {
          text: win.overlayPath === "" ? "Add image layer" : "Change image"
          onClicked: imgDialog.open()
        }
        Text {
          Layout.maximumWidth: 220
          visible: win.overlayPath !== ""
          text: win.overlayPath.split("/").pop()
          elide: Text.ElideMiddle
          color: Theme.yellow
          font.family: Theme.fontFamily
          font.pixelSize: 11
        }
        Text {
          visible: win.overlayPath !== ""
          text: "size"
          color: Theme.muted
          font.family: Theme.fontFamily
          font.pixelSize: 11
        }
        MSlider {
          visible: win.overlayPath !== ""
          Layout.preferredWidth: 110
          value: (win.ovFw - 0.03) / 0.97
          onMoved: v => win.ovFw = 0.03 + v * 0.97
        }
        MButton {
          visible: win.overlayPath !== ""
          text: "From " + win.fmtTime(win.ovStart)
          onClicked: win.ovStart = win.positionS
        }
        MButton {
          visible: win.overlayPath !== ""
          text: "To " + win.fmtTime(win.effOvEnd)
          onClicked: if (win.positionS > win.ovStart) win.ovEnd = win.positionS
        }
        MButton {
          visible: win.overlayPath !== ""
          text: "Remove"
          onClicked: {
            win.overlayPath = ""
            win.ovStart = 0
            win.ovEnd = 0
          }
        }
        Item { Layout.fillWidth: true }
        Text {
          text: "zoom"
          color: Theme.muted
          font.family: Theme.fontFamily
          font.pixelSize: 11
        }
        IconButton { icon: "minus"; size: 28; onClicked: timeline.zoomOut() }
        IconButton { icon: "plus"; size: 28; onClicked: timeline.zoomIn() }
      }

      // ------------------------------------------------------------- status
      RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: win.statusText !== "" || win.exporting

        Rectangle {
          visible: win.exporting || win.exportProgress > 0
          Layout.preferredWidth: 220
          height: 8
          radius: 4
          color: Theme.panelHi
          Rectangle {
            width: parent.width * win.exportProgress
            height: parent.height
            radius: 4
            color: Theme.green
          }
        }
        Text {
          Layout.fillWidth: true
          text: win.statusText
          elide: Text.ElideMiddle
          color: win.statusText.indexOf("failed") >= 0 ? Theme.red : Theme.fg
          font.family: Theme.fontFamily
          font.pixelSize: 12
        }
        MButton {
          visible: win.statusText.indexOf("Saved:") === 0
          text: "Open result"
          onClicked: Quickshell.execDetached(["mpv", win.outFile])
        }
      }
    }
  }
}
