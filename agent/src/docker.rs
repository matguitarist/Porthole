//! The Docker socket, through bollard.

use crate::parse::{self, Level};
use bollard::query_parameters::{
    ListContainersOptions, LogsOptions, RestartContainerOptions, StartContainerOptions,
    StopContainerOptions,
};
use futures::{Stream, StreamExt};
use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone)]
pub struct Docker(bollard::Docker);

#[derive(Debug, Clone, Serialize)]
pub struct Container {
    pub id: String,
    pub name: String,
    pub image: String,
    pub state: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub health: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub web_ui: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Problems {
    pub warnings: usize,
    pub errors: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest: Option<parse::Line>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ProblemScan {
    /// Unix seconds of the scan, 0 before the first.
    pub scanned: u64,
    pub hours: u64,
    pub containers: BTreeMap<String, Problems>,
}

/// "Up 2 hours (unhealthy)" → "unhealthy".
pub fn health_from_status(status: &str) -> Option<String> {
    ["(healthy)", "(unhealthy)", "(health: starting)"]
        .iter()
        .find(|h| status.contains(*h))
        .map(|h| {
            h.trim_matches(['(', ')'])
                .trim_start_matches("health: ")
                .to_string()
        })
}

impl Docker {
    pub fn connect() -> Result<Self, String> {
        bollard::Docker::connect_with_local_defaults()
            .map(Docker)
            .map_err(|e| e.to_string())
    }

    /// (hostname, Docker version, cores).
    pub async fn server(&self) -> (String, String, i64) {
        match self.0.info().await {
            Ok(info) => (
                info.name.unwrap_or_default(),
                info.server_version.unwrap_or_default(),
                info.ncpu.unwrap_or(0),
            ),
            Err(_) => (String::new(), String::new(), 0),
        }
    }

    pub async fn containers(&self) -> Result<Vec<Container>, String> {
        let options = ListContainersOptions {
            all: true,
            ..Default::default()
        };
        let list = self
            .0
            .list_containers(Some(options))
            .await
            .map_err(|e| e.to_string())?;
        let mut containers: Vec<Container> = list
            .into_iter()
            .map(|c| {
                let labels = c.labels.unwrap_or_default();
                let status = c.status.unwrap_or_default();
                Container {
                    id: c.id.unwrap_or_default().chars().take(12).collect(),
                    name: c
                        .names
                        .unwrap_or_default()
                        .first()
                        .map(|n| n.trim_start_matches('/').to_string())
                        .unwrap_or_default(),
                    image: c.image.unwrap_or_default(),
                    state: c.state.map(|s| s.to_string()).unwrap_or_default(),
                    health: health_from_status(&status),
                    status,
                    project: labels.get("com.docker.compose.project").cloned(),
                    icon: labels
                        .get("net.unraid.docker.icon")
                        .filter(|i| i.starts_with("http"))
                        .cloned(),
                    web_ui: labels.get("net.unraid.docker.webui").cloned(),
                }
            })
            .collect();
        containers.sort_by_key(|c| c.name.to_lowercase());
        Ok(containers)
    }

    /// Raw `docker logs -t` lines: the last `tail` (or everything since `since`), then new ones.
    pub fn logs(
        &self,
        name: &str,
        tail: usize,
        since: Option<i64>,
    ) -> impl Stream<Item = String> + use<> {
        let options = LogsOptions {
            follow: true,
            stdout: true,
            stderr: true,
            timestamps: true,
            since: since.unwrap_or(0) as i32,
            tail: if since.is_some() {
                "all".into()
            } else {
                tail.to_string()
            },
            ..Default::default()
        };
        self.0
            .logs(name, Some(options))
            .filter_map(|chunk| async move { chunk.ok().map(|c| c.to_string()) })
            // A chunk can hold several lines.
            .flat_map(|text| {
                futures::stream::iter(text.lines().map(str::to_string).collect::<Vec<_>>())
            })
    }

    pub async fn perform(&self, name: &str, action: &str) -> Result<(), String> {
        let result = match action {
            "start" => {
                self.0
                    .start_container(name, None::<StartContainerOptions>)
                    .await
            }
            "stop" => {
                self.0
                    .stop_container(name, None::<StopContainerOptions>)
                    .await
            }
            "restart" => {
                self.0
                    .restart_container(name, None::<RestartContainerOptions>)
                    .await
            }
            _ => return Err(format!("Unknown action {action}.")),
        };
        result.map_err(|e| e.to_string())
    }

    /// Every container's warnings and errors of the last day.
    pub async fn scan_problems(&self) -> ProblemScan {
        const HOURS: u64 = 24;
        const MAX_LINES: usize = 20_000;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut scan = ProblemScan {
            scanned: now,
            hours: HOURS,
            containers: BTreeMap::new(),
        };
        let Ok(containers) = self.containers().await else {
            return scan;
        };
        for container in containers {
            let options = LogsOptions {
                stdout: true,
                stderr: true,
                timestamps: true,
                since: (now - HOURS * 3600) as i32,
                tail: MAX_LINES.to_string(),
                ..Default::default()
            };
            let mut problems = Problems::default();
            let mut stream = self.0.logs(&container.name, Some(options));
            while let Some(Ok(chunk)) = stream.next().await {
                for raw in chunk.to_string().lines() {
                    let line = parse::parse(raw);
                    if !line.level.is_problem() {
                        continue;
                    }
                    if line.level == Level::Warning {
                        problems.warnings += 1
                    } else {
                        problems.errors += 1
                    }
                    problems.latest = Some(line);
                }
            }
            scan.containers.insert(container.name, problems);
        }
        scan
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_comes_from_the_status() {
        assert_eq!(
            health_from_status("Up 2 hours (unhealthy)").as_deref(),
            Some("unhealthy")
        );
        assert_eq!(
            health_from_status("Up 6 hours (healthy)").as_deref(),
            Some("healthy")
        );
        assert_eq!(
            health_from_status("Up 3 seconds (health: starting)").as_deref(),
            Some("starting")
        );
        assert_eq!(health_from_status("Exited (0) 6 hours ago"), None);
    }
}
