//! Progress messages of the privileged tool in the GUI languages.

use std::sync::OnceLock;

static LANG: OnceLock<String> = OnceLock::new();

/// Select the language once, at start-up (en, id, pt or tet).
pub fn set_lang(lang: &str) {
    let lang = if ["en", "id", "pt", "tet"].contains(&lang) { lang } else { "en" };
    let _ = LANG.set(lang.to_string());
}

pub fn lang() -> &'static str {
    LANG.get().map(String::as_str).unwrap_or("en")
}

// English text, then Indonesian, Portuguese and Tetum.
const MESSAGES: &[[&str; 4]] = &[
    ["Checking repository configuration...", "Memeriksa konfigurasi repositori...",
     "Verificando a configuracao dos repositorios...", "Verifika konfigurasaun repositoriu..."],
    ["Refreshing package lists to detect key problems...", "Memperbarui daftar paket untuk mendeteksi masalah kunci...",
     "Atualizando listas de pacotes para detetar problemas de chaves...", "Atualiza lista pakote atu deteta problema xave..."],
    ["Downloading missing signing key {}...", "Mengunduh kunci penandatangan {} yang hilang...",
     "Transferindo a chave de assinatura {} em falta...", "Download xave asinatura {} nebe lakon..."],
    ["Moving keys out of the legacy trusted.gpg keyring...", "Memindahkan kunci dari keyring lama trusted.gpg...",
     "Movendo chaves do keyring antigo trusted.gpg...", "Muda xave sira husi keyring tuan trusted.gpg..."],
    ["Repairing keyring formats and permissions...", "Memperbaiki format dan izin keyring...",
     "Reparando formatos e permissoes dos keyrings...", "Hadi'a formatu no permisaun keyring..."],
    ["Reinstalling distribution archive keyrings...", "Memasang ulang keyring arsip distribusi...",
     "Reinstalando os keyrings do arquivo da distribuicao...", "Instala fali keyring arkivu distribuisaun..."],
    ["Verifying repositories...", "Memverifikasi repositori...", "Verificando os repositorios...",
     "Verifika repositoriu sira..."],
    ["Disabling duplicate repository entries...", "Menonaktifkan entri repositori duplikat...",
     "Desativando entradas de repositorio duplicadas...", "Dezativa repositoriu duplikadu..."],
    ["Installing the signing key...", "Memasang kunci penandatangan...", "Instalando a chave de assinatura...",
     "Instala xave asinatura..."],
    ["Adding the repository...", "Menambahkan repositori...", "Adicionando o repositorio...", "Aumenta repositoriu..."],
    ["Complete.", "Selesai.", "Concluido.", "Remata."],
];

/// Translate a progress message written in English; unknown text is kept.
pub fn translate(text: &str) -> String {
    let column = match lang() {
        "id" => 1,
        "pt" => 2,
        "tet" => 3,
        _ => return text.to_string(),
    };
    for row in MESSAGES {
        if let Some((head, tail)) = row[0].split_once("{}") {
            if let Some(value) = text.strip_prefix(head).and_then(|rest| rest.strip_suffix(tail)) {
                return row[column].replace("{}", value);
            }
        } else if row[0] == text {
            return row[column].to_string();
        }
    }
    text.to_string()
}
