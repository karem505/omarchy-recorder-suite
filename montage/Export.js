// Builds the ffmpeg argv for the montage export. No shell is involved:
// Quickshell's Process takes the argv directly, so nothing here needs
// shell-quoting. Filter-internal single quotes are for ffmpeg's own
// filtergraph parser (commas inside enable/select expressions).
.pragma library

function fmt(n) {
  return Number(n).toFixed(3)
}

// Round to an even number — H.264 chroma subsampling needs even dimensions.
function even(n) {
  return Math.max(2, Math.round(Number(n) / 2) * 2)
}

// opts: {
//   clips: [{path, dur, hasAudio}],              // 1+ videos, joined in order
//   out, hasAudio, W, H, fps,
//   cuts: [{s, e}],                              // seconds, removed ranges
//   overlay: null | {path, w, x, y, s, e},       // pixels + seconds
//   hw: null | {device}                          // VAAPI render node
// }
// Cut and overlay times are on the joined timeline, so the concat runs first
// and everything downstream sees one continuous stream. The overlay/select
// filters always run on the CPU; with hw set, frames are uploaded to the GPU
// only for the final encode (h264_vaapi).
function buildArgs(opts) {
  var parts = []
  var clips = opts.clips
  var n = clips.length
  var vlabel = "[0:v]"
  var alabel = "[0:a]"
  var endV = opts.hw ? "[vcpu]" : "[vout]"

  // Joining clips: concat demands identical geometry, pixel format, SAR and
  // audio layout, so each clip is letterboxed into the first clip's frame and
  // resampled first. Clips with no audio track contribute silence, otherwise
  // the video and audio legs of the concat would not line up.
  if (n > 1) {
    var W = even(opts.W)
    var H = even(opts.H)
    var fps = opts.fps || "30"
    var legs = []
    for (var i = 0; i < n; i++) {
      parts.push("[" + i + ":v]scale=" + W + ":" + H
        + ":force_original_aspect_ratio=decrease"
        + ",pad=" + W + ":" + H + ":(ow-iw)/2:(oh-ih)/2"
        + ",setsar=1,fps=" + fps + ",format=yuv420p[cv" + i + "]")
      legs.push("[cv" + i + "]")
      if (opts.hasAudio) {
        if (clips[i].hasAudio)
          parts.push("[" + i + ":a]aformat=sample_fmts=fltp:sample_rates=48000"
            + ":channel_layouts=stereo,asetpts=N/SR/TB[ca" + i + "]")
        else
          parts.push("anullsrc=r=48000:cl=stereo,atrim=duration="
            + fmt(clips[i].dur) + ",asetpts=N/SR/TB[ca" + i + "]")
        legs.push("[ca" + i + "]")
      }
    }
    parts.push(legs.join("") + "concat=n=" + n + ":v=1:a=" + (opts.hasAudio ? 1 : 0)
      + "[vjoin]" + (opts.hasAudio ? "[ajoin]" : ""))
    vlabel = "[vjoin]"
    alabel = "[ajoin]"
  }

  if (opts.overlay) {
    var o = opts.overlay
    // The overlay image is the input after the last clip.
    parts.push("[" + n + ":v]scale=" + o.w + ":-1[ov]")
    parts.push(vlabel + "[ov]overlay=x=" + o.x + ":y=" + o.y
      + ":enable='between(t," + fmt(o.s) + "," + fmt(o.e) + ")'[vov]")
    vlabel = "[vov]"
  }

  if (opts.cuts.length > 0) {
    var terms = []
    for (var j = 0; j < opts.cuts.length; j++)
      terms.push("between(t," + fmt(opts.cuts[j].s) + "," + fmt(opts.cuts[j].e) + ")")
    var keep = "not(" + terms.join("+") + ")"
    parts.push(vlabel + "select='" + keep + "',setpts=N/FRAME_RATE/TB" + endV)
    if (opts.hasAudio)
      parts.push(alabel + "aselect='" + keep + "',asetpts=N/SR/TB[aout]")
  } else {
    parts.push(vlabel + "null" + endV)
    if (opts.hasAudio)
      parts.push(alabel + "anull[aout]")
  }

  if (opts.hw)
    parts.push("[vcpu]format=nv12,hwupload[vout]")

  // nice keeps the desktop responsive: the export still uses every idle
  // core, it just yields to interactive work first.
  var args = ["nice", "-n", "10", "ffmpeg", "-y"]
  if (opts.hw)
    args = args.concat(["-vaapi_device", opts.hw.device])
  for (var k = 0; k < n; k++)
    args = args.concat(["-i", clips[k].path])
  if (opts.overlay)
    args = args.concat(["-i", opts.overlay.path])
  args = args.concat(["-filter_complex", parts.join(";"), "-map", "[vout]"])
  if (opts.hasAudio)
    args = args.concat(["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"])
  if (opts.hw)
    args = args.concat(["-c:v", "h264_vaapi", "-qp", "23"])
  else
    args = args.concat(["-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
      "-pix_fmt", "yuv420p"])
  args = args.concat([
    "-progress", "pipe:1", "-nostats", "-loglevel", "error",
    opts.out
  ])
  return args
}
