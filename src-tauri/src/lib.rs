mod capture;

use serde::{Deserialize, Serialize};
use xcap::{Monitor, Window};

#[derive(Clone, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum NativeCaptureSource {
    Monitor { id: u32 },
    Window { id: u32 },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeCaptureSourceInfo {
    #[serde(rename = "type")]
    source_type: &'static str,
    id: u32,
    label: String,
    width: u32,
    height: u32,
    is_primary: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeCaptureResult {
    pub base64: String,
    pub width: u32,
    pub height: u32,
}

#[tauri::command]
fn list_capture_sources() -> Result<Vec<NativeCaptureSourceInfo>, String> {
    let mut sources = Vec::new();

    for monitor in Monitor::all().map_err(|error| format!("Failed to list monitors: {error}"))? {
        let Some(id) = monitor.id().ok() else { continue };
        let Some(width) = monitor.width().ok() else { continue };
        let Some(height) = monitor.height().ok() else { continue };
        let label = monitor
            .friendly_name()
            .or_else(|_| monitor.name())
            .unwrap_or_else(|_| format!("Display {id}"));

        sources.push(NativeCaptureSourceInfo {
            source_type: "monitor",
            id,
            label,
            width,
            height,
            is_primary: monitor.is_primary().unwrap_or(false),
        });
    }

    // A platform can expose monitor capture while denying window enumeration,
    // so a window-list failure should not hide otherwise usable displays.
    if let Ok(windows) = Window::all() {
        for window in windows {
            let Some(id) = window.id().ok() else { continue };
            let Some(width) = window.width().ok() else { continue };
            let Some(height) = window.height().ok() else { continue };
            let title = window.title().unwrap_or_default();
            let app_name = window.app_name().unwrap_or_default();

            if width < 50 || height < 50 || (title.is_empty() && app_name.is_empty()) {
                continue;
            }
            if app_name.eq_ignore_ascii_case("Tempus") || title.eq_ignore_ascii_case("Tempus") {
                continue;
            }

            let label = match (app_name.is_empty(), title.is_empty()) {
                (false, false) => format!("{app_name} — {title}"),
                (false, true) => app_name,
                (true, false) => title,
                (true, true) => unreachable!(),
            };

            sources.push(NativeCaptureSourceInfo {
                source_type: "window",
                id,
                label,
                width,
                height,
                is_primary: false,
            });
        }
    }

    sources.sort_by_key(|source| match (source.source_type, source.is_primary) {
        ("monitor", true) => 0,
        ("monitor", false) => 1,
        _ => 2,
    });
    Ok(sources)
}

#[tauri::command]
async fn capture_screenshot(source: NativeCaptureSource) -> Result<NativeCaptureResult, String> {
    tauri::async_runtime::spawn_blocking(move || capture::capture_png(source))
        .await
        .map_err(|error| format!("Capture task failed: {error}"))?
}

#[tauri::command]
async fn capture_video_frame(source: NativeCaptureSource) -> Result<tauri::ipc::Response, String> {
    let bytes = tauri::async_runtime::spawn_blocking(move || capture::capture_fast_png(source))
        .await
        .map_err(|error| format!("Capture task failed: {error}"))??;
    Ok(tauri::ipc::Response::new(bytes))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![
            list_capture_sources,
            capture_screenshot,
            capture_video_frame
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tempus");
}
