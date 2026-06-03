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
/// `cropRequest` is a padded, display-aspect (square-normalized) box around the visible window. It
/// MUST be display-aspect: the host's output buffer is display-aspect, so a non-square crop would be
/// stretched. The padding gives room to pan before the host must re-crop, and at high zoom the small
/// crop is encoded at full resolution → crisper.
struct ZoomGeometry {
    let renderScale: CGFloat
    let pan: CGPoint
    let cropRequest: CGRect

    init(view: CGSize, displaySize: CGSize, cursor: CGPoint, zoom: CGFloat, frameViewport: CGRect) {
        let viewAspect = view.width / max(1, view.height)
        let displayAspect = displaySize.width / max(1, displaySize.height)

        // The host's current crop. Its pixel aspect — NOT necessarily the display's — drives the
        // aspect-fit, because the host now crops to (and sizes its buffer to) the visible region.
        let f = (frameViewport.width > 0 && frameViewport.height > 0)
            ? frameViewport : CGRect(x: 0, y: 0, width: 1, height: 1)
        let frameAspect = (f.width * displaySize.width) / max(1, f.height * displaySize.height)
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

        // Crop request = the *tight* visible part of the window (what actually has content), padded a
        // little for pan headroom, clamped. NOT squared: the host sizes its output buffer to this
        // region's native pixels, so it's encoded at full display density (crisp) instead of the
        // whole display scaled down. (At zoom 1 the visible region is the whole display → no crop.)
        let visX0 = max(0, window.minX), visY0 = max(0, window.minY)
        let visX1 = min(1, window.maxX), visY1 = min(1, window.maxY)
        let visible = CGRect(x: visX0, y: visY0,
                             width: max(0.0001, visX1 - visX0), height: max(0.0001, visY1 - visY0))
        let padX = visible.width * 0.08, padY = visible.height * 0.08
        let cropX0 = max(0, visible.minX - padX), cropY0 = max(0, visible.minY - padY)
        let cropX1 = min(1, visible.maxX + padX), cropY1 = min(1, visible.maxY + padY)
        let tight = CGRect(x: cropX0, y: cropY0, width: cropX1 - cropX0, height: cropY1 - cropY0)
        // Hysteresis: keep the host's current crop while the visible window stays inside it and the
        // crop isn't far larger than needed — so panning within a crop doesn't constantly re-crop the
        // stream. Re-crop only when panning past the edge or after a zoom change shrinks the window.
        let frameTooBig = f.width > tight.width * 1.6 || f.height > tight.height * 1.6
        cropRequest = (f.contains(visible) && !frameTooBig) ? f : tight

        // Render the window aspect-fit, mapped through the host's current crop.
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
