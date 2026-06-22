import CoreGraphics

/// Pure geometry for the zoom/magnifier render. Maps the gesture (zoom + cursor) to a host crop
/// request and to the sub-rect of the current frame the renderer should sample.
///
/// The "window" is the view-aspect region of the display the user wants to fill the phone with. Its
/// normalized aspect is `viewAspect / displayAspect`, sized by `1/zoom`. At zoom 1 it contains the
/// whole display (→ overview, letterboxed); shrinking it as you zoom makes the content fill the phone,
/// so the letterbox bars shrink continuously to nothing (the viewport takes on the phone's orientation
/// as you zoom in).
///
/// The zoom is applied IN the Metal shader (not as a Core Animation transform): `sampleRect` is the
/// visible window expressed in the CURRENT frame's texture UV coordinates, and the renderer samples
/// exactly that sub-rect into the full-resolution drawable. Because `sampleRect` is recomputed from the
/// live `frameViewport` every frame, the SAME display-window stays put on screen as the host re-crops
/// (`frameViewport` changes but the recovered window does not) — so re-crops change crispness, never
/// on-screen geometry (no jump). Sampling at drawable resolution also avoids the old CA upscale of a
/// 1×-resolution layer.
///
/// `cropRequest` is a padded box around the visible window in the window's OWN aspect (deliberately NOT
/// square): the host encodes exactly this region. The padding gives room to pan before the host must
/// re-crop, and at high zoom the small region is encoded at high resolution → crisper.
struct ZoomGeometry {
    /// Padded host crop request (normalized display coords).
    let cropRequest: CGRect
    /// Sub-rect of the current frame's texture to sample, in UV [0,1] (top-left origin). Clamped to
    /// [0,1] so a window that has run past a not-yet-re-cropped frame samples the edge (clampToEdge)
    /// rather than outside the texture.
    let sampleRect: CGRect

    init(view: CGSize, displaySize: CGSize, cursor: CGPoint, zoom: CGFloat, frameViewport: CGRect) {
        let viewAspect = view.width / max(1, view.height)
        let displayAspect = displaySize.width / max(1, displaySize.height)
        // The received frame shows `f` of the display; at zoom 1 / no crop it's the whole display.
        let f = (frameViewport.width > 0 && frameViewport.height > 0)
            ? frameViewport : CGRect(x: 0, y: 0, width: 1, height: 1)

        // View-aspect window over the display (normalized). base*/zoom; base (zoom 1) is the smallest
        // view-aspect rect containing the unit display, so zoom 1 == overview.
        let ratio = viewAspect / displayAspect
        let z = max(0.0001, zoom)
        let windowW = max(1, ratio) / z
        let windowH = max(1, 1 / ratio) / z
        // Center on the cursor where the window fits inside the display; otherwise center it (the
        // overflow beyond the display edges is the letterbox).
        let cx = windowW < 1 ? min(max(cursor.x, windowW / 2), 1 - windowW / 2) : 0.5
        let cy = windowH < 1 ? min(max(cursor.y, windowH / 2), 1 - windowH / 2) : 0.5
        let window = CGRect(x: cx - windowW / 2, y: cy - windowH / 2, width: windowW, height: windowH)

        // Visible window = window ∩ display.
        let visX0 = max(0, window.minX), visY0 = max(0, window.minY)
        let visX1 = min(1, window.maxX), visY1 = min(1, window.maxY)

        // Crop request = the visible window, padded for pan headroom. Deliberately the window's OWN
        // aspect (not square) so it shrinks for an ultrawide display on a portrait phone.
        let padX = (visX1 - visX0) * 0.25
        let padY = (visY1 - visY0) * 0.25
        let cropX0 = max(0, visX0 - padX), cropY0 = max(0, visY0 - padY)
        let cropX1 = min(1, visX1 + padX), cropY1 = min(1, visY1 + padY)
        cropRequest = CGRect(x: cropX0, y: cropY0, width: cropX1 - cropX0, height: cropY1 - cropY0)

        // Map the visible window into the current frame's region `f`, in texture UV. The same display
        // window maps to the same on-screen result regardless of `f`: recovering the window as
        // `f.origin + sampleRect.origin * f.size` returns the visible window for any `f`. NOT clamped to
        // [0,1]: if a fast pan runs the window past the not-yet-re-cropped frame, the UVs exceed [0,1]
        // and the clampToEdge sampler smears the edge — while the rect's SIZE (the window's true pixel
        // aspect) is preserved, so the renderer aspect-fits it to the same on-screen rect instead of
        // pinching the picture to a sliver.
        let u0 = (visX0 - f.minX) / f.width
        let v0 = (visY0 - f.minY) / f.height
        let u1 = (visX1 - f.minX) / f.width
        let v1 = (visY1 - f.minY) / f.height
        sampleRect = CGRect(x: u0, y: v0, width: max(0.0001, u1 - u0), height: max(0.0001, v1 - v0))
    }
}
