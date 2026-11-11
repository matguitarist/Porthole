//! The server's load from /proc, like the Mac app's HostLoad: CPU from the
//! change in /proc/stat between two readings, memory from /proc/meminfo.
//! In the container, the host's /proc is mounted at /host/proc.

use serde::Serialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Default, Serialize)]
pub struct Load {
    /// Percent of all cores, newest last, one reading every two seconds.
    pub cpu: Vec<f64>,
    /// Bytes in use (not counting caches), newest last.
    pub memory_used: Vec<f64>,
    pub memory_total: f64,
    /// 1, 5 and 15 minute averages.
    pub load: Vec<f64>,
    pub uptime: f64,
}

pub struct Sampler {
    root: PathBuf,
    last: Option<(f64, f64)>,
    capacity: usize,
    pub load: Load,
}

impl Sampler {
    pub fn new(root: PathBuf) -> Self {
        Sampler {
            root,
            last: None,
            capacity: 90,
            load: Load::default(),
        }
    }

    fn read(&self, name: &str) -> String {
        std::fs::read_to_string(self.root.join(name)).unwrap_or_default()
    }

    pub fn sample(&mut self) {
        if let Some((busy, total)) = cpu_ticks(&self.read("stat")) {
            if let Some((last_busy, last_total)) = self.last
                && total > last_total
            {
                push(
                    &mut self.load.cpu,
                    (busy - last_busy) / (total - last_total) * 100.0,
                    self.capacity,
                );
            }
            self.last = Some((busy, total));
        }
        if let Some((total, used)) = memory(&self.read("meminfo")) {
            self.load.memory_total = total;
            push(&mut self.load.memory_used, used, self.capacity);
        }
        self.load.load = self
            .read("loadavg")
            .split_whitespace()
            .take(3)
            .filter_map(|v| v.parse().ok())
            .collect();
        self.load.uptime = self
            .read("uptime")
            .split_whitespace()
            .next()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.0);
    }
}

fn push(values: &mut Vec<f64>, value: f64, capacity: usize) {
    values.push(value);
    if values.len() > capacity {
        values.remove(0);
    }
}

/// (busy, total) ticks from the "cpu " line of /proc/stat.
pub fn cpu_ticks(stat: &str) -> Option<(f64, f64)> {
    let line = stat.lines().find(|l| l.starts_with("cpu "))?;
    let values: Vec<f64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|v| v.parse().ok())
        .collect();
    if values.len() < 4 {
        return None;
    }
    let total: f64 = values.iter().sum();
    let idle = values[3] + values.get(4).copied().unwrap_or(0.0);
    Some((total - idle, total))
}

/// (total, used) bytes from /proc/meminfo: used = MemTotal - MemAvailable.
pub fn memory(meminfo: &str) -> Option<(f64, f64)> {
    let field = |name: &str| -> Option<f64> {
        meminfo
            .lines()
            .find(|l| l.starts_with(name))?
            .split_whitespace()
            .nth(1)?
            .parse::<f64>()
            .ok()
            .map(|kb| kb * 1024.0)
    };
    let total = field("MemTotal:")?;
    Some((total, total - field("MemAvailable:")?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_cpu_and_memory() {
        assert_eq!(
            cpu_ticks("cpu  100 0 100 700 100 0 0 0\ncpu0 1 2 3 4"),
            Some((200.0, 1000.0))
        );
        let meminfo = "MemTotal:       32768000 kB\nMemFree:  1 kB\nMemAvailable:   12768000 kB\n";
        assert_eq!(
            memory(meminfo),
            Some((32768000.0 * 1024.0, 20000000.0 * 1024.0))
        );
    }

    #[test]
    fn cpu_percent_comes_from_two_readings() {
        let dir = std::env::temp_dir().join(format!("porthole-host-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("stat"), "cpu  100 0 0 900 0 0 0 0\n").unwrap();
        let mut sampler = Sampler::new(dir.clone());
        sampler.sample();
        assert!(sampler.load.cpu.is_empty());
        std::fs::write(dir.join("stat"), "cpu  150 0 0 950 0 0 0 0\n").unwrap();
        std::fs::write(dir.join("loadavg"), "1.12 0.98 0.87 2/812 1234\n").unwrap();
        sampler.sample();
        assert_eq!(sampler.load.cpu, vec![50.0]);
        assert_eq!(sampler.load.load, vec![1.12, 0.98, 0.87]);
        std::fs::remove_dir_all(dir).ok();
    }
}
