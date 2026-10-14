//! Eduka-Update-System core: APT sources, keyrings, releases, kernels,
//! cleaner and System Health. Shared by the tool, the GUI and the panel.

pub mod apt;
pub mod cleaner;
pub mod health;
pub mod i18n;
pub mod kernels;
pub mod keys;
pub mod release;
pub mod repos;
pub mod sources;
pub mod util;

pub use anyhow::{Error, Result};
