import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtMultimedia
import QtQuick.Dialogs
import "Export.js" as Export

// Montage — a very simple video editor for screen recordings, styled after
// omacut and themed from the active Omarchy theme: a timeline you can join
// more videos onto, an image overlay layer, cut ranges, zoomable filmstrip,
// ffmpeg export.
// Launched by ~/.local/bin/montage-editor, which probes the video and passes
// facts through MONTAGE_* environment variables.
ShellRoot {
  id: rootScope

  readonly property string videoFile: Quickshell.env("MONTAGE_FILE") || ""
  readonly property int videoW: parseInt(Quickshell.env("MONTAGE_W") || "0") || 1920
  readonly property int videoH: parseInt(Quickshell.env("MONTAGE_H") || "0") || 1080
  readonly property bool hasAudio: (Quickshell.env("MONTAGE_HAS_AUDIO") || "") === "1"
  // Frame rate of the recording, as ffprobe's fraction ("60/1"). Videos joined
  // onto the timeline are normalised to it, since concat wants one rate.
  readonly property string fps: {
    var r = (Quickshell.env("MONTAGE_FPS") || "").trim()
    return /^[1-9]\d*(\/[1-9]\d*)?$/.test(r) ? r : "30"
  }
  // Hardware encoding, probed by the launcher (empty when unsupported).
  readonly property string hwType: Quickshell.env("MONTAGE_HWENC") || ""
  readonly property string hwDev: Quickshell.env("MONTAGE_VAAPI_DEV") || ""

  FloatingWindow {
    id: win

    title: "Montage — " + (rootScope.videoFile.split("/").pop() || "no file")
    implicitWidth: 1150
    implicitHeight: 760
    color: Theme.background

    // The timeline is the clips played back to back; every time below — the
    // playhead, cuts, the overlay range — is on that joined timeline.
    property real durationS: 0
    property real clipOffsetS: 0
    readonly property real positionS: clipOffsetS + player.position / 1000
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
    property bool primed: false

    // ------------------------------------------------------------- clips
    // One row per video, in play order. `start` is the clip's position on the
    // joined timeline and is recomputed by refresh(); `id` is monotonic so a
    // clip keeps its thumbnail directory when earlier clips are removed.
    ListModel { id: clipsModel }
    property int nextClipId: 0
    property bool anyAudio: false
    // Index of the clip the player currently holds. Changing it reloads the
    // MediaPlayer, so everything that moves the playhead across a clip
    // boundary goes through seek().
    property int clipIndex: 0
    property string currentPath: ""
    property real pendingSeekLocal: -1
    property bool resumeAfterSwitch: false
    property real primeTarget: 0
    // True between a source change and the one-shot load handling for it.
    property bool pendingLoad: false

    function syncCurrent() {
      var c = clipIndex >= 0 && clipIndex < clipsModel.count
        ? clipsModel.get(clipIndex) : null
      clipOffsetS = c ? c.start : 0
      currentPath = c ? c.path : ""
    }

    function refresh() {
      var t = 0
      var audio = false
      for (var i = 0; i < clipsModel.count; i++) {
        clipsModel.setProperty(i, "start", t)
        t += clipsModel.get(i).dur
        if (clipsModel.get(i).hasAudio) audio = true
      }
      durationS = t
      anyAudio = audio
      syncCurrent()
    }

    function clipAt(globalS) {
      var t = 0
      for (var i = 0; i < clipsModel.count; i++) {
        t += clipsModel.get(i).dur
        if (globalS < t) return i
      }
      return Math.max(0, clipsModel.count - 1)
    }

    function appendClip(path, dur, clipHasAudio) {
      var id = nextClipId++
      clipsModel.append({
        id: id,
        path: path,
        name: String(path).split("/").pop(),
        dur: dur,
        start: 0,
        hasAudio: clipHasAudio,
        // Roughly a thumbnail every three seconds, whatever the clip's length.
        thumbs: Math.max(4, Math.min(48, Math.ceil(dur / 3))),
        dir: thumbDir + "/c" + id,
        ready: false
      })
      refresh()
      queueThumbs(clipsModel.count - 1)
      if (clipsModel.count > 1)
        statusText = "Added " + String(path).split("/").pop()
          + " — timeline is now " + fmtTime(durationS)
    }

    function addVideo(path) {
      if (!path) return
      probeQueue = probeQueue.concat([path])
      pumpProbe()
    }

    // Removing a joined clip closes the gap, so cuts and the overlay range
    // are pulled back over the removed stretch — otherwise they would silently
    // start applying to different footage.
    function shiftTime(t, s0, d) {
      return t >= s0 + d ? t - d : (t > s0 ? s0 : t)
    }

    function removeClip(i) {
      // Clip 0 is the recording the editor was opened on; it stays.
      if (i <= 0 || i >= clipsModel.count) return
      var gone = clipsModel.get(i)
      var s0 = gone.start
      var d = gone.dur
      clipsModel.remove(i)

      for (var c = cutsModel.count - 1; c >= 0; c--) {
        var cut = cutsModel.get(c)
        var ns = shiftTime(cut.s, s0, d)
        var ne = shiftTime(cut.e, s0, d)
        if (ne - ns < 0.05) cutsModel.remove(c)
        else {
          cutsModel.setProperty(c, "s", ns)
          cutsModel.setProperty(c, "e", ne)
        }
      }
      ovStart = shiftTime(ovStart, s0, d)
      if (ovEnd > 0) ovEnd = shiftTime(ovEnd, s0, d)
      if (pendingIn >= 0) pendingIn = shiftTime(pendingIn, s0, d)

      if (i < clipIndex) {
        clipIndex = clipIndex - 1   // same clip, one slot earlier
        refresh()
      } else if (i === clipIndex) {
        // The playhead was inside what just went away — land on the join.
        refresh()
        seek(Math.min(s0, durationS))
      } else {
        refresh()
      }
      statusText = "Removed " + gone.name + " — timeline is now " + fmtTime(durationS)
    }

    // ------------------------------------------------------------ playback
    function togglePlay() {
      player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
    }
    function seek(s) {
      if (clipsModel.count === 0) return
      s = Math.max(0, Math.min(durationS, s))
      var k = clipAt(s)
      var local = s - clipsModel.get(k).start
      if (k === clipIndex) {
        player.position = Math.round(local * 1000)
      } else {
        resumeAfterSwitch = player.playbackState === MediaPlayer.PlayingState
        pendingSeekLocal = local
        clipIndex = k
      }
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

    onClipIndexChanged: syncCurrent()

    function startExport() {
      if (exporting || durationS <= 0 || clipsModel.count === 0) return
      var cuts = []
      for (var i = 0; i < cutsModel.count; i++) {
        var c = cutsModel.get(i)
        cuts.push({ s: c.s, e: c.e })
      }
      var clips = []
      for (var k = 0; k < clipsModel.count; k++) {
        var cl = clipsModel.get(k)
        clips.push({ path: cl.path, dur: cl.dur, hasAudio: cl.hasAudio })
      }
      var useOv = overlayPath !== ""
      if (!useOv && cuts.length === 0 && clips.length < 2) {
        statusText = "Nothing to export — join a video, add an image layer, or mark cuts first"
        return
      }
      outFile = rootScope.videoFile.replace(/\.[^.\/]+$/, "") + "-montage.mp4"
      var opts = {
        clips: clips,
        out: outFile,
        hasAudio: anyAudio,
        W: rootScope.videoW,
        H: rootScope.videoH,
        fps: rootScope.fps,
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

    Component.onCompleted: {
      if (rootScope.videoFile !== "")
        appendClip(rootScope.videoFile,
          parseFloat(Quickshell.env("MONTAGE_DUR") || "0") || 0,
          rootScope.hasAudio)
    }

    // Where the video actually paints inside the preview. Before the first
    // frame renders contentRect is empty, which used to collapse the image
    // overlay to zero size — fall back to the whole preview area.
    readonly property rect videoRect: videoOut.contentRect.width > 0
      ? videoOut.contentRect
      : Qt.rect(0, 0, previewArea.width, previewArea.height)

    MediaPlayer {
      id: player
      source: win.currentPath !== "" ? "file://" + win.currentPath : ""
      audioOutput: AudioOutput { id: audioOut }
      videoOutput: videoOut

      // Only trusted when the launcher could not probe the file (duration 0);
      // otherwise ffprobe's number wins, so the timeline never shifts under
      // the playhead mid-session.
      onDurationChanged: {
        if (player.duration <= 0 || win.clipIndex >= clipsModel.count) return
        var c = clipsModel.get(win.clipIndex)
        if (c.dur > 0) return
        var d = player.duration / 1000
        clipsModel.setProperty(win.clipIndex, "dur", d)
        clipsModel.setProperty(win.clipIndex, "thumbs",
          Math.max(4, Math.min(48, Math.ceil(d / 3))))
        win.refresh()
        win.queueThumbs(win.clipIndex)
      }

      // A new file is loading: everything below runs once per source, never
      // again while that source plays. LoadedMedia is re-emitted during normal
      // playback, and re-running the prime on those would drag the playhead
      // back to the clip start over and over.
      onSourceChanged: {
        win.pendingLoad = true
        if (win.pendingSeekLocal < 0) win.pendingSeekLocal = 0
      }

      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.EndOfMedia) {
          // Roll into the next clip so the joined timeline plays as one video.
          if (win.clipIndex + 1 < clipsModel.count) {
            win.pendingSeekLocal = 0
            win.resumeAfterSwitch = true
            win.clipIndex = win.clipIndex + 1
          }
          return
        }
        if (mediaStatus !== MediaPlayer.LoadedMedia || !win.pendingLoad) return
        win.pendingLoad = false
        win.primed = true

        var local = win.pendingSeekLocal >= 0 ? win.pendingSeekLocal : 0
        win.pendingSeekLocal = -1
        if (win.resumeAfterSwitch) {
          // Came from the clip before this one while playing — keep playing.
          win.resumeAfterSwitch = false
          position = Math.round(local * 1000)
          play()
        } else {
          // The ffmpeg backend paints nothing until playback starts, so a
          // freshly loaded clip shows black. Play muted for a beat so a real
          // frame lands, then pause back at the wanted spot.
          win.primeTarget = local
          audioOut.muted = true
          play()
          primeTimer.restart()
        }
      }
    }

    Timer {
      id: primeTimer
      interval: 200
      onTriggered: {
        player.pause()
        player.position = Math.round(win.primeTarget * 1000)
        audioOut.muted = false
      }
    }

    // ---------------------------------------------------- filmstrip thumbs
    // One ffmpeg pass per clip, run one at a time so a burst of added videos
    // does not fork half a dozen encoders at once.
    property var thumbQueue: []

    function queueThumbs(i) {
      thumbQueue = thumbQueue.concat([clipsModel.get(i).id])
      pumpThumbs()
    }

    function clipById(id) {
      for (var i = 0; i < clipsModel.count; i++)
        if (clipsModel.get(i).id === id) return i
      return -1
    }

    function pumpThumbs() {
      if (thumbProc.running || thumbQueue.length === 0) return
      var id = thumbQueue[0]
      thumbQueue = thumbQueue.slice(1)
      var i = clipById(id)
      if (i < 0 || clipsModel.get(i).dur <= 0) { pumpThumbs(); return }
      var c = clipsModel.get(i)
      thumbProc.clipId = id
      thumbProc.command = ["bash", "-c",
        'rm -rf "$0" && mkdir -p "$0" && exec ffmpeg -y -i "$1" ' +
        '-vf "fps=$2,scale=-1:64" "$0/t%03d.png" -loglevel error',
        c.dir, c.path, (c.thumbs / c.dur).toFixed(6)]
      thumbProc.running = true
    }

    Process {
      id: thumbProc
      property int clipId: -1
      onExited: code => {
        if (code === 0) {
          var i = win.clipById(thumbProc.clipId)
          if (i >= 0) clipsModel.setProperty(i, "ready", true)
        }
        thumbPump.restart()
      }
    }
    Timer { id: thumbPump; interval: 0; onTriggered: win.pumpThumbs() }

    // ------------------------------------------------- probing added videos
    // ffprobe before the clip joins the timeline: its duration sets where the
    // following clips sit, and whether it has audio decides if the export has
    // to fill in silence for it.
    property var probeQueue: []

    function pumpProbe() {
      if (probeProc.running || probeQueue.length === 0) return
      var f = probeQueue[0]
      probeQueue = probeQueue.slice(1)
      probeProc.target = f
      probeProc.line = ""
      statusText = "Reading " + String(f).split("/").pop() + "…"
      probeProc.command = ["bash", "-c",
        'd=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$0" 2>/dev/null); ' +
        'a=$(ffprobe -v error -select_streams a -show_entries stream=codec_type ' +
        '-of csv=p=0 "$0" 2>/dev/null | head -1); printf "%s|%s\\n" "${d:-0}" "${a:+1}"',
        f]
      probeProc.running = true
    }

    Process {
      id: probeProc
      property string target: ""
      property string line: ""
      stdout: SplitParser {
        onRead: data => { if (String(data).trim() !== "") probeProc.line = String(data).trim() }
      }
      onExited: code => {
        var bits = probeProc.line.split("|")
        var d = parseFloat(bits[0] || "0")
        if (code !== 0 || !(d > 0.05))
          win.statusText = "Could not read "
            + String(probeProc.target).split("/").pop() + " — is it a video?"
        else
          win.appendClip(probeProc.target, d, bits[1] === "1")
        probePump.restart()
      }
    }
    Timer { id: probePump; interval: 0; onTriggered: win.pumpProbe() }

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

    FileDialog {
      id: vidDialog
      title: "Add a video to the end of the timeline"
      nameFilters: ["Videos (*.mp4 *.mkv *.webm *.mov *.avi *.m4v *.ts)",
        "All files (*)"]
      onAccepted: {
        win.addVideo(decodeURIComponent(
          String(selectedFile).replace(/^file:\/\//, "")))
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
    Shortcut { sequence: "V"; onActivated: vidDialog.open() }
    Shortcut { sequence: "L"; onActivated: imgDialog.open() }

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
            if (!drop.hasUrls) return
            for (var i = 0; i < drop.urls.length; i++) {
              var p = decodeURIComponent(String(drop.urls[i]).replace(/^file:\/\//, ""))
              if (/\.(png|jpe?g|webp|bmp)$/i.test(p)) win.overlayPath = p
              else if (/\.(mp4|mkv|webm|mov|avi|m4v|mpe?g|wmv|flv|ts)$/i.test(p))
                win.addVideo(p)
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
          clipsModel: clipsModel
          hasOverlay: win.overlayPath !== ""
          ovStart: win.ovStart
          ovEnd: win.effOvEnd
          onSeekTo: s => win.seek(s)
          onRemoveCut: index => cutsModel.remove(index)
          onAddClip: vidDialog.open()
          onDropClip: index => win.removeClip(index)
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
        MButton { text: "Add video (V)"; onClicked: vidDialog.open() }
        Text {
          visible: clipsModel.count > 1
          text: clipsModel.count + " clips"
          color: Theme.muted
          font.family: Theme.fontFamily
          font.pixelSize: 11
        }
        Rectangle { width: 1; height: 20; color: Theme.panelHi }
        MButton {
          text: win.overlayPath === "" ? "Add image layer (L)" : "Change image (L)"
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
          color: win.statusText.indexOf("failed") >= 0
            || win.statusText.indexOf("Could not") >= 0 ? Theme.red : Theme.fg
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
