//! File › Options (#485): a list of panes on the left (General, Display, Proofing, Save,
//! Language, Accessibility, Advanced, Agents), the chosen pane's settings on the right. Only
//! settings WordCraft carries out are shown. Each pane is one function below, so a new setting
//! goes into its pane's function. Settings agents can change too go through `file.options`; the
//! rest live in [`crate::UiState`] (saved in `ui.json`).

use std::cell::Cell;

use egui::{RichText, Ui, vec2};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};
use wordcraft_engine::cmd::options::{MAX_WORD_CHARS, PANES};
use wordcraft_geom::Unit;

use crate::WordApp;
use crate::theme::{Tokens, semibold};

thread_local! {
    // The unit dialogs and the ribbon show lengths in: File › Options › Advanced, copied from the
    // session each frame so dialog code without the app can read it.
    static UNIT: Cell<Unit> = const { Cell::new(Unit::Inches) };
    // The region's decimal separator (#838).
    static DECIMAL: Cell<char> = const { Cell::new('.') };
}

/// The unit lengths are shown in (File › Options › Advanced › Measurement units, else the
/// region's).
pub fn unit() -> Unit {
    UNIT.get()
}

/// The decimal separator lengths are written with (the region's: `,` in Poland).
pub fn decimal() -> char {
    DECIMAL.get()
}

/// `pt` in [`unit`], written the region's way (`2,54 cm`), with the unit in the interface
/// language (`2,54 см` in Russian).
pub fn length(pt: f32) -> String {
    length_in(unit(), pt)
}

/// [`length`] in a given unit.
pub fn length_in(unit: Unit, pt: f32) -> String {
    format!("{}{}", unit.number(pt, decimal()), unit_suffix(unit))
}

/// The unit's suffix as the interface shows it: ` cm`, ` mm`, ` pt` and ` pi` go through the
/// catalog (` см` in Russian, #1734); inches keep `"`.
pub fn unit_suffix(unit: Unit) -> String {
    match unit {
        Unit::Inches => unit.suffix().to_string(),
        Unit::Centimeters => format!(" {}", tl!("cm")),
        Unit::Millimeters => format!(" {}", tl!("mm")),
        Unit::Points => format!(" {}", tl!("pt")),
        Unit::Picas => format!(" {}", tl!("pi")),
    }
}

/// A length typed into a field in `unit`, as a number of that unit: either decimal separator,
/// another unit (`1 in` in a centimetre field), and the units' names in the interface language
/// as well as in English (`3 см`).
pub fn parse_length(text: &str, unit: Unit) -> Option<f64> {
    let mut text: String = text.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_lowercase();
    for (english, translated) in [("cm", tl!("cm")), ("mm", tl!("mm")), ("pt", tl!("pt")), ("pi", tl!("pi"))] {
        let translated = translated.to_lowercase();
        if translated != english
            && let Some(number) = text.strip_suffix(translated.as_str())
        {
            text = format!("{number}{english}");
            break;
        }
    }
    wordcraft_geom::parse_measure(&text, unit).map(|pt| f64::from(pt / unit.pt_per_unit()))
}

/// Copy the session's settings the UI reads without the app.
pub(crate) fn sync(app: &WordApp) {
    UNIT.set(app.session.units());
    DECIMAL.set(app.session.region().decimal());
}

/// A length field: the unit's suffix, and numbers written and read with the region's decimal
/// separator (`2,54 cm`). Typing either separator works, and so does another unit (`1 in` in a
/// centimetre field).
pub trait MeasureExt {
    fn measure(self, unit: Unit) -> Self;
    /// The same field showing nothing, not even the unit, until a length is typed in: a value
    /// the selected paragraphs differ in.
    fn measure_blank(self, unit: Unit) -> Self;
}

impl MeasureExt for egui::DragValue<'_> {
    fn measure(self, unit: Unit) -> Self {
        let sep = decimal();
        self.suffix(unit_suffix(unit))
            .custom_formatter(move |n, decimals| {
                let s = egui::emath::format_with_decimals_in_range(n, decimals);
                if sep == '.' { s } else { s.replace('.', &sep.to_string()) }
            })
            .custom_parser(move |text| parse_length(text, unit))
    }
    fn measure_blank(self, unit: Unit) -> Self {
        self.custom_formatter(|_, _| String::new()).custom_parser(move |text| parse_length(text, unit))
    }
}

/// Regions offered in File › Options › Advanced › Region (any locale tag works through
/// `file.options`): Letter and A4 countries, decimal point and decimal comma.
const REGIONS: [&str; 16] =
    ["en-US", "en-CA", "en-GB", "en-AU", "en-IN", "es-MX", "es-ES", "pt-BR", "fr-FR", "de-DE", "it-IT", "pl-PL", "ru-RU", "ja-JP", "zh-CN", "ko-KR"];

/// The units offered, with their names.
pub const UNITS: [(Unit, &str); 5] = [
    (Unit::Inches, "Inches"),
    (Unit::Centimeters, "Centimeters"),
    (Unit::Millimeters, "Millimeters"),
    (Unit::Points, "Points"),
    (Unit::Picas, "Picas"),
];

const UI_PANES: [&str; 9] = [
    "general",
    "display",
    "proofing",
    "save",
    "language",
    "fonts",
    "accessibility",
    "advanced",
    "agents",
];

/// The pane names, in [`UI_PANES`] order.
fn pane_label(id: &str) -> &'static str {
    match id {
        "display" => "Display",
        "proofing" => "Proofing",
        "save" => "Save",
        "language" => "Language",
        "fonts" => "Fonts",
        "accessibility" => "Accessibility",
        "advanced" => "Advanced",
        "agents" => "Agents",
        _ => "General",
    }
}

/// The Options page.
pub fn page(app: &mut WordApp, ui: &mut Ui) {
    let t = Tokens::get(ui.ctx());
    ui.label(RichText::new(tl!("Options")).font(semibold(26.0)));
    ui.add_space(16.0);
    let current = if UI_PANES.contains(&app.ui.options_pane.as_str()) || PANES.contains(&app.ui.options_pane.as_str()) { app.ui.options_pane.clone() } else { "general".to_string() };
    let rtl = crate::rtl::on();
    let body = |ui: &mut Ui| {
        crate::rtl::vertical(ui, |ui| {
            ui.set_width(170.0);
            for id in UI_PANES {
                let label = tl!(pane_label(id));
                let active = current == id;
                let (r, resp) = ui.allocate_exact_size(vec2(170.0, 30.0), egui::Sense::click());
                resp.widget_info(|| egui::WidgetInfo::selected(egui::Role::Button, true, active, label));
                if active {
                    ui.painter().rect_filled(r, 4.0, t.checked);
                } else if resp.hovered() {
                    ui.painter().rect_filled(r, 4.0, t.hover);
                }
                let font = if active { semibold(14.0) } else { crate::theme::regular(14.0) };
                // Long translations stay inside the row; WidgetInfo above keeps the full name.
                ui.painter().with_clip_rect(r).text(
                    egui::pos2(crate::rtl::lead_x(rtl, r, 12.0), r.center().y),
                    crate::rtl::lead_center(rtl),
                    label,
                    font,
                    t.text,
                );
                if resp.clicked() {
                    app.ui.options_pane = id.to_string();
                }
            }
        });
        ui.add_space(12.0);
        let (line, _) = ui.allocate_exact_size(vec2(1.0, 420.0), egui::Sense::hover());
        ui.painter().rect_filled(line, 0.0, t.border);
        ui.add_space(20.0);
        crate::rtl::vertical(ui, |ui| {
            ui.set_max_width(640.0);
            match current.as_str() {
                "display" => display(app, ui),
                "proofing" => proofing(app, ui),
                "save" => save(app, ui),
                "language" => language(app, ui),
                "fonts" => fonts(app, ui),
                "accessibility" => accessibility(app, ui),
                "advanced" => advanced(app, ui),
                "agents" => agents(ui),
                _ => general(app, ui),
            }
        });
    };
    // Right to left the pane list is on the right and the settings fill in from it.
    if rtl {
        ui.with_layout(crate::rtl::row_layout(ui, egui::Align::Min), body)
    } else {
        crate::rtl::horizontal_top(ui, body)
    };
}

fn section(ui: &mut Ui, title: &str) {
    ui.add_space(6.0);
    ui.label(RichText::new(tl!(title)).font(semibold(15.0)));
    ui.add_space(2.0);
}

fn note(ui: &mut Ui, text: &str) {
    ui.label(RichText::new(tl!(text)).small().weak());
}

/// Change settings through `file.options` (the command agents use).
fn set(app: &mut WordApp, params: Value) {
    if let Err(e) = app.run("file.options", params) {
        app.status(e);
    }
}

/// A checkbox for a `file.options` on/off setting.
fn flag(app: &mut WordApp, ui: &mut Ui, label: &str, key: &str, value: bool) {
    let mut v = value;
    if ui.checkbox(&mut v, tl!(label)).changed() {
        set(app, json!({ key: v }));
    }
}

/// Draws General options: interface theme and size, mini toolbar, dark page, community button and
/// default apps; the Start screen; and personalization such as user name and initials.
fn general(app: &mut WordApp, ui: &mut Ui) {
    section(ui, "Interface");
    theme_picker(app, ui);
    interface_size_picker(app, ui);
    ui.horizontal(|ui| {
        use wordcraft_engine::cmd::view::PaperColor;
        let label = ui.label(tl!("Screen paper color:"));
        let selected = app.session.prefs.paper_color;
        let combo = craft_ui::ComboBox::from_id_salt("screen_paper_color").selected_text(tl!(selected.label())).width(220.0).show_ui(ui, |ui| {
            for color in PaperColor::ALL {
                if ui.selectable_label(selected == color, tl!(color.label())).clicked() {
                    let _ = app.run("view.paperColor", json!({"value": color}));
                }
            }
        });
        combo.response.labelled_by(label.id).on_hover_text(tl!(
            "Screen only. Document backgrounds, printing and exports keep their colours. Dark page and explicit Read Mode colours take precedence."
        ));
    });
    ui.checkbox(&mut app.ui.mini_toolbar, tl!("Show the mini toolbar when text is selected"));
    let mut dark_page = app.session.view.dark_mode;
    if ui
        .checkbox(&mut dark_page, tl!("Dark page (white text on black)"))
        .on_hover_text(tl!("Show documents with their colours inverted, like View › Switch Modes. Saving, printing and PDFs are unchanged."))
        .changed()
    {
        let _ = app.run("view.darkMode", json!({"value": dark_page}));
    }
    ui.checkbox(&mut app.ui.show_discord, tl!("Show the community button in the title bar"));
    default_app_button(app, ui);
    ui.add_space(8.0);
    section(ui, "Start-up");
    let mut start = app.ui.start_screen;
    if ui
        .checkbox(&mut start, tl!("Show the Start screen when WordCraft starts"))
        .on_hover_text(tl!(
            "On: WordCraft opens on File › Home, with a blank document, the templates and your recent documents. Off: it opens a blank document."
        ))
        .changed()
    {
        let _ = app.run("ui.startScreen", json!({"value": start}));
    }
    ui.add_space(8.0);
    section(ui, "Personalize");
    crate::rtl::Table::new("options_user").columns(2).spacing(vec2(8.0, 6.0)).show(ui, |t| {
        t.row(|r| {
            let user_label = r.cell(|ui| ui.label(tl!("User name:")));
            r.cell(|ui| {
                let mut n = app.session.author.clone();
                let protected = wordcraft_engine::cmd::protect::enforced(&app.session.doc);
                if ui.add_enabled(!protected, egui::TextEdit::singleline(&mut n).desired_width(260.0)).labelled_by(user_label.id).changed()
                    && !protected
                {
                    app.session.author = n;
                }
            });
        });
        t.row(|r| {
            let initials_label = r.cell(|ui| ui.label(tl!("Initials:")));
            r.cell(|ui| {
                let mut i = app.session.initials.clone();
                let hint = app.session.user_initials();
                if ui
                    .add(
                        egui::TextEdit::singleline(&mut i)
                            .desired_width(80.0)
                            .char_limit(wordcraft_engine::cmd::options::MAX_INITIALS_CHARS)
                            .hint_text(hint),
                    )
                    .labelled_by(initials_label.id)
                    .changed()
                {
                    set(app, json!({"initials": i}));
                }
            });
        });
    });
    note(ui, "New comments and tracked changes are recorded under this name and these initials.");
}

fn display(app: &mut WordApp, ui: &mut Ui) {
    section(ui, "Formatting marks");
    note(ui, "These marks show even when Show/Hide ¶ is off.");
    let m = app.session.prefs.marks;
    for (label, key, on) in [
        ("Tab characters", "tabs", m.tabs),
        ("Spaces", "spaces", m.spaces),
        ("Paragraph marks", "paragraphs", m.paragraphs),
        ("Hidden text", "hidden", m.hidden),
    ] {
        let mut v = on;
        if ui.checkbox(&mut v, tl!(label)).changed() {
            set(app, json!({"marks": { key: v }}));
        }
    }
    let mut marks = app.session.view.marks;
    if ui.checkbox(&mut marks, tl!("Show all formatting marks")).changed() {
        let _ = app.run("view.marks", json!({"value": marks}));
    }
    ui.add_space(8.0);
    section(ui, "Page display");
    let mut ruler = app.session.view.ruler;
    if ui.checkbox(&mut ruler, tl!("Show rulers")).changed() {
        let _ = app.run("view.ruler", json!({"value": ruler}));
    }
    numeral_picker(app, ui);
    ui.add_space(8.0);
    section(ui, "Status bar");
    status_count_picker(app, ui);
    ui.add_space(8.0);
    section(ui, "Printing");
    ui.checkbox(&mut app.ui.print_backgrounds, tl!("Print the page color"));
    ui.checkbox(&mut app.ui.update_fields_before_print, tl!("Update fields before printing"));
}

fn proofing(app: &mut WordApp, ui: &mut Ui) {
    section(ui, "AutoCorrect");
    if ui.button(tl!("AutoCorrect Options")).clicked() {
        let _ = app.run("tools.autocorrect", json!({}));
    }
    ui.add_space(8.0);
    section(ui, "Spelling");
    let pr = app.session.prefs.clone();
    flag(app, ui, "Ignore words in capitals", "ignoreUppercase", pr.ignore_uppercase);
    flag(app, ui, "Ignore words with numbers", "ignoreNumbers", pr.ignore_numbers);
    flag(app, ui, "Ignore web and file addresses", "ignoreInternet", pr.ignore_internet);
    ui.add_space(8.0);
    section(ui, "As you type");
    let spelling = app.session.view.proofing;
    flag(app, ui, "Check spelling as you type", "checkSpelling", spelling);
    ui.add_enabled_ui(app.session.view.proofing, |ui| flag(app, ui, "Mark grammar errors as you type", "markGrammar", pr.mark_grammar));
    ui.add_space(8.0);
    section(ui, "Custom dictionary");
    custom_dictionary(app, ui);
}

/// Where the spelling dictionaries come from (#1063): a folder searched before the system's
/// usual places, saved with the settings. An app started from Finder or the Dock doesn't see
/// `WORDCRAFT_DICTIONARIES`, so this is how it finds a dictionary kept in a folder of the user's
/// own. Each language's status ("Your own dictionary") is in Your languages above, and the file
/// each language found is under Dictionary files.
fn dictionaries(app: &mut WordApp, ui: &mut Ui) {
    let saved = app.session.prefs.dictionaries_folder.clone().unwrap_or_default();
    let id = egui::Id::unique("options_dictionaries_folder");
    let mut folder = ui.data(|d| d.get_temp::<String>(id)).unwrap_or_else(|| saved.clone());
    let folder_label = ui.label(tl!("Dictionaries folder:")).id;
    ui.horizontal(|ui| {
        let r = ui
            .add(egui::TextEdit::singleline(&mut folder).desired_width(320.0).hint_text(tl!("Not set: the system's usual places")))
            .labelled_by(folder_label);
        let enter = r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        let changed = folder.trim() != saved;
        if ui.add_enabled(changed, egui::Button::new(tl!("Apply"))).clicked() || (enter && changed) {
            let value = if folder.trim().is_empty() { "auto" } else { folder.trim() };
            match app.run("file.options", json!({"dictionariesFolder": value})) {
                // Shown as saved (`~/` expanded).
                Ok(_) => folder = app.session.prefs.dictionaries_folder.clone().unwrap_or_default(),
                Err(e) => app.status(e),
            }
        }
        if ui.add_enabled(!saved.is_empty(), egui::Button::new(tl!("Clear"))).clicked()
            && app.run("file.options", json!({"dictionariesFolder": "auto"})).is_ok()
        {
            folder.clear();
        }
    });
    ui.data_mut(|d| d.insert_temp(id, folder));
    note(ui, "Hunspell .aff and .dic files here (pl_PL, pt_BR, it_IT, hr_HR, tr_TR) are used before the system's.");
    note(ui, "An installed Language pack is used after this folder.");
    ui.add_space(6.0);
    ui.label(RichText::new(tl!("Dictionary files")).strong());
    dictionary_files(ui);
}

/// The dictionary each language found (#1063): its file, "no dictionary found", or why the file
/// couldn't be read, looked up again after the folder changes.
fn dictionary_files(ui: &mut Ui) {
    // The dictionary each language found, looked up again after the folder changes.
    let found_id = egui::Id::unique("options_dictionaries_found");
    let generation = wordcraft_engine::proof::dictionary_generation();
    let cached = ui.data(|d| d.get_temp::<(u64, Vec<(String, Option<String>, Option<String>)>)>(found_id)).filter(|(g, _)| *g == generation);
    let found = match cached {
        Some((_, f)) => f,
        None => {
            let f: Vec<(String, Option<String>, Option<String>)> = wordcraft_engine::proof::installed_dictionaries()
                .into_iter()
                .map(|(lang, dic)| {
                    let error = wordcraft_engine::proof::dictionary_load_error(lang);
                    (language_name(lang).to_string(), dic.map(|d| d.to_string_lossy().into_owned()), error)
                })
                .collect();
            ui.data_mut(|d| d.insert_temp(found_id, (generation, f.clone())));
            f
        }
    };
    for (language, file, error) in found {
        let line = match (file, error) {
            (Some(f), Some(e)) => crate::i18n::fmt(
                tl!("{language}: {file} (unreadable: {reason})"),
                &[("language", &language), ("file", &crate::i18n::isolate_path(&f)), ("reason", &e)],
            ),
            (Some(f), None) => crate::i18n::fmt(tl!("{language}: {file}"), &[("language", &language), ("file", &crate::i18n::isolate_path(&f))]),
            (None, _) => crate::i18n::fmt(tl!("{language}: no dictionary found"), &[("language", &language)]),
        };
        ui.add(egui::Label::new(RichText::new(line).small()).truncate());
    }
}

/// The interface name of a language with a Hunspell dictionary.
fn language_name(lang: wordcraft_engine::proof::ProofLang) -> &'static str {
    use wordcraft_engine::proof::ProofLang;
    match lang {
        ProofLang::Pl => tl!("Polish"),
        ProofLang::Pt => tl!("Portuguese (Brazil)"),
        ProofLang::It => tl!("Italian"),
        ProofLang::Hr => tl!("Croatian"),
        ProofLang::Tr => tl!("Turkish"),
        ProofLang::Ru => tl!("Russian"),
        ProofLang::Cs => tl!("Czech"),
        ProofLang::Id => tl!("Indonesian"),
        ProofLang::Es => tl!("Spanish (Spain)"),
        ProofLang::EsMx => tl!("Spanish (Mexico)"),
        ProofLang::Es419 => tl!("Spanish (Latin America)"),
        ProofLang::EsUy => tl!("Spanish (Uruguay)"),
        // English uses its bundled word list; Bulgarian and German have no dictionary yet.
        ProofLang::En
        | ProofLang::EnGb
        | ProofLang::EnCa
        | ProofLang::EnAu
        | ProofLang::Bg
        | ProofLang::De
        | ProofLang::Pack(_)
        | ProofLang::Other => "",
    }
}

/// The custom dictionary: the words Add to Dictionary kept, each with a Remove button, and a
/// field to add one.
fn custom_dictionary(app: &mut WordApp, ui: &mut Ui) {
    let words = wordcraft_engine::proof::user_dictionary();
    if words.is_empty() {
        note(ui, "No words yet. Add to Dictionary on a misspelled word puts it here.");
    }
    egui::ScrollArea::vertical().id_salt("options_dictionary").max_height(180.0).show(ui, |ui| {
        for w in &words {
            ui.horizontal(|ui| {
                ui.allocate_ui_with_layout(vec2(220.0, 20.0), egui::Layout::left_to_right(egui::Align::Center), |ui| {
                    ui.set_min_width(220.0);
                    ui.add(egui::Label::new(w.as_str()).truncate());
                });
                if ui.small_button(tl!("Remove")).clicked() {
                    set(app, json!({"removeWords": [w]}));
                }
            });
        }
    });
    let id = egui::Id::unique("options_dictionary_new");
    let mut word = ui.data(|d| d.get_temp::<String>(id)).unwrap_or_default();
    ui.horizontal(|ui| {
        let r = ui
            .add(egui::TextEdit::singleline(&mut word).desired_width(220.0).char_limit(MAX_WORD_CHARS).hint_text(tl!("New word")))
            .accessible_name(tl!("New word"));
        let enter = r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        let w = word.trim().to_string();
        let ok = !w.is_empty() && !w.chars().any(char::is_whitespace);
        if (ui.add_enabled(ok, egui::Button::new(tl!("Add"))).clicked() || (enter && ok)) && app.run("file.options", json!({"addWords": [w]})).is_ok()
        {
            word.clear();
        }
    });
    ui.data_mut(|d| d.insert_temp(id, word));
}

fn save(app: &mut WordApp, ui: &mut Ui) {
    section(ui, "Save documents");
    // The browser can't write to the user's files, so AutoSave can't be turned on there (#176).
    let browser = app.autosave_block() == Some(crate::AutoSaveBlock::Browser);
    let mut autosave = app.autosave && !browser;
    let r = ui.add_enabled_ui(!browser, |ui| ui.checkbox(&mut autosave, tl!("AutoSave documents you have saved in WordCraft"))).inner;
    if browser {
        r.on_disabled_hover_text(crate::AutoSaveBlock::Browser.reason());
    } else if r.changed() {
        app.autosave = autosave;
        app.session.autosave = autosave;
    }
    note(ui, "AutoSave writes your changes to the file a moment after you stop typing.");
    ui.add_space(8.0);
    // The open document's `file.privacyOptions` (#1062): saved with it, honoured when it is saved.
    section(ui, "Privacy for this document");
    let settings = &app.session.doc.settings;
    let rows = [
        ("Remove my name from comments, changes and file properties when saving", "removePersonalInfo", settings.remove_personal_info),
        ("Leave out the date and time of comments and tracked changes when saving", "removeDateTime", settings.remove_date_time),
    ];
    for (label, key, value) in rows {
        let mut v = value;
        if ui.checkbox(&mut v, tl!(label)).changed()
            && let Err(e) = app.run("file.privacyOptions", json!({ key: v }))
        {
            app.status(e);
        }
    }
    note(ui, "The document you are editing keeps the names and dates; only the saved file leaves them out.");
}

fn language(app: &mut WordApp, ui: &mut Ui) {
    section(ui, "Interface language");
    language_picker(app, ui);
    // #414 (detect the document's language) goes here.
    ui.add_space(8.0);
    section(ui, "Proofing language");
    let lang = crate::ribbon::caret_language(app);
    let text = if crate::ribbon::caret_no_proof(app) {
        tl!("The text at the insertion point is marked Do not check spelling or grammar.").to_string()
    } else if !crate::ribbon::caret_language_proofed(app) {
        crate::i18n::fmt(tl!("{language}: WordCraft doesn't check spelling or grammar in this language yet."), &[("language", &lang)])
    } else {
        let unreadable = crate::ribbon::caret_unreadable_dictionary(app);
        crate::chrome::dictionary_problem(&lang, &unreadable, crate::ribbon::caret_missing_dictionary(app))
            .unwrap_or_else(|| crate::i18n::fmt(tl!("Spelling and grammar are checked in {language}."), &[("language", &lang)]))
    };
    ui.label(RichText::new(text).small().weak());
    ui.add_space(8.0);
    crate::language_packs::your_languages_section(app, ui);
    ui.add_space(8.0);
    section(ui, "Dictionaries");
    dictionaries(app, ui);
    crate::language_packs::add_language_window(app, &ui.ctx().clone());
}

fn is_bundled_open_font(family: &str) -> bool {
    let f = family.trim().to_ascii_lowercase();
    matches!(
        f.as_str(),
        "source sans 3"
            | "source serif 4"
            | "inter"
            | "jetbrains mono"
            | "source han sans sc"
            | "source han serif sc"
            | "source han sans tc"
            | "source han serif tc"
            | "source han sans jp"
            | "source han serif jp"
            | "noto sans cjk sc"
            | "noto serif cjk sc"
            | "noto sans cjk tc"
            | "noto serif cjk tc"
            | "noto sans cjk hk"
            | "noto serif cjk hk"
            | "noto sans cjk jp"
            | "noto serif cjk jp"
            | "noto sans cjk kr"
            | "noto serif cjk kr"
            | "noto sans mono cjk sc"
            | "noto sans mono cjk tc"
            | "noto sans mono cjk hk"
            | "noto sans mono cjk jp"
            | "noto sans mono cjk kr"
            | "carlito"
            | "caladea"
            | "arimo"
            | "tinos"
            | "cousine"
            | "liberation sans"
            | "liberation serif"
            | "liberation mono"
    ) || f.starts_with("source sans 3 ")
        || f.starts_with("source serif 4 ")
        || f.starts_with("inter ")
        || f.starts_with("noto sans cjk ")
        || f.starts_with("noto serif cjk ")
        || f.starts_with("source han ")
}

const DEFAULT_FONT_TEST_TEXT: &str = "中文：中华人民共和国，中文字体测试。\n英文：The quick brown fox jumps over the lazy dog.\n日文：日本語のフォントテスト。\n数字：0123456789。";

/// File › Options › Fonts: three-subpage Font Management UI (Font List, Font Preview, Font Management & Licensing).
fn fonts(app: &mut WordApp, ui: &mut Ui) {
    let tab_id = egui::Id::unique("options_fonts_subtab");
    let mut subtab = ui.data(|d| d.get_temp::<u8>(tab_id)).unwrap_or(0);

    ui.horizontal(|ui| {
        for (idx, title) in [
            (0u8, tl!("Font List (字体列表)")),
            (1u8, tl!("Font Preview (字体预览)")),
            (2u8, tl!("Font Management (字体管理与授权)")),
        ] {
            if ui.selectable_label(subtab == idx, title).clicked() {
                subtab = idx;
            }
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.button(tl!("Import Font… (导入字体)")).clicked() {
                let _ = app.run("font.add", json!({}));
            }
        });
    });
    ui.data_mut(|d| d.insert_temp(tab_id, subtab));
    ui.separator();

    match subtab {
        0 => fonts_list_subpage(app, ui),
        1 => fonts_preview_subpage(app, ui),
        _ => fonts_manage_subpage(app, ui),
    }
}

fn fonts_list_subpage(app: &mut WordApp, ui: &mut Ui) {
    let db = wordcraft_fonts::FontDb::global();
    let user_list = db.user_fonts();
    let user_families: std::collections::HashSet<String> = user_list
        .iter()
        .flat_map(|u| u.families())
        .map(|f| f.to_ascii_lowercase())
        .collect();
    let ea_set: std::collections::HashSet<String> = db
        .east_asian_families()
        .into_iter()
        .map(|f| f.to_ascii_lowercase())
        .collect();

    let search_id = egui::Id::unique("options_fonts_search");
    let filter_id = egui::Id::unique("options_fonts_source_filter");
    let mut query = ui.data(|d| d.get_temp::<String>(search_id)).unwrap_or_default();
    let mut filter = ui.data(|d| d.get_temp::<u8>(filter_id)).unwrap_or(0);

    ui.horizontal(|ui| {
        ui.label(tl!("Search:"));
        ui.add(egui::TextEdit::singleline(&mut query).desired_width(200.0).hint_text(tl!("Filter by font name…")));
        ui.add_space(8.0);
        for (idx, label) in [
            (0u8, tl!("All")),
            (1u8, tl!("Built-in (内置)")),
            (2u8, tl!("User (用户导入)")),
            (3u8, tl!("System (系统)")),
        ] {
            if ui.selectable_label(filter == idx, label).clicked() {
                filter = idx;
            }
        }
    });
    ui.data_mut(|d| {
        d.insert_temp(search_id, query.clone());
        d.insert_temp(filter_id, filter);
    });
    ui.add_space(6.0);

    let all_families = db.families();
    let q_lower = query.trim().to_lowercase();
    let mut rows = Vec::new();
    for fam in &all_families {
        if fam.starts_with('.') {
            continue;
        }
        let shown = app.previews.font_shown(fam);
        if !q_lower.is_empty() && !fam.to_lowercase().contains(&q_lower) && !shown.to_lowercase().contains(&q_lower) {
            continue;
        }
        let lower = fam.to_ascii_lowercase();
        let is_user = user_families.contains(&lower);
        let is_bundled = !is_user && is_bundled_open_font(fam);
        match filter {
            1 if !is_bundled => continue,
            2 if !is_user => continue,
            3 if is_bundled || is_user => continue,
            _ => {}
        }
        let is_ea = ea_set.contains(&lower);
        let styles = db.styles(fam);
        rows.push((fam.clone(), shown, is_bundled, is_user, is_ea, styles));
    }

    note(
        ui,
        &format!(
            "Showing {} font families ({} user-imported files in sandbox).",
            rows.len(),
            user_list.len()
        ),
    );
    ui.add_space(4.0);

    egui::ScrollArea::vertical()
        .id_salt("options_fonts_list_scroll")
        .max_height(330.0)
        .show(ui, |ui| {
            crate::rtl::Table::new("options_fonts_table")
                .columns(4)
                .spacing(vec2(12.0, 6.0))
                .show(ui, |t| {
                    t.row(|r| {
                        r.cell(|ui| ui.label(RichText::new(tl!("Font Name (字体名称)")).strong()));
                        r.cell(|ui| ui.label(RichText::new(tl!("Type (类型)")).strong()));
                        r.cell(|ui| ui.label(RichText::new(tl!("Weights / Styles (字重)")).strong()));
                        r.cell(|ui| ui.label(RichText::new(tl!("Source (来源)")).strong()));
                    });
                    for (fam, shown, is_bundled, is_user, is_ea, styles) in rows {
                        t.row(|r| {
                            r.cell(|ui| {
                                let label = if shown.eq_ignore_ascii_case(&fam) {
                                    shown.clone()
                                } else {
                                    format!("{shown} ({fam})")
                                };
                                ui.add(egui::Label::new(label).truncate());
                            });
                            r.cell(|ui| {
                                let kind = if is_ea {
                                    tl!("CJK / East Asian")
                                } else if fam.to_ascii_lowercase().contains("mono") {
                                    tl!("Monospace")
                                } else if fam.to_ascii_lowercase().contains("serif")
                                    || matches!(fam.to_ascii_lowercase().as_str(), "caladea" | "tinos")
                                {
                                    tl!("Serif")
                                } else {
                                    tl!("Sans / Document")
                                };
                                ui.label(RichText::new(kind).small());
                            });
                            r.cell(|ui| {
                                let st = if styles.is_empty() {
                                    "Regular".to_string()
                                } else {
                                    styles.join(", ")
                                };
                                ui.add(egui::Label::new(RichText::new(st).small()).truncate());
                            });
                            r.cell(|ui| {
                                let badge = if is_user {
                                    tl!("User Imported (用户导入)")
                                } else if is_bundled {
                                    tl!("Built-in OFL (内置字体)")
                                } else {
                                    tl!("System Fallback (系统字体)")
                                };
                                ui.label(RichText::new(badge).small().weak());
                            });
                        });
                    }
                });
        });
}

fn fonts_preview_subpage(app: &mut WordApp, ui: &mut Ui) {
    let fam_id = egui::Id::unique("options_fonts_preview_family");
    let size_id = egui::Id::unique("options_fonts_preview_size");
    let bold_id = egui::Id::unique("options_fonts_preview_bold");
    let italic_id = egui::Id::unique("options_fonts_preview_italic");
    let text_id = egui::Id::unique("options_fonts_preview_text");

    let families = app.previews.families();
    let default_fam = families.first().cloned().unwrap_or_else(|| "Source Serif 4".to_string());
    let mut selected_fam = ui.data(|d| d.get_temp::<String>(fam_id)).unwrap_or(default_fam);
    let mut pt = ui.data(|d| d.get_temp::<f32>(size_id)).unwrap_or(14.0).clamp(8.0, 48.0);
    let mut bold = ui.data(|d| d.get_temp::<bool>(bold_id)).unwrap_or(false);
    let mut italic = ui.data(|d| d.get_temp::<bool>(italic_id)).unwrap_or(false);
    let mut sample_text = ui
        .data(|d| d.get_temp::<String>(text_id))
        .unwrap_or_else(|| DEFAULT_FONT_TEST_TEXT.to_string());

    ui.horizontal(|ui| {
        ui.label(tl!("Font:"));
        let prev = app.previews.font_preview_fn();
        if let Some(picked) = crate::widgets::font_combo(ui, "opt_font_prev_combo", 220.0, &selected_fam, &families, Some(&*prev)) {
            if picked == crate::widgets::ADD_FONT {
                let _ = app.run("font.add", json!({}));
            } else if picked != crate::widgets::MANAGE_FONTS && picked != crate::widgets::LOAD_SYSTEM_FONTS {
                selected_fam = picked;
            }
        }
        ui.add_space(8.0);
        ui.label(tl!("Size:"));
        ui.add(egui::DragValue::new(&mut pt).range(8.0..=48.0).speed(0.5).suffix(" pt"));
        ui.checkbox(&mut bold, tl!("Bold"));
        ui.checkbox(&mut italic, tl!("Italic"));
    });

    ui.add_space(6.0);
    ui.horizontal(|ui| {
        ui.label(RichText::new(tl!("Test text (中文 / English / 日本語 / 0-9):")).strong());
        if ui.small_button(tl!("Reset Default Sample (重置测试文本)")).clicked() {
            sample_text = DEFAULT_FONT_TEST_TEXT.to_string();
        }
    });
    ui.add(egui::TextEdit::multiline(&mut sample_text).desired_rows(4).desired_width(580.0));

    ui.data_mut(|d| {
        d.insert_temp(fam_id, selected_fam.clone());
        d.insert_temp(size_id, pt);
        d.insert_temp(bold_id, bold);
        d.insert_temp(italic_id, italic);
        d.insert_temp(text_id, sample_text.clone());
    });

    ui.add_space(8.0);
    ui.label(RichText::new(tl!("Live Document Engine Render Preview (排版引擎实时渲染预览):")).strong());

    let stored_fam = app.previews.font_stored(&selected_fam);
    let dark = app.session.view.dark_mode;
    let paper = app.session.doc.settings.page_color.unwrap_or(wordcraft_doc::Rgb(255, 255, 255));
    let mut render_options = crate::canvas::screen_render_options();
    render_options.dark = dark;
    render_options.dark_paper = wordcraft_render::DARK_PAPER;
    let display_paper = render_options.paper_of(&app.session.doc);
    let props = wordcraft_doc::props::CharProps {
        font: Some(stored_fam.clone()),
        font_ea: Some(stored_fam.clone()),
        size: Some(pt),
        bold: Some(bold),
        italic: Some(italic),
        ..Default::default()
    };
    let (w, h) = (580.0, 150.0);
    let ppp = ui.ctx().pixels_per_point();
    let key = format!("fontmgr_prev:{sample_text}:{stored_fam}:{pt}:{bold}:{italic}:{paper:?}:{dark}:{ppp}");
    let tex = app
        .previews
        .get_or(ui.ctx(), &key, || crate::previews::font_sample(&sample_text, &props, None, (w, h, ppp), paper, dark));
    let (rect, _) = ui.allocate_exact_size(vec2(w + 4.0, h + 4.0), egui::Sense::hover());
    let t = Tokens::get(ui.ctx());
    ui.painter().rect(
        rect,
        6.0,
        crate::theme::c32(display_paper),
        egui::Stroke::new(1.0, t.border),
        egui::StrokeKind::Inside,
    );
    if let Some(tex) = tex {
        let full = egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0));
        ui.painter().image(
            tex.id(),
            egui::Rect::from_min_size(rect.min + vec2(2.0, 2.0), (tex.size_vec2() / ppp).min(vec2(w, h))),
            full,
            egui::Color32::WHITE,
        );
    }
}

fn fonts_manage_subpage(app: &mut WordApp, ui: &mut Ui) {
    let db = wordcraft_fonts::FontDb::global();
    let confirm_id = egui::Id::unique("options_fonts_confirm_delete");
    let mut pending_delete = ui.data(|d| d.get_temp::<Option<String>>(confirm_id)).flatten();

    section(ui, "Font Actions (字体操作)");
    ui.horizontal(|ui| {
        if ui.button(tl!("Import Font File… (导入字体 TTF/OTF/TTC/WOFF/WOFF2)")).clicked() {
            let _ = app.run("font.add", json!({}));
        }
        if ui.button(tl!("Refresh Font List (刷新字体列表)")).clicked() {
            if let Some(dir) = db.user_font_dir() {
                let _ = db.load_user_fonts(&dir);
            }
            #[cfg(not(target_arch = "wasm32"))]
            {
                let _ = db.load_system_fonts();
            }
            app.previews.fonts_changed();
            app.session.relayout();
            app.status(tl!("Font list refreshed."));
        }
    });

    if let Some(dir) = db.user_font_dir() {
        let mb = db.loaded_font_bytes() as f64 / (1024.0 * 1024.0);
        note(
            ui,
            &format!(
                "Sandbox User Font Directory: {} (Loaded font heap: {:.1} MB; single file limit: 50 MB)",
                dir.display(),
                mb
            ),
        );
    }

    ui.add_space(6.0);
    section(ui, "User Imported Fonts (用户导入字体管理)");
    let user_fonts = db.user_fonts();
    if user_fonts.is_empty() {
        note(
            ui,
            "No user-imported fonts yet. Click \"Import Font File…\" above to import .ttf, .otf, .ttc, .otc, .woff or .woff2 fonts from the iPad Files app or iCloud Drive.",
        );
    } else {
        egui::ScrollArea::vertical()
            .id_salt("options_user_fonts_scroll")
            .max_height(150.0)
            .show(ui, |ui| {
                for uf in &user_fonts {
                    let families = uf.families();
                    let primary_family = families.first().cloned().unwrap_or_else(|| uf.file.clone());
                    let styles: Vec<&str> = uf.faces.iter().map(|(_, s)| s.as_str()).collect();
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(families.join(", ")).strong());
                        ui.label(RichText::new(format!("[{}] ({})", styles.join(", "), uf.file)).small().weak());
                        if pending_delete.as_deref() == Some(primary_family.as_str()) {
                            ui.label(RichText::new(tl!("Confirm delete? (确认删除？)")).small());
                            if ui.small_button(tl!("Confirm (确认删除)")).clicked() {
                                let _ = app.run("font.remove", json!({"family": primary_family}));
                                pending_delete = None;
                            }
                            if ui.small_button(tl!("Cancel (取消)")).clicked() {
                                pending_delete = None;
                            }
                        } else if ui.small_button(tl!("Delete (删除)")).clicked() {
                            pending_delete = Some(primary_family.clone());
                        }
                    });
                }
            });
    }
    ui.data_mut(|d| d.insert_temp(confirm_id, pending_delete));
    note(ui, "Built-in open-source fonts are protected and cannot be deleted by user operations.");

    ui.add_space(8.0);
    section(ui, "Font Sources & Licensing Notice (字体来源与开源授权说明)");
    egui::ScrollArea::vertical()
        .id_salt("options_font_licenses_scroll")
        .max_height(130.0)
        .show(ui, |ui| {
            ui.label(
                RichText::new(
                    "1. 合规声明（用户自定义导入字体）：用户通过“导入字体”功能安装的字体仅保存在本机沙盒目录供个人使用，WordCraft 不会重新分发任何用户导入的字体。请确保您对所导入的字体拥有合法使用权限。\n                     2. 内置中/日韩字体（SIL Open Font License 1.1）：\n                     • Source Han Sans SC / Noto Sans CJK SC & JP（思源黑体，替代微软雅黑/等线/黑体/Yu Gothic/Meiryo）— Copyright Adobe & Google Corp.\n                     • Source Han Serif SC / Noto Serif CJK SC & JP（思源宋体，替代宋体/仿宋/楷体/MS Mincho）— Copyright Adobe & Google Corp.\n                     3. 内置西文度量兼容字体（SIL Open Font License 1.1 / Apache 2.0）：\n                     • Carlito（替代 Calibri）、Caladea（替代 Cambria）、Liberation Sans / Arimo（替代 Arial）、Liberation Serif / Tinos（替代 Times New Roman）、Liberation Mono / Cousine（替代 Courier New）\n                     • Source Sans 3、Source Serif 4、Inter、JetBrains Mono（随应用附带完整 OFL-1.1 许可证文本）。",
                )
                .small(),
            );
        });
}

/// Draws Accessibility options: the animation setting and Read Aloud speed and skip-citations.
fn accessibility(app: &mut WordApp, ui: &mut Ui) {
    use wordcraft_engine::speech::{MAX_RATE, MIN_RATE};
    section(ui, "Visual effects");
    animations_picker(app, ui);
    ui.add_space(8.0);
    section(ui, "Read Aloud");
    let mut rate = app.session.read_aloud.rate();
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Speed"));
        let r =
            ui.add(egui::Slider::new(&mut rate, MIN_RATE..=MAX_RATE).step_by(0.05).custom_formatter(|v, _| format!("{v:.2}×"))).labelled_by(label.id);
        if r.changed() {
            let _ = app.run("readAloud.speed", json!({"value": rate}));
        }
    });
    let mut skip = app.session.read_aloud.skip_citations;
    if ui.checkbox(&mut skip, tl!("Skip citations & bibliography")).changed() {
        let _ = app.run("readAloud.skipCitations", json!({"value": skip}));
    }
}

/// Draws Advanced options: typing and overtype behavior, alignment guides, recent-document count,
/// measurement units, region, keytips, caret animation, file locations and customization.
fn advanced(app: &mut WordApp, ui: &mut Ui) {
    section(ui, "Editing");
    let pr = app.session.prefs.clone();
    flag(app, ui, "Typing replaces selected text", "typingReplacesSelection", pr.typing_replaces_selection);
    flag(app, ui, "Use the Insert key to switch overtype on and off", "insertKeyOvertype", pr.insert_key_overtype);
    flag(app, ui, "Overtype (typing replaces the characters after the caret)", "overtype", pr.overtype);
    let mut guides = app.ui.alignment_guides;
    if ui
        .checkbox(&mut guides, tl!("Show alignment guides when moving pictures and shapes"))
        .on_hover_text(tl!("Moved objects snap to the page's edges and centre, the margins and other objects. Hold Alt to move freely."))
        .changed()
    {
        let _ = app.run("ui.alignmentGuides", json!({"value": guides}));
    }
    ui.add_space(8.0);
    section(ui, "Display");
    crate::rtl::Table::new("options_display").columns(2).spacing(vec2(8.0, 6.0)).show(ui, |t| {
        t.row(|r| {
            let recent_label = r.cell(|ui| ui.label(tl!("Recent documents to show:")));
            r.cell(|ui| {
                let mut n = app.ui.recent_shown();
                if ui.add(egui::DragValue::new(&mut n).range(0..=crate::MAX_RECENT).speed(0.2)).labelled_by(recent_label.id).changed() {
                    app.ui.recent_count = n;
                }
            });
        });
        t.row(|r| {
            let units_label = r.cell(|ui| ui.label(tl!("Measurement units:")));
            r.cell(|ui| {
                // The user's choice, else the region's (#838): Automatic follows the region.
                let units = app.session.units();
                let auto = app.session.prefs.units.is_none();
                let name = UNITS.iter().find(|(u, _)| *u == units).map_or("Inches", |(_, n)| n);
                let shown = if auto { format!("{} ({})", tl!("Automatic"), tl!(name)) } else { tl!(name).to_string() };
                let combo = craft_ui::ComboBox::from_id_salt("options_units").selected_text(shown).width(200.0).show_ui(ui, |ui| {
                    if ui.selectable_label(auto, tl!("Automatic")).clicked() {
                        set(app, json!({"units": "auto"}));
                    }
                    for (u, label) in UNITS {
                        if ui.selectable_label(!auto && units == u, tl!(label)).clicked() {
                            set(app, json!({"units": u}));
                        }
                    }
                });
                combo.response.labelled_by(units_label.id);
            });
        });
        // The region new documents, units and the decimal separator follow; Automatic is the
        // system's (#838).
        t.row(|r| {
            let region_label = r.cell(|ui| ui.label(tl!("Region:")));
            r.cell(|ui| {
                let chosen = app.session.prefs.region.clone();
                let system = &app.session.system_region;
                let system_tag =
                    if system.territory.is_empty() { system.language.clone() } else { format!("{}-{}", system.language, system.territory) };
                let automatic = crate::i18n::fmt(tl!("Automatic ({region})"), &[("region", system_tag.as_str())]);
                let shown = chosen.clone().unwrap_or_else(|| automatic.clone());
                let combo = craft_ui::ComboBox::from_id_salt("options_region").selected_text(shown).width(200.0).show_ui(ui, |ui| {
                    if ui.selectable_label(chosen.is_none(), automatic.as_str()).clicked() {
                        set(app, json!({"region": "auto"}));
                    }
                    for tag in REGIONS {
                        if ui.selectable_label(chosen.as_deref() == Some(tag), tag).clicked() {
                            set(app, json!({"region": tag}));
                        }
                    }
                });
                combo.response.labelled_by(region_label.id);
            });
        });
    });
    let mut keytips = app.ui.keytips_enabled;
    if ui.checkbox(&mut keytips, tl!("Show KeyTips (Alt or F10)")).changed() {
        let _ = app.run("ui.keytips", json!({"value": keytips}));
    }
    ui.add_space(8.0);
    section(ui, "Animation");
    let mut caret = app.ui.caret_animation;
    if ui
        .checkbox(&mut caret, tl!("Animate the caret (it glides and fades)"))
        .on_hover_text(tl!(
            "On: the caret glides to its new place when you type or use the arrow keys, and its blink fades. Off: it jumps and blinks on and off."
        ))
        .changed()
    {
        let _ = app.run("ui.caretAnimation", json!({"value": caret}));
    }
    if cfg!(all(unix, not(target_os = "macos"))) {
        ui.add_space(8.0);
        section(ui, "Linux display server");
        display_server_picker(app, ui);
    }
    // The web app has no folders to name.
    if !cfg!(target_arch = "wasm32") {
        ui.add_space(8.0);
        section(ui, "File locations");
        templates_folder(app, ui);
    }
    ui.add_space(8.0);
    section(ui, "Scrolling");
    scroll_speed_picker(app, ui);
    ui.add_space(8.0);
    section(ui, "Customize");
    ui.horizontal(|ui| {
        ui.label(tl!("Keyboard shortcuts:"));
        if ui.button(tl!("Customize…")).clicked() {
            let _ = app.run("tools.customizeKeyboard", json!({}));
        }
    });
    ui.horizontal(|ui| {
        ui.label(tl!("Ribbon and Quick Access Toolbar:"));
        if ui.button(tl!("Customize…")).clicked() {
            let _ = app.run("tools.customizeRibbon", json!({}));
        }
    });
}

/// The user templates folder (#2852): where File › New finds personal templates and Save as Word
/// Template starts. Empty is the app's own folder, shown as the hint.
fn templates_folder(app: &mut WordApp, ui: &mut Ui) {
    let saved = app.session.prefs.user_templates_folder.clone().unwrap_or_default();
    let id = egui::Id::unique("options_user_templates_folder");
    let mut folder = ui.data(|d| d.get_temp::<String>(id)).unwrap_or_else(|| saved.clone());
    let default = app.services.templates_dir.as_ref().map(|d| d.to_string_lossy().into_owned());
    let templates_label = ui.label(tl!("User templates:")).id;
    ui.horizontal(|ui| {
        let hint = default.clone().unwrap_or_else(|| tl!("Not set").to_string());
        let r = ui.add(egui::TextEdit::singleline(&mut folder).desired_width(320.0).hint_text(hint)).labelled_by(templates_label);
        let enter = r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        let changed = folder.trim() != saved;
        if ui.add_enabled(changed, egui::Button::new(tl!("Apply"))).clicked() || (enter && changed) {
            let value = if folder.trim().is_empty() { "auto" } else { folder.trim() };
            match app.run("file.options", json!({"userTemplatesFolder": value})) {
                Ok(_) => folder = app.session.prefs.user_templates_folder.clone().unwrap_or_default(),
                Err(e) => app.status(e),
            }
        }
        if ui.add_enabled(!saved.is_empty(), egui::Button::new(tl!("Clear"))).clicked()
            && app.run("file.options", json!({"userTemplatesFolder": "auto"})).is_ok()
        {
            folder.clear();
        }
    });
    ui.data_mut(|d| d.insert_temp(id, folder));
    note(ui, "File › New lists the .dotx and .dotm templates here under Personal; Save as Word Template starts here.");
}

fn agents(ui: &mut Ui) {
    section(ui, "Agents");
    ui.label(tl!("Every command is available to scripts and AI agents: run `wordcraft-cli mcp` for an MCP server, or start the app with `--control <port>` for the JSON control channel."));
}

/// Interface theme: Light, Dark, or follow the system's appearance (#115).
fn theme_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::theme::Appearance;
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Interface theme:"));
        let combo = craft_ui::ComboBox::from_id_salt("interface_theme").selected_text(tl!(app.ui.theme.label())).width(220.0).show_ui(ui, |ui| {
            for a in Appearance::ALL {
                if ui.selectable_label(app.ui.theme == a, tl!(a.label())).clicked() {
                    let _ = app.run("ui.theme", json!({"value": a.code()}));
                }
            }
        });
        combo.response.labelled_by(label.id);
    });
}

/// What the status bar's live count shows (#2797): words (as Word's status bar counts), characters
/// with spaces, or characters without spaces. Right-clicking the count in the status bar offers
/// the same choices.
fn status_count_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::StatusCount;
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Status bar count:"));
        let combo = craft_ui::ComboBox::from_id_salt("status_count").selected_text(tl!(app.ui.status_count.label())).width(220.0).show_ui(ui, |ui| {
            for c in StatusCount::ALL {
                if ui.selectable_label(app.ui.status_count == c, tl!(c.label())).clicked() {
                    let _ = app.run("ui.statusCount", json!({"value": c.code()}));
                }
            }
        });
        combo.response.labelled_by(label.id);
    });
    note(ui, "You can also right-click the count in the status bar to change it.");
}

/// Interface size (#475, #822): Auto, which keeps the system's display scale and shows the size it
/// draws at, or an absolute size, so "100%" means one screen pixel per point.
fn interface_size_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::theme::InterfaceSize;
    let size = app.ui.interface_size;
    let native = ui.ctx().native_pixels_per_point().unwrap_or(1.0);
    // The template keeps the percent sign outside its placeholder, so `fmt` isolates the number
    // without it and a right-to-left line draws "(%200)": the sign goes inside the isolate.
    let drawn = InterfaceSize::AUTO.drawn_percent_within(native, app.auto_scale_limit);
    let auto = crate::i18n::fmt(tl!("Auto ({percent}%)"), &[("percent", &drawn.to_string())]).replace("\u{2069}%", "%\u{2069}");
    let selected = size.percent().map_or_else(|| auto.clone(), |pct| format!("{pct}%"));
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Interface size:"));
        let combo = craft_ui::ComboBox::from_id_salt("interface_size").selected_text(selected).width(220.0).show_ui(ui, |ui| {
            if ui.selectable_label(size.is_auto(), auto).clicked() {
                let _ = app.run("ui.interfaceSize", json!({"value": "auto"}));
            }
            for pct in InterfaceSize::PRESETS {
                if ui.selectable_label(size.percent() == Some(pct), format!("{pct}%")).clicked() {
                    let _ = app.run("ui.interfaceSize", json!({"percent": pct}));
                }
            }
        });
        combo.response.labelled_by(label.id);
    });
    ui.label(
        RichText::new(tl!(
            "Makes the ribbon, menus and dialogs larger or smaller. Auto follows your system's display scaling; 100% is one screen pixel per point. Document zoom is separate."
        ))
        .small()
        .weak(),
    );
}

/// Animation effects: on, off, or follow the system's setting (the default). Under "Use system
/// setting" a line says what the system reports, so it is plain what the choice comes to here.
fn animations_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::theme::Animations;
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Animation effects:"));
        let combo =
            craft_ui::ComboBox::from_id_salt("animation_effects").selected_text(tl!(app.ui.animations.label())).width(220.0).show_ui(ui, |ui| {
                for a in Animations::ALL {
                    if ui.selectable_label(app.ui.animations == a, tl!(a.label())).clicked() {
                        let _ = app.run("ui.animations", json!({"value": a.code()}));
                    }
                }
            });
        combo.response.labelled_by(label.id);
    });
    note(ui, "Smooth scrolling and zooming, and menus and buttons that fade in. Off shows every change at once.");
    if app.ui.animations == Animations::System {
        let reported = match app.system_animations() {
            Some(true) => "Your system has animation effects turned on.",
            Some(false) => "Your system has animation effects turned off.",
            None => "Your system doesn't report an animation setting, so animation effects stay on.",
        };
        note(ui, reported);
    }
}

/// Linux display server (#2184): Automatic, Wayland or X11 (XWayland). The desktop app reads it
/// before the window opens, so a change applies at the next launch.
fn display_server_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::DisplayServer;
    let name = |d: DisplayServer| if d == DisplayServer::Auto { tl!(d.label()) } else { d.label() };
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Display server:"));
        let combo = craft_ui::ComboBox::from_id_salt("display_server").selected_text(name(app.ui.display_server)).width(220.0).show_ui(ui, |ui| {
            for d in DisplayServer::ALL {
                if ui.selectable_label(app.ui.display_server == d, name(d)).clicked() {
                    let _ = app.run("ui.displayServer", json!({"value": d.code()}));
                }
            }
        });
        combo.response.labelled_by(label.id);
    });
    note(ui, "Applies the next time WordCraft starts.");
}

/// Scroll speed preferences (#6146): mouse wheel and touchpad (Wayland / macOS).
fn scroll_speed_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::scroll::ScrollSpeed;
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Mouse wheel scroll speed:"));
        let combo = craft_ui::ComboBox::from_id_salt("scroll_speed").selected_text(tl!(app.ui.scroll_speed.label())).width(220.0).show_ui(ui, |ui| {
            for s in ScrollSpeed::ALL {
                if ui.selectable_label(app.ui.scroll_speed == s, tl!(s.label())).clicked() {
                    let _ = app.run("ui.scrollSpeed", json!({"value": s.code()}));
                }
            }
        });
        combo.response.labelled_by(label.id);
    });
    // Windows and browsers do not report touchpads in points.
    if !cfg!(any(target_os = "windows", target_arch = "wasm32")) {
        let row = ui.horizontal(|ui| {
            let label = ui.label(tl!("Touchpad scroll speed:"));
            let combo = craft_ui::ComboBox::from_id_salt("touchpad_scroll_speed")
                .selected_text(tl!(app.ui.touchpad_scroll_speed.label()))
                .width(220.0)
                .show_ui(ui, |ui| {
                    for s in ScrollSpeed::ALL {
                        if ui.selectable_label(app.ui.touchpad_scroll_speed == s, tl!(s.label())).clicked() {
                            let _ = app.run("ui.touchpadScrollSpeed", json!({"value": s.code()}));
                        }
                    }
                });
            combo.response.labelled_by(label.id);
        });
        if !cfg!(target_os = "macos") {
            row.response.on_hover_text(tl!("On X11, the touchpad follows the mouse wheel speed."));
        }
    }
}

/// Interface language: follow the system (the default) or pick one (#8).
fn language_picker(app: &mut WordApp, ui: &mut Ui) {
    use crate::i18n::{AUTO, Lang};
    // The language names are in their own scripts: fonts for them load from the next frame.
    app.want_system_cjk = true;
    app.want_system_arabic = true;
    let system = crate::i18n::system_lang();
    let auto_label = crate::i18n::fmt(tl!("Automatic ({language})"), &[("language", system.name())]);
    let current = if app.ui.language == AUTO { auto_label.clone() } else { Lang::from_pref(&app.ui.language).name().to_string() };
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Interface language:"));
        let combo = craft_ui::ComboBox::from_id_salt("interface_language").selected_text(current).width(220.0).show_ui(ui, |ui| {
            if ui.selectable_label(app.ui.language == AUTO, auto_label.as_str()).clicked() {
                let _ = app.run("ui.language", json!({"value": AUTO}));
            }
            for lang in Lang::for_picker() {
                if ui.selectable_label(app.ui.language == lang.code(), lang.name()).clicked() {
                    let _ = app.run("ui.language", json!({"value": lang.code()}));
                }
            }
        });
        combo.response.labelled_by(label.id);
    });
    ui.label(RichText::new(tl!("Automatic follows your system's language. Menus and commands change; your documents don't.")).small().weak());
}

/// Deserialize `input` over `T`'s defaults one setting at a time: a value of the wrong type is
/// dropped (its default stays) instead of failing the whole read. Objects nest (`editing`).
pub fn lenient<T: Serialize + DeserializeOwned + Default>(input: &Value) -> T {
    let mut base = serde_json::to_value(T::default()).unwrap_or(Value::Null);
    if base.is_object() {
        let mut extra = Vec::new();
        overlay::<T>(&mut base, &mut Vec::new(), input, 0, &mut extra);
        // Keys with no slot in the defaults (write-only legacy settings, or unknown ones) are
        // kept only after the loop, so `base` stays the size of `T` while each key is checked.
        for (path, k, v) in extra {
            if let Some(parent) = object_at(&mut base, &path) {
                parent.insert(k, v);
            }
        }
    }
    serde_json::from_value(base).unwrap_or_default()
}

/// The object at `path` inside `root`.
fn object_at<'a>(root: &'a mut Value, path: &[String]) -> Option<&'a mut Map<String, Value>> {
    let mut v = root;
    for k in path {
        v = v.as_object_mut()?.get_mut(k)?;
    }
    v.as_object_mut()
}

fn overlay<T: DeserializeOwned>(
    root: &mut Value,
    path: &mut Vec<String>,
    input: &Value,
    depth: usize,
    extra: &mut Vec<(Vec<String>, String, Value)>,
) {
    let Some(map) = input.as_object() else { return };
    for (k, v) in map {
        let Some(parent) = object_at(root, path) else { return };
        let old = parent.get(k).cloned();
        if depth < 4 && v.is_object() && old.as_ref().is_some_and(Value::is_object) {
            path.push(k.clone());
            overlay::<T>(root, path, v, depth + 1, extra);
            path.pop();
            continue;
        }
        parent.insert(k.clone(), v.clone());
        if old.is_none() {
            let ok = serde_json::from_value::<T>(root.clone()).is_ok();
            if let Some(parent) = object_at(root, path) {
                parent.remove(k);
            }
            if ok {
                extra.push((path.clone(), k.clone(), v.clone()));
            }
            continue;
        }
        if serde_json::from_value::<T>(root.clone()).is_err()
            && let Some(parent) = object_at(root, path)
        {
            match old {
                Some(o) => parent.insert(k.clone(), o),
                None => parent.remove(k),
            };
        }
    }
}

/// File ▸ Options ▸ General: make WordCraft the default app for Word documents (#295). Only where
/// the host can (`Services::make_default_app`: Windows opens Default apps, Linux and BSD use
/// `xdg-mime`); macOS shows how to do it in Finder, the web shows nothing.
fn default_app_button(app: &mut WordApp, ui: &mut Ui) {
    if app.services.make_default_app.is_some() {
        let hint = if cfg!(target_os = "windows") {
            tl!("Opens Settings › Default apps, where you choose WordCraft for .docx and the other document types.")
        } else {
            tl!("Opens .docx, .doc, .rtf and .odt files and Word templates with WordCraft from now on.")
        };
        if ui.button(tl!("Make WordCraft the default for Word documents…")).on_hover_text(hint).clicked() {
            // Straight to the hook, not through `run`: only a click may change system defaults.
            let _ = app.make_default_app();
        }
    } else if cfg!(target_os = "macos") {
        ui.label(
            egui::RichText::new(tl!("To open Word documents with WordCraft by default: select one in Finder, choose File › Get Info, pick WordCraft under Open with, then click Change All."))
                .small()
                .weak(),
        );
    }
}

/// File ▸ Options ▸ Numerals: how digits look on screen (display only, like Word's
/// File › Options › Advanced › Numeral).
fn numeral_picker(app: &mut WordApp, ui: &mut Ui) {
    use wordcraft_layout::NumeralMode;
    ui.horizontal(|ui| {
        let label = ui.label(tl!("Numerals:"));
        let mut sel = app.session.view.numeral;
        let combo = craft_ui::ComboBox::from_id_salt("numerals").selected_text(tl!(sel.label())).width(220.0).show_ui(ui, |ui| {
            for m in [NumeralMode::Arabic, NumeralMode::Hindi, NumeralMode::Context, NumeralMode::System] {
                ui.selectable_value(&mut sel, m, tl!(m.label()));
            }
        });
        combo.response.labelled_by(label.id);
        if sel != app.session.view.numeral {
            let _ = app.run("view.numeral", json!({ "value": sel }));
        }
    });
}

#[cfg(test)]
mod tests;
