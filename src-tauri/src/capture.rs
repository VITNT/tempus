use crate::{NativeCaptureResult, NativeCaptureSource};
use base64::Engine;
use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::{DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, RgbaImage};
use std::io::Cursor;
use xcap::{Monitor, Window};

/// Capture the source directly from the operating system at its native pixel
/// dimensions. This follows Lookout's desktop capture architecture, but keeps
/// the local Tempus frame lossless instead of applying its upload-oriented
/// JPEG compression and 1080p size cap.
pub fn capture_png(source: NativeCaptureSource) -> Result<NativeCaptureResult, String> {
    let image = DynamicImage::ImageRgba8(capture_rgba(source)?);

    let mut bytes = Cursor::new(Vec::new());
    image
        .write_to(&mut bytes, ImageFormat::Png)
        .map_err(|error| format!("PNG encoding failed: {error}"))?;

    Ok(NativeCaptureResult {
        base64: base64::engine::general_purpose::STANDARD.encode(bytes.into_inner()),
        width: image.width(),
        height: image.height(),
    })
}

/// Video mode grabs frames several times a second and immediately re-encodes
/// them, so this favours speed: lossless PNG with the fastest deflate setting
/// (screen content still compresses well), returned as raw bytes rather than
/// base64 so the IPC hop stays cheap.
pub fn capture_fast_png(source: NativeCaptureSource) -> Result<Vec<u8>, String> {
    let image = capture_rgba(source)?;
    let mut bytes = Vec::with_capacity((image.width() * image.height()) as usize);
    PngEncoder::new_with_quality(&mut bytes, CompressionType::Fast, FilterType::Sub)
        .write_image(image.as_raw(), image.width(), image.height(), ExtendedColorType::Rgba8)
        .map_err(|error| format!("PNG encoding failed: {error}"))?;
    Ok(bytes)
}

fn capture_rgba(source: NativeCaptureSource) -> Result<RgbaImage, String> {
    let image = match source {
        NativeCaptureSource::Monitor { id } => {
            let monitor = Monitor::all()
                .map_err(|error| format!("Failed to list monitors: {error}"))?
                .into_iter()
                .find(|monitor| monitor.id().ok() == Some(id))
                .ok_or_else(|| format!("Monitor {id} is no longer available"))?;

            monitor
                .capture_image()
                .map_err(|error| format!("Screen capture failed: {error}"))?
        }
        NativeCaptureSource::Window { id } => {
            let window = Window::all()
                .map_err(|error| format!("Failed to list windows: {error}"))?
                .into_iter()
                .find(|window| window.id().ok() == Some(id))
                .ok_or_else(|| format!("Window {id} is no longer available"))?;

            window
                .capture_image()
                .map_err(|error| format!("Window capture failed: {error}"))?
        }
    };

    if image.width() <= 2 || image.height() <= 2 {
        return Err("The selected source is minimized or unavailable".to_string());
    }
    Ok(image)
}
