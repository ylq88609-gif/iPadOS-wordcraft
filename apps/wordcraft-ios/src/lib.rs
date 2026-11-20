//! iPadOS 2018 Pro Native Port Entry for WordCraft.
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::unimplemented,
    clippy::todo,
    clippy::unreachable
)]

use std::ffi::{CStr, CString, c_char};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock};

use eframe::egui;
use wordcraft_engine::Session;
use wordcraft_ui_egui::{FileDialogAnswer, FileDialogRequest, Inbox, Services, UiState, WordApp};

type IosFilePickerFn = unsafe extern "C" fn(*const c_char);
type IosFileExporterFn = unsafe extern "C" fn(*const c_char);
type IosImeSyncFn = unsafe extern "C" fn(bool, f32, f32, f32, f32);
type IosClipboardGetFn = unsafe extern "C" fn() -> *mut c_char;
type IosClipboardSetFn = unsafe extern "C" fn(*const c_char);
type IosFreeStrFn = unsafe extern "C" fn(*mut c_char);

/// Legacy commercial fonts that older builds copied from `WordFonts` into the user font directory.
/// Removed once on upgrade so only open-source bundled fonts and user-imported fonts remain.
const LEGACY_COMMERCIAL_FONTS: &[&str] = &[
    "msyh.ttc",
    "msyhbd.ttc",
    "simsun.ttc",
    "Deng.ttf",
    "Dengb.ttf",
    "simkai.ttf",
    "simfang.ttf",
    "simhei.ttf",
    "YuGothB.ttc",
    "YuGothM.ttc",
    "msmincho.ttc",
    "meiryob.ttc",
    "meiryo.ttc",
    "msgothic.ttc",
    "calibri.ttf",
    "calibrib.ttf",
    "times.ttf",
    "timesbd.ttf",
    "arial.ttf",
];

fn ios_file_picker() -> &'static Mutex<Option<IosFilePickerFn>> {
    static PICKER: OnceLock<Mutex<Option<IosFilePickerFn>>> = OnceLock::new();
    PICKER.get_or_init(|| Mutex::new(None))
}

fn ios_file_exporter() -> &'static Mutex<Option<IosFileExporterFn>> {
    static EXPORTER: OnceLock<Mutex<Option<IosFileExporterFn>>> = OnceLock::new();
    EXPORTER.get_or_init(|| Mutex::new(None))
}

fn ios_clipboard_get() -> &'static Mutex<Option<(IosClipboardGetFn, IosFreeStrFn)>> {
    static CB: OnceLock<Mutex<Option<(IosClipboardGetFn, IosFreeStrFn)>>> = OnceLock::new();
    CB.get_or_init(|| Mutex::new(None))
}

fn ios_clipboard_set() -> &'static Mutex<Option<IosClipboardSetFn>> {
    static CB: OnceLock<Mutex<Option<IosClipboardSetFn>>> = OnceLock::new();
    CB.get_or_init(|| Mutex::new(None))
}

fn ios_ime_sync() -> &'static Mutex<Option<IosImeSyncFn>> {
    static IME_SYNC: OnceLock<Mutex<Option<IosImeSyncFn>>> = OnceLock::new();
    IME_SYNC.get_or_init(|| Mutex::new(None))
}

fn ios_pending_events() -> &'static Mutex<Vec<egui::Event>> {
    static EVENTS: OnceLock<Mutex<Vec<egui::Event>>> = OnceLock::new();
    EVENTS.get_or_init(|| Mutex::new(Vec::new()))
}

fn ios_dialog_sender() -> &'static Mutex<Option<Sender<FileDialogAnswer>>> {
    static SENDER: OnceLock<Mutex<Option<Sender<FileDialogAnswer>>>> = OnceLock::new();
    SENDER.get_or_init(|| Mutex::new(None))
}

fn ios_inbox() -> Inbox {
    static INBOX: OnceLock<Inbox> = OnceLock::new();
    INBOX.get_or_init(|| Arc::new(Mutex::new(Vec::new()))).clone()
}

fn ios_picker_errors() -> &'static Mutex<Vec<String>> {
    static ERRORS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
    ERRORS.get_or_init(|| Mutex::new(Vec::new()))
}

fn ios_egui_ctx() -> &'static Mutex<Option<egui::Context>> {
    static CTX: OnceLock<Mutex<Option<egui::Context>>> = OnceLock::new();
    CTX.get_or_init(|| Mutex::new(None))
}

fn request_ios_repaint() {
    if let Some(ctx) = ios_egui_ctx().lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_ref() {
        ctx.request_repaint();
    }
}

/// Registers the native iOS `UIDocumentPickerViewController` launcher from `main.m`.
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_register_file_picker(picker: Option<IosFilePickerFn>) {
    *ios_file_picker().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = picker;
}

/// Registers the native iOS `UIDocumentPickerViewController` exporter from `main.m`.
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_register_file_exporter(exporter: Option<IosFileExporterFn>) {
    *ios_file_exporter().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = exporter;
}

/// Registers native iOS `UIPasteboard` helpers from `main.m`.
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_register_clipboard(
    get_fn: Option<IosClipboardGetFn>,
    free_fn: Option<IosFreeStrFn>,
    set_fn: Option<IosClipboardSetFn>,
) {
    if let (Some(g), Some(f)) = (get_fn, free_fn) {
        *ios_clipboard_get().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some((g, f));
    }
    *ios_clipboard_set().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = set_fn;
}

fn hid_to_egui_key(hid: i32) -> Option<egui::Key> {
    match hid {
        4 => Some(egui::Key::A),
        5 => Some(egui::Key::B),
        6 => Some(egui::Key::C),
        7 => Some(egui::Key::D),
        8 => Some(egui::Key::E),
        9 => Some(egui::Key::F),
        10 => Some(egui::Key::G),
        11 => Some(egui::Key::H),
        12 => Some(egui::Key::I),
        13 => Some(egui::Key::J),
        14 => Some(egui::Key::K),
        15 => Some(egui::Key::L),
        16 => Some(egui::Key::M),
        17 => Some(egui::Key::N),
        18 => Some(egui::Key::O),
        19 => Some(egui::Key::P),
        20 => Some(egui::Key::Q),
        21 => Some(egui::Key::R),
        22 => Some(egui::Key::S),
        23 => Some(egui::Key::T),
        24 => Some(egui::Key::U),
        25 => Some(egui::Key::V),
        26 => Some(egui::Key::W),
        27 => Some(egui::Key::X),
        28 => Some(egui::Key::Y),
        29 => Some(egui::Key::Z),
        30 => Some(egui::Key::Num1),
        31 => Some(egui::Key::Num2),
        32 => Some(egui::Key::Num3),
        33 => Some(egui::Key::Num4),
        34 => Some(egui::Key::Num5),
        35 => Some(egui::Key::Num6),
        36 => Some(egui::Key::Num7),
        37 => Some(egui::Key::Num8),
        38 => Some(egui::Key::Num9),
        39 => Some(egui::Key::Num0),
        40 => Some(egui::Key::Enter),
        41 => Some(egui::Key::Escape),
        42 => Some(egui::Key::Backspace),
        43 => Some(egui::Key::Tab),
        44 => Some(egui::Key::Space),
        45 => Some(egui::Key::Minus),
        46 => Some(egui::Key::Equals),
        47 => Some(egui::Key::OpenBracket),
        48 => Some(egui::Key::CloseBracket),
        54 => Some(egui::Key::Comma),
        55 => Some(egui::Key::Period),
        56 => Some(egui::Key::Slash),
        74 => Some(egui::Key::Home),
        75 => Some(egui::Key::PageUp),
        76 => Some(egui::Key::Delete),
        77 => Some(egui::Key::End),
        78 => Some(egui::Key::PageDown),
        79 => Some(egui::Key::ArrowRight),
        80 => Some(egui::Key::ArrowLeft),
        81 => Some(egui::Key::ArrowDown),
        82 => Some(egui::Key::ArrowUp),
        _ => None,
    }
}

/// Called by Objective-C (`main.m`) for Magic Keyboard shortcuts (`mod_flags`: 1=Shift, 2=Ctrl, 4=Alt, 8=Cmd).
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_ime_shortcut(hid_code: i32, mod_flags: i32) {
    let Some(key) = hid_to_egui_key(hid_code) else { return; };
    let shift = (mod_flags & 1) != 0;
    let ctrl = (mod_flags & 2) != 0;
    let alt = (mod_flags & 4) != 0;
    let cmd = (mod_flags & 8) != 0;
    let modifiers = egui::Modifiers {
        alt,
        ctrl,
        shift,
        mac_cmd: cmd,
        command: cmd || ctrl,
    };
    let mut events = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if cmd && !shift && !alt && !ctrl {
        if key == egui::Key::C {
            events.push(egui::Event::Copy);
        } else if key == egui::Key::X {
            events.push(egui::Event::Cut);
        }
    }
    events.push(egui::Event::Key {
        key,
        physical_key: Some(key),
        pressed: true,
        repeat: false,
        modifiers,
    });
    events.push(egui::Event::Key {
        key,
        physical_key: Some(key),
        pressed: false,
        repeat: false,
        modifiers,
    });
    drop(events);
    request_ios_repaint();
}

/// Called by Objective-C (`main.m`) when pasting text from `UIPasteboard`.
///
/// # Safety
/// `text_ptr` must be a valid NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wordcraft_ios_paste_text(text_ptr: *const c_char) {
    if text_ptr.is_null() {
        return;
    }
    let text = unsafe { CStr::from_ptr(text_ptr) }.to_string_lossy().into_owned();
    if text.is_empty() {
        return;
    }
    let mut events = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    events.push(egui::Event::Paste(text));
    drop(events);
    request_ios_repaint();
}

/// Registers the native iOS `UITextInput` keyboard/IME synchronizer from `main.m`.
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_register_ime_sync(sync_fn: Option<IosImeSyncFn>) {
    *ios_ime_sync().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = sync_fn;
}

/// Called by Objective-C (`main.m`) during `UITextInput` `setMarkedText:selectedRange:` (CJK/IME composition).
///
/// # Safety
/// `text_ptr` must be a valid NUL-terminated UTF-8 C string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wordcraft_ios_ime_preedit(
    text_ptr: *const c_char,
    cursor_start: i32,
    cursor_end: i32,
) {
    let text = if text_ptr.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(text_ptr) }.to_string_lossy().into_owned()
    };
    let char_len = text.chars().count();
    let active_range_chars = if cursor_start >= 0 && cursor_end >= cursor_start {
        let s = (cursor_start as usize).min(char_len);
        let e = (cursor_end as usize).min(char_len);
        Some(s..e)
    } else if char_len > 0 {
        Some(0..char_len)
    } else {
        None
    };
    let mut events = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    events.push(egui::Event::Ime(egui::ImeEvent::Preedit {
        text,
        active_range_chars,
    }));
    drop(events);
    request_ios_repaint();
}

/// Called by Objective-C (`main.m`) when `UITextInput` commits finalized text (Chinese/Japanese/English/etc.).
///
/// # Safety
/// `text_ptr` must be a valid NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wordcraft_ios_ime_commit(text_ptr: *const c_char) {
    if text_ptr.is_null() {
        return;
    }
    let text = unsafe { CStr::from_ptr(text_ptr) }.to_string_lossy().into_owned();
    if text.is_empty() {
        return;
    }
    let mut events = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    events.push(egui::Event::Ime(egui::ImeEvent::Commit(text)));
    drop(events);
    request_ios_repaint();
}

/// Called by Objective-C (`main.m`) when `UIPanGestureRecognizer` detects finger swipe or trackpad scroll.
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_scroll(x: f32, y: f32, dx: f32, dy: f32) {
    let mut events = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    events.push(egui::Event::PointerMoved(egui::pos2(x, y)));
    events.push(egui::Event::MouseWheel {
        unit: egui::MouseWheelUnit::Point,
        delta: egui::vec2(dx, dy),
        phase: egui::TouchPhase::Move,
        source: egui::MouseWheelSource::Unknown,
        modifiers: egui::Modifiers::NONE,
    });
    drop(events);
    request_ios_repaint();
}

/// Called by Objective-C (`main.m`) for special non-text keys (`1`=Backspace, `2`=Enter, `3`=Tab,
/// `4`=ArrowLeft, `5`=ArrowRight, `6`=ArrowUp, `7`=ArrowDown, `8`=Escape).
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_ime_key(key_code: i32) {
    let key = match key_code {
        1 => egui::Key::Backspace,
        2 => egui::Key::Enter,
        3 => egui::Key::Tab,
        4 => egui::Key::ArrowLeft,
        5 => egui::Key::ArrowRight,
        6 => egui::Key::ArrowUp,
        7 => egui::Key::ArrowDown,
        8 => egui::Key::Escape,
        _ => return,
    };
    let mut events = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    events.push(egui::Event::Key {
        key,
        physical_key: Some(key),
        pressed: true,
        repeat: false,
        modifiers: egui::Modifiers::NONE,
    });
    events.push(egui::Event::Key {
        key,
        physical_key: Some(key),
        pressed: false,
        repeat: false,
        modifiers: egui::Modifiers::NONE,
    });
    drop(events);
    request_ios_repaint();
}

/// Called by Objective-C (`main.m`) when `UIDocumentPickerViewController` finishes reading a file.
///
/// # Safety
/// `name_ptr` must be a valid NUL-terminated UTF-8 C string and `data_ptr` must point to `data_len`
/// readable bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wordcraft_ios_deliver_file(
    name_ptr: *const c_char,
    data_ptr: *const u8,
    data_len: usize,
) {
    if name_ptr.is_null() || (data_ptr.is_null() && data_len > 0) {
        return;
    }
    let name = unsafe { CStr::from_ptr(name_ptr) }.to_string_lossy().into_owned();
    if data_len > wordcraft_fonts::MAX_FONT_FILE_BYTES && wordcraft_fonts::is_font_file_name(&name.to_ascii_lowercase()) {
        let mut errs = ios_picker_errors().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        errs.push(format!(
            "Font import failed: {} exceeds the {} MB size limit.",
            name,
            wordcraft_fonts::MAX_FONT_FILE_BYTES >> 20
        ));
        drop(errs);
        request_ios_repaint();
        return;
    }
    let bytes = if data_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(data_ptr, data_len) }.to_vec()
    };

    // If a non-blocking `file_dialog` open request is waiting, write to Documents and answer it.
    let pending_tx = ios_dialog_sender().lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    if let Some(tx) = pending_tx {
        let docs = ios_documents_dir();
        let _ = std::fs::create_dir_all(&docs);
        let safe_name = Path::new(&name)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| "Document.docx".to_string());
        let dest = docs.join(&safe_name);
        match std::fs::write(&dest, &bytes) {
            Ok(()) => {
                let _ = tx.send(Ok(vec![dest.to_string_lossy().into_owned()]));
            }
            Err(e) => {
                let _ = tx.send(Err(format!("写入本地打开缓存失败: {e}")));
            }
        }
        request_ios_repaint();
        return;
    }

    let inbox = ios_inbox();
    let mut guard = inbox.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    guard.push((name, bytes));
    drop(guard);
    request_ios_repaint();
}

/// Called by Objective-C (`main.m`) when `UIDocumentPickerViewController` is cancelled.
#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_cancel_dialog() {
    if let Some(tx) = ios_dialog_sender().lock().unwrap_or_else(std::sync::PoisonError::into_inner).take() {
        let _ = tx.send(Ok(Vec::new()));
        request_ios_repaint();
    }
}

/// Called by Objective-C (`main.m`) when `UIDocumentPickerViewController` encounters a read or
/// permission error.
///
/// # Safety
/// `msg_ptr` must be a valid NUL-terminated UTF-8 C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wordcraft_ios_report_picker_error(msg_ptr: *const c_char) {
    if msg_ptr.is_null() {
        return;
    }
    let msg = unsafe { CStr::from_ptr(msg_ptr) }.to_string_lossy().into_owned();
    if let Some(tx) = ios_dialog_sender().lock().unwrap_or_else(std::sync::PoisonError::into_inner).take() {
        let _ = tx.send(Err(msg.clone()));
    }
    if !msg.trim().is_empty() {
        let mut errs = ios_picker_errors().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        errs.push(msg);
        drop(errs);
        request_ios_repaint();
    }
}

fn ios_documents_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|h| h.join("Documents"))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn ios_config_dir() -> PathBuf {
    ios_documents_dir().join(".config").join("wordcraft")
}

fn ios_user_fonts_dir() -> PathBuf {
    ios_config_dir().join("fonts")
}

fn ios_bundle_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(PathBuf::from))
}

fn cleanup_legacy_commercial_fonts(config_dir: &Path, user_fonts: &Path) {
    let marker = config_dir.join(".cleaned_legacy_wordfonts_v1");
    if marker.exists() {
        return;
    }
    for name in LEGACY_COMMERCIAL_FONTS {
        let path = user_fonts.join(name);
        if path.is_file() {
            let _ = std::fs::remove_file(&path);
        }
    }
    let _ = std::fs::write(
        &marker,
        b"Legacy un-licensed commercial fonts cleaned; bundled open-source fonts are loaded read-only from the app bundle.\n",
    );
}

fn sync_bundled_word_resources() {
    let docs = ios_documents_dir();
    let config_dir = ios_config_dir();
    let user_fonts = ios_user_fonts_dir();
    let _ = std::fs::create_dir_all(&user_fonts);

    cleanup_legacy_commercial_fonts(&config_dir, &user_fonts);

    let (loaded, skipped) = wordcraft_fonts::FontDb::global().load_user_fonts(&user_fonts);
    if !loaded.is_empty() || !skipped.is_empty() {
        log::info!(
            "iOS user fonts: {} loaded, {} skipped from {}",
            loaded.len(),
            skipped.len(),
            user_fonts.display()
        );
    }
    wordcraft_fonts::FontDb::global().scan_in_background();

    if let Some(bundle) = ios_bundle_dir() {
        let bundled_docs = bundle.join("WordDocs");
        if let Ok(entries) = std::fs::read_dir(bundled_docs) {
            for entry in entries.flatten() {
                let dest = docs.join(entry.file_name());
                if !dest.exists() {
                    let _ = std::fs::copy(entry.path(), dest);
                }
            }
        }
    }
}

fn ios_prefs_path() -> PathBuf {
    ios_config_dir().join("ui.json")
}

fn load_ios_prefs(app: &mut WordApp) {
    let path = ios_prefs_path();
    if let Ok(bytes) = std::fs::read(&path)
        && let Some(ui) = UiState::from_json(&bytes)
    {
        app.apply_prefs(ui);
    }
}

fn try_save_ios_prefs(app: &WordApp) -> Result<bool, String> {
    let path = ios_prefs_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    let bytes = serde_json::to_vec_pretty(&app.prefs()).map_err(|e| format!("cannot serialize preferences: {e}"))?;
    let tmp = path.with_extension("json.part");
    std::fs::write(&tmp, &bytes).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("cannot save {}: {e}", path.display()))?;
    Ok(true)
}

fn launch_ios_picker(purpose: &str) {
    let picker = *ios_file_picker().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(f) = picker
        && let Ok(c_purpose) = CString::new(purpose)
    {
        unsafe {
            f(c_purpose.as_ptr());
        }
    }
}

fn ios_services() -> Services {
    let templates_dir = ios_config_dir().join("Templates");
    let _ = std::fs::create_dir_all(&templates_dir);
    Services {
        inbox: Some(ios_inbox()),
        open_async: Some(Box::new(|purpose| {
            launch_ios_picker(purpose);
        })),
        file_dialog: Some(Box::new(|req| {
            let (tx, rx) = std::sync::mpsc::channel();
            match req {
                FileDialogRequest::Open { purpose } | FileDialogRequest::OpenMany { purpose } => {
                    *ios_dialog_sender().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(tx);
                    launch_ios_picker(&purpose);
                }
                FileDialogRequest::Save { name, .. } => {
                    let docs = ios_documents_dir();
                    let _ = std::fs::create_dir_all(&docs);
                    let safe_name = Path::new(&name)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .filter(|n| !n.is_empty())
                        .unwrap_or_else(|| "Document.docx".to_string());
                    let dest = docs.join(&safe_name);
                    let _ = tx.send(Ok(vec![dest.to_string_lossy().into_owned()]));
                }
            }
            rx
        })),
        download: Some(Box::new(|name, bytes| {
            let docs = ios_documents_dir();
            let _ = std::fs::create_dir_all(&docs);
            let safe_name = Path::new(name)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| "Document.docx".to_string());
            let dest = docs.join(&safe_name);
            std::fs::write(&dest, bytes).map_err(|e| format!("无法保存文件到本地: {e}"))?;
            let exporter = *ios_file_exporter().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = exporter
                && let Ok(c_path) = CString::new(dest.to_string_lossy().as_bytes())
            {
                unsafe {
                    f(c_path.as_ptr());
                }
            }
            Ok(())
        })),
        clipboard_text: Some(Box::new(|| {
            let cb = *ios_clipboard_get().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let (get_fn, free_fn) = cb?;
            let ptr = unsafe { get_fn() };
            if ptr.is_null() {
                return None;
            }
            let text = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
            unsafe { free_fn(ptr) };
            Some(text)
        })),
        set_clipboard_rich: Some(Box::new(|text, _html, _rtf, _mathml| {
            let cb = *ios_clipboard_set().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = cb
                && let Ok(c_text) = CString::new(text)
            {
                unsafe { f(c_text.as_ptr()) };
                return true;
            }
            false
        })),
        save_prefs: Some(Box::new(try_save_ios_prefs)),
        templates_dir: Some(templates_dir),
        ..Default::default()
    }
}

pub struct IpadApp {
    inner: WordApp,
    last_ime_active: bool,
    last_ime_rect: (f32, f32, f32, f32),
}

impl IpadApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        *ios_egui_ctx().lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(cc.egui_ctx.clone());
        sync_bundled_word_resources();

        let doc = wordcraft_engine::sample::sample_document();
        let session = Session::new(doc);
        let mut inner = WordApp::new(session, ios_services());
        inner.disable_self_update();
        load_ios_prefs(&mut inner);

        let docs = ios_documents_dir();
        let _ = std::fs::create_dir_all(&docs);
        let _ = std::env::set_current_dir(&docs);

        Self {
            inner,
            last_ime_active: false,
            last_ime_rect: (0.0, 0.0, 0.0, 0.0),
        }
    }
}

impl eframe::App for IpadApp {
    fn raw_input_hook(&mut self, _ctx: &egui::Context, raw_input: &mut egui::RawInput) {
        const Y_OFFSET: f32 = 18.0;
        for ev in &mut raw_input.events {
            match ev {
                egui::Event::PointerMoved(pos)
                | egui::Event::PointerButton { pos, .. }
                | egui::Event::Touch { pos, .. } => {
                    pos.y = (pos.y - Y_OFFSET).max(0.0);
                }
                _ => {}
            }
        }
        let mut pending = ios_pending_events().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !pending.is_empty() {
            raw_input.events.append(&mut *pending);
        }
    }

    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let mut errs = ios_picker_errors().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for err in errs.drain(..) {
            self.inner.status(err);
        }
        drop(errs);
        self.inner.logic(ctx);
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.inner.ui(ui);

        let ctx = ui.ctx();
        let ime_out = ctx.output(|o| o.ime.clone());
        let ime_active = ctx.egui_wants_keyboard_input() || ime_out.is_some();
        let (x, y, w, h) = ime_out
            .map(|i| (i.cursor_rect.min.x, i.cursor_rect.min.y, i.cursor_rect.width(), i.cursor_rect.height()))
            .unwrap_or((120.0, 220.0, 2.0, 20.0));

        let rect_changed = (x - self.last_ime_rect.0).abs() > 4.0 || (y - self.last_ime_rect.1).abs() > 4.0;
        if ime_active != self.last_ime_active || (ime_active && rect_changed) {
            let sync_fn = *ios_ime_sync().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(f) = sync_fn {
                unsafe {
                    f(ime_active, x, y, w, h);
                }
            }
            self.last_ime_active = ime_active;
            self.last_ime_rect = (x, y, w, h);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn wordcraft_ios_main() {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_fullscreen(true)
            .with_title("WordCraft"),
        ..Default::default()
    };

    let _ = eframe::run_native(
        "WordCraft",
        options,
        Box::new(|cc| Ok(Box::new(IpadApp::new(cc)))),
    );
}
