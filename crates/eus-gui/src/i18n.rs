//! GUI texts in English, Indonesian, Portuguese and Tetum.

use serde_json::{Map, Value};
use std::sync::OnceLock;

static MESSAGES: OnceLock<Map<String, Value>> = OnceLock::new();
static LANG: OnceLock<String> = OnceLock::new();

fn messages() -> &'static Map<String, Value> {
    MESSAGES.get_or_init(|| match serde_json::from_str(include_str!("messages.json")) {
        Ok(Value::Object(map)) => map,
        _ => Map::new(),
    })
}

/// Language from the locale environment: tet, pt, id or en.
pub fn language_code() -> &'static str {
    LANG.get_or_init(|| {
        let raw = ["LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"]
            .iter()
            .filter_map(|name| std::env::var(name).ok())
            .find(|value| !value.is_empty())
            .unwrap_or_else(|| "en".into());
        let raw = raw.split(':').next().unwrap_or("").to_lowercase();
        if raw.starts_with("tet") {
            "tet"
        } else if raw.starts_with("pt") {
            "pt"
        } else if raw.starts_with("id") || raw.starts_with("in") {
            "id"
        } else {
            "en"
        }
        .to_string()
    })
}

/// The text for `key`, falling back to English and then to the key itself.
pub fn t(key: &str) -> String {
    let lookup = |lang: &str| messages().get(lang).and_then(|m| m.get(key)).and_then(Value::as_str).map(str::to_string);
    lookup(language_code()).or_else(|| lookup("en")).unwrap_or_else(|| key.to_string())
}

/// [`t`] with `{name}` placeholders filled in.
pub fn tf(key: &str, values: &[(&str, &str)]) -> String {
    let mut text = t(key);
    for (name, value) in values {
        text = text.replace(&format!("{{{name}}}"), value);
    }
    text
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_language_has_valid_placeholders() {
        let english = super::messages()["en"].as_object().unwrap();
        for (lang, table) in super::messages() {
            for (key, value) in table.as_object().unwrap() {
                assert!(english.contains_key(key), "{lang}: {key} is not in English");
                let text = value.as_str().unwrap();
                assert_eq!(text.matches('{').count(), text.matches('}').count(), "{lang}: {key}");
            }
        }
        assert_eq!(super::tf("hours", &[("hours", "6")]).contains('6'), true);
    }
}
