// Builds the ffmpeg argv for the montage export. No shell is involved:
// Quickshell's Process takes the argv directly, so nothing here needs
// shell-quoting. Filter-internal single quotes are for ffmpeg's own
// filtergraph parser (commas inside enable/select expressions).
.pragma library

function fmt(n) {
  return Number(n).toFixed(3)
}

// opts: {
//   video, out, hasAudio, W, H,
//   cuts: [{s, e}],                              // seconds, removed ranges
//   overlay: null | {path, w, x, y, s, e}        // pixels + seconds
// }
function buildArgs(opts) {
  var parts = []
  var vlabel = "[0:v]"

  if (opts.overlay) {
    var o = opts.overlay
    parts.push("[1:v]scale=" + o.w + ":-1[ov]")
    parts.push("[0:v][ov]overlay=x=" + o.x + ":y=" + o.y
      + ":enable='between(t," + fmt(o.s) + "," + fmt(o.e) + ")'[vov]")
    vlabel = "[vov]"
  }

  if (opts.cuts.length > 0) {
    var terms = []
    for (var i = 0; i < opts.cuts.length; i++)
      terms.push("between(t," + fmt(opts.cuts[i].s) + "," + fmt(opts.cuts[i].e) + ")")
    var keep = "not(" + terms.join("+") + ")"
    parts.push(vlabel + "select='" + keep + "',setpts=N/FRAME_RATE/TB[vout]")
    if (opts.hasAudio)
      parts.push("[0:a]aselect='" + keep + "',asetpts=N/SR/TB[aout]")
  } else {
    parts.push(vlabel + "null[vout]")
    if (opts.hasAudio)
      parts.push("[0:a]anull[aout]")
  }

  var args = ["ffmpeg", "-y", "-i", opts.video]
  if (opts.overlay)
    args = args.concat(["-i", opts.overlay.path])
  args = args.concat(["-filter_complex", parts.join(";"), "-map", "[vout]"])
  if (opts.hasAudio)
    args = args.concat(["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"])
  args = args.concat([
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "19", "-pix_fmt", "yuv420p",
    "-progress", "pipe:1", "-nostats", "-loglevel", "error",
    opts.out
  ])
  return args
}
