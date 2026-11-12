//! Porthole's agent: the server's containers and logs, on a web page and an
//! HTTP API, for when you're away from the Mac. Runs on the Docker server,
//! talks to the Docker socket, and sits behind Cloudflare Access.
//!
//! Settings (environment):
//!   PORTHOLE_PORT=7080        where it listens
//!   PORTHOLE_PROC=/host/proc  the host's /proc, for the server's load
//!   PORTHOLE_ACTIONS=1        allow Start, Stop and Restart (off: read only)
//!   PORTHOLE_TOKEN=<secret>   optional: require it as a bearer token or the porthole_token cookie

mod docker;
mod host;
mod parse;

use axum::{
    Json, Router,
    extract::{Path, Query, Request, State},
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{
        Html, IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
    routing::{get, post},
};
use futures::StreamExt;
use serde::Deserialize;
use std::{collections::HashMap, convert::Infallible, sync::Arc, time::Duration};
use tokio::sync::RwLock;

#[derive(Clone)]
struct App {
    docker: docker::Docker,
    load: Arc<RwLock<host::Load>>,
    problems: Arc<RwLock<docker::ProblemScan>>,
    actions: bool,
    token: Option<String>,
}

#[tokio::main]
async fn main() {
    let env = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    let port: u16 = env("PORTHOLE_PORT")
        .and_then(|p| p.parse().ok())
        .unwrap_or(7080);
    // Docker's health check: the image has no curl, so the binary asks itself.
    if std::env::args().any(|a| a == "--health") {
        std::process::exit(if health_check(port) { 0 } else { 1 });
    }
    let proc_root = env("PORTHOLE_PROC").unwrap_or_else(|| {
        if std::path::Path::new("/host/proc/stat").exists() {
            "/host/proc".into()
        } else {
            "/proc".into()
        }
    });
    let docker = docker::Docker::connect()
        .expect("can't reach the Docker socket (mount /var/run/docker.sock)");
    let app = App {
        docker,
        load: Arc::default(),
        problems: Arc::default(),
        actions: env("PORTHOLE_ACTIONS").is_some_and(|v| v == "1" || v == "true"),
        token: env("PORTHOLE_TOKEN"),
    };

    // The server's load, every two seconds.
    let load = app.load.clone();
    tokio::spawn(async move {
        let mut sampler = host::Sampler::new(proc_root.into());
        loop {
            sampler.sample();
            *load.write().await = sampler.load.clone();
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
    // Warnings and errors of the last day, every five minutes.
    let (scan_docker, problems, scan_load) = (app.docker.clone(), app.problems.clone(), app.load.clone());
    tokio::spawn(async move {
        // The first host reading, so the scan knows when Docker started.
        tokio::time::sleep(Duration::from_secs(3)).await;
        loop {
            let started = scan_load.read().await.dockerd_started;
            let scan = scan_docker.scan_problems(started).await;
            *problems.write().await = scan;
            tokio::time::sleep(Duration::from_secs(300)).await;
        }
    });

    let api = Router::new()
        .route("/api/info", get(info))
        .route("/api/containers", get(containers))
        .route("/api/containers/{name}/logs", get(logs))
        .route("/api/containers/{name}/{action}", post(action))
        .route("/api/host", get(host_load))
        .route("/api/problems", get(problems_now))
        .layer(middleware::from_fn_with_state(app.clone(), auth));
    let router = Router::new()
        .route(
            "/",
            get(|| async { Html(include_str!("../web/index.html")) }),
        )
        .route(
            "/app.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript")],
                    include_str!("../web/app.js"),
                )
            }),
        )
        .route(
            "/style.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css")],
                    include_str!("../web/style.css"),
                )
            }),
        )
        .route("/health", get(|| async { "ok" }))
        .merge(api)
        .with_state(app);

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .expect("port in use");
    println!(
        "Porthole agent {} on port {port}",
        env!("CARGO_PKG_VERSION")
    );
    axum::serve(listener, router).await.unwrap();
}

fn health_check(port: u16) -> bool {
    use std::io::{Read, Write};
    let Ok(mut stream) = std::net::TcpStream::connect_timeout(
        &([127, 0, 0, 1], port).into(),
        Duration::from_secs(2),
    ) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let mut reply = String::new();
    stream.write_all(b"GET /health HTTP/1.0\r\n\r\n").is_ok()
        && stream.read_to_string(&mut reply).is_ok()
        && (reply.starts_with("HTTP/1.0 200") || reply.starts_with("HTTP/1.1 200"))
}

/// With PORTHOLE_TOKEN set, the API needs it.
async fn auth(
    State(app): State<App>,
    headers: HeaderMap,
    request: Request,
    next: Next,
) -> Response {
    if let Some(token) = &app.token
        && !token_matches(&headers, token)
    {
        return (StatusCode::UNAUTHORIZED, "token needed").into_response();
    }
    next.run(request).await
}

fn token_matches(headers: &HeaderMap, token: &str) -> bool {
    let bearer = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    let cookie = headers
        .get(header::COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(|cookies| {
            cookies
                .split(';')
                .map(str::trim)
                .find_map(|c| c.strip_prefix("porthole_token="))
        });
    [bearer, cookie]
        .into_iter()
        .flatten()
        .any(|given| constant_time_eq(given.as_bytes(), token.as_bytes()))
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn info(State(app): State<App>) -> impl IntoResponse {
    let (hostname, version, cores) = app.docker.server().await;
    Json(serde_json::json!({
        "agent": env!("CARGO_PKG_VERSION"), "hostname": hostname, "docker": version, "cores": cores, "actions": app.actions,
    }))
}

async fn containers(State(app): State<App>) -> Result<impl IntoResponse, (StatusCode, String)> {
    app.docker
        .containers()
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_GATEWAY, e))
}

async fn host_load(State(app): State<App>) -> impl IntoResponse {
    Json(app.load.read().await.clone())
}

async fn problems_now(State(app): State<App>) -> impl IntoResponse {
    Json(app.problems.read().await.clone())
}

#[derive(Deserialize)]
struct LogQuery {
    tail: Option<usize>,
    /// Unix seconds: everything since then instead of the last lines.
    since: Option<i64>,
}

/// The container's log as server-sent events: the last lines, then new ones as they come.
async fn logs(
    State(app): State<App>,
    Path(name): Path<String>,
    Query(query): Query<LogQuery>,
) -> impl IntoResponse {
    let stream = app
        .docker
        .logs(&name, query.tail.unwrap_or(1000).min(50_000), query.since)
        .map(|line| {
            Ok::<_, Infallible>(
                Event::default()
                    .json_data(parse::parse(&line))
                    .unwrap_or_else(|_| Event::default()),
            )
        });
    Sse::new(stream).keep_alive(KeepAlive::default())
}

async fn action(
    State(app): State<App>,
    Path((name, action)): Path<(String, String)>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    if !app.actions {
        return Err((
            StatusCode::FORBIDDEN,
            "Actions are off on this agent (PORTHOLE_ACTIONS=1 turns them on).".into(),
        ));
    }
    app.docker
        .perform(&name, &action)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(HashMap::from([("ok", true)])))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_from_bearer_or_cookie() {
        let mut headers = HeaderMap::new();
        assert!(!token_matches(&headers, "s3cret"));
        headers.insert(header::AUTHORIZATION, "Bearer s3cret".parse().unwrap());
        assert!(token_matches(&headers, "s3cret"));
        let mut headers = HeaderMap::new();
        headers.insert(
            header::COOKIE,
            "theme=dark; porthole_token=s3cret".parse().unwrap(),
        );
        assert!(token_matches(&headers, "s3cret"));
        headers.insert(header::COOKIE, "porthole_token=wrong".parse().unwrap());
        assert!(!token_matches(&headers, "s3cret"));
    }
}
