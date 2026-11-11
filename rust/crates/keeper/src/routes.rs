//! The agents that have an ACP route. `routes.json` is the table the app sends
//! to the python keeper (`agentRoutes` in `app/lib/data/acp/agent_host.dart`);
//! a Dart test keeps the two equal.

use serde::Deserialize;

/// One agent the keeper can start.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Route {
    /// Stable, lower case: `omp`, `claude`, `codex`, `pi`.
    pub id: String,
    /// What the person reads: `Claude Code`.
    pub label: String,
    pub binary: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Run through `npx -y` when the binary is not installed.
    #[serde(default)]
    pub npx: Option<String>,
    /// Capabilities declared to the agent (`clientCapabilities._meta.jetbrains.air`).
    #[serde(default)]
    pub air: Vec<String>,
}

const TABLE: &str = include_str!("../routes.json");

/// The routes, in the order the start form lists them.
///
/// # Panics
/// Never at run time: `routes.json` is checked by a test.
#[must_use]
pub fn all() -> Vec<Route> {
    serde_json::from_str(TABLE).expect("routes.json is valid, checked by a test")
}

/// The route with this id.
#[must_use]
pub fn by_id(id: &str) -> Option<Route> {
    all().into_iter().find(|r| r.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_parses_and_ids_are_unique_lower_case() {
        let routes = all();
        let mut ids: Vec<&str> = routes.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids.first(), Some(&"omp"), "the form lists omp first");
        for id in &ids {
            assert_eq!(*id, id.to_lowercase());
        }
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), routes.len(), "ids are unique");
    }

    #[test]
    fn omp_runs_acp_and_an_agent_with_a_package_can_fall_back_to_npx() {
        assert_eq!(by_id("omp").map(|r| r.args), Some(vec!["acp".to_string()]));
        assert!(by_id("claude").and_then(|r| r.npx).is_some());
        // An agent only its own installer provides has no package to run.
        assert_eq!(by_id("cursor").and_then(|r| r.npx), None);
        assert_eq!(by_id("nope"), None);
    }
}
