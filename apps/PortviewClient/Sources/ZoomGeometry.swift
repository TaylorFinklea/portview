import CoreGraphics

/// Pure geometry for the zoom/magnifier render. Maps the gesture (zoom + cursor) to a render
/// transform and a host crop request.
///
/// The "window" is the view-aspect region of the display the user wants to fill the phone with.
/// Its normalized aspect is `viewAspect / displayAspect`, sized by `1/zoom`. At zoom 1 it contains
/// the whole display (→ overview, letterboxed); shrinking it as you zoom makes the content fill the
/// phone, so the letterbox bars shrink continuously to nothing (this is the behavior the user
/// expects — the viewport takes on the phone's orientation as you zoom in).
///
/// The window is rendered aspect-fit, mapped through the host's current crop (`frameViewport`), via
/// a uniform `renderScale` + `pan`. Because the transform always maps the window to the same screen
/// region regardless of `frameViewport`, the host re-cropping (the magnifier) changes crispness
/// without moving the picture — so it doesn't introduce visual jerk.
///
/// `cropRequest` is a padded box around the visible window in the window's OWN aspect (deliberately
/// NOT square): the host encodes exactly this region, sizing its output buffer to the crop's aspect
/// (`CaptureSizing.cropOutputSize`) so there's no stretch. The padding gives room to pan before the
/// host must re-crop, and at high zoom the small region is encoded at high resolution → crisper.
struct ZoomGeometry {
    let renderScale: CGFloat
    let pan: CGPoint
    let cropRequest: CGRect

    init(view: CGSize, displaySize: CGSize, cursor: CGPoint, zoom: CGFloat, frameViewport: CGRect) {
        let viewAspect = view.width / max(1, view.height)
        let displayAspect = displaySize.width / max(1, displaySize.height)

        // The received frame shows `frameViewport` (`f`) of the display; its on-screen aspect-fit
        // uses the FRAME's aspect, not the whole display's. At zoom 1 / no crop, f is the full
        // display so frameAspect == displayAspect — the original overview behavior, unchanged.
        let f = (frameViewport.width > 0 && frameViewport.height > 0)
            ? frameViewport : CGRect(x: 0, y: 0, width: 1, height: 1)
        let frameAspect = (f.width / max(0.0001, f.height)) * displayAspect
        let videoSize: CGSize = frameAspect > viewAspect
            ? CGSize(width: view.width, height: view.width / frameAspect)
            : CGSize(width: view.height * frameAspect, height: view.height)
        let videoOrigin = CGPoint(x: (view.width - videoSize.width) / 2,
                                  y: (view.height - videoSize.height) / 2)

        // View-aspect window over the display (normalized). base*/zoom; base (zoom 1) is the
        // smallest view-aspect rect containing the unit display, so zoom 1 == overview.
        let ratio = viewAspect / displayAspect
        let z = max(0.0001, zoom)
        let windowW = max(1, ratio) / z
        let windowH = max(1, 1 / ratio) / z
        // Center on the cursor where the window fits inside the display; otherwise center it (the
        // overflow beyond the display edges is the letterbox).
        let cx = windowW < 1 ? min(max(cursor.x, windowW / 2), 1 - windowW / 2) : 0.5
        let cy = windowH < 1 ? min(max(cursor.y, windowH / 2), 1 - windowH / 2) : 0.5
        let window = CGRect(x: cx - windowW / 2, y: cy - windowH / 2, width: windowW, height: windowH)

        // Crop request = the visible part of the window (its OWN aspect), padded for pan headroom.
        // Deliberately NOT square: the host encodes exactly this region at its aspect (see
        // CaptureSizing.cropOutputSize), so it shrinks for an ultrawide display on a portrait phone
        // where the old square crop (max of w/h) stayed full-display and defeated the magnifier.
        let visX0 = max(0, window.minX), visY0 = max(0, window.minY)
        let visX1 = min(1, window.maxX), visY1 = min(1, window.maxY)
        // Generous pan headroom: the host crop extends well beyond the visible window so the cursor-
        // follow can pan locally (instant, using already-received pixels) between host re-crops. Too
        // small and you run past the captured region before the host re-crops → "nothing repaints
        // until I stop". Trades a little high-zoom crispness (a bigger region at the same output rung)
        // for smooth tracking; tunable.
        let padX = (visX1 - visX0) * 0.25
        let padY = (visY1 - visY0) * 0.25
        let cropX0 = max(0, visX0 - padX), cropY0 = max(0, visY0 - padY)
        let cropX1 = min(1, visX1 + padX), cropY1 = min(1, visY1 + padY)
        cropRequest = CGRect(x: cropX0, y: cropY0, width: cropX1 - cropX0, height: cropY1 - cropY0)

        // Map the window through the frame's region (`f`) onto its on-screen rect, then scale so the
        // window fills the view.
        let wvx0 = videoOrigin.x + (window.minX - f.minX) / f.width * videoSize.width
        let wvy0 = videoOrigin.y + (window.minY - f.minY) / f.height * videoSize.height
        let wvw = window.width / f.width * videoSize.width
        let wvh = window.height / f.height * videoSize.height
        let scale = min(view.width / max(1, wvw), view.height / max(1, wvh))
        renderScale = scale
        pan = CGPoint(x: scale * (view.width / 2 - (wvx0 + wvw / 2)),
                      y: scale * (view.height / 2 - (wvy0 + wvh / 2)))
    }
}
