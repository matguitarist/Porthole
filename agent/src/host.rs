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
    /// Docker's own CPU, in percent of one core (500 is five cores busy).
    pub dockerd_cpu: Vec<f64>,
    /// Unix seconds when dockerd started.
    pub dockerd_started: Option<u64>,
    /// The average when dockerd has been busy for five minutes (see `busy`).
    pub dockerd_busy: Option<f64>,
}

/// Busy means above this, in percent of one core, on average…
pub const BUSY_THRESHOLD: f64 = 150.0;
/// …over this many readings (two seconds apart: five minutes). Like the Mac app's DockerdWatch.
pub const BUSY_WINDOW: usize = 150;

pub fn busy(cpu: &[f64]) -> Option<f64> {
    if cpu.len() < BUSY_WINDOW {
        return None;
    }
    let average = cpu[cpu.len() - BUSY_WINDOW..].iter().sum::<f64>() / BUSY_WINDOW as f64;
    (average > BUSY_THRESHOLD).then_some(average)
}

/// Clock ticks per second in /proc (USER_HZ, 100 on Linux).
const TICKS: f64 = 100.0;

/// (utime + stime, start) in ticks from /proc/<pid>/stat.
pub fn process_ticks(stat: &str) -> Option<(f64, f64)> {
    // The name is in parentheses and may hold spaces: count fields after it.
    let fields: Vec<&str> = stat.get(stat.rfind(')')? + 1..)?.split_whitespace().collect();
    let field = |n: usize| -> Option<f64> { fields.get(n - 3)?.parse().ok() };
    Some((field(14)? + field(15)?, field(22)?))
}

pub struct Sampler {
    root: PathBuf,
    last: Option<(f64, f64)>,
    dockerd: Option<u32>,
    last_dockerd: Option<(f64, f64)>,
    capacity: usize,
    pub load: Load,
}

impl Sampler {
    pub fn new(root: PathBuf) -> Self {
        Sampler {
            root,
            last: None,
            dockerd: None,
            last_dockerd: None,
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
        self.sample_dockerd();
    }

    fn find_dockerd(&self) -> Option<u32> {
        std::fs::read_dir(&self.root).ok()?.flatten().find_map(|entry| {
            let pid: u32 = entry.file_name().to_str()?.parse().ok()?;
            (self.read(&format!("{pid}/comm")).trim() == "dockerd").then_some(pid)
        })
    }

    fn sample_dockerd(&mut self) {
        let uptime = self.load.uptime;
        let mut ticks = self.dockerd.and_then(|pid| process_ticks(&self.read(&format!("{pid}/stat"))));
        if ticks.is_none() {
            // First reading, or Docker restarted with a new pid.
            self.dockerd = self.find_dockerd();
            self.last_dockerd = None;
            ticks = self.dockerd.and_then(|pid| process_ticks(&self.read(&format!("{pid}/stat"))));
        }
        let Some((ticks, start)) = ticks else { return };
        if uptime <= 0.0 {
            return;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        self.load.dockerd_started = Some((now - (uptime - start / TICKS)).max(0.0) as u64);
        if let Some((last_ticks, last_uptime)) = self.last_dockerd
            && ticks >= last_ticks
            && uptime > last_uptime
        {
            push(
                &mut self.load.dockerd_cpu,
                100.0 * (ticks - last_ticks) / TICKS / (uptime - last_uptime),
                self.capacity.max(BUSY_WINDOW),
            );
        }
        self.last_dockerd = Some((ticks, uptime));
        self.load.dockerd_busy = busy(&self.load.dockerd_cpu);
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
    fn reads_dockerd_ticks_and_busy() {
        let stat = "11766 (dockerd) S 1 11766 11766 0 -1 4194560 1 0 0 0 9469 11922 0 0 20 0 60 0 10018993 5815068";
        assert_eq!(process_ticks(stat), Some((21391.0, 10018993.0)));
        assert_eq!(busy(&[500.0; 100]), None);
        assert_eq!(busy(&[507.0; 150]), Some(507.0));
        let mut spike = vec![2.0; 140];
        spike.extend([900.0; 10]);
        assert_eq!(busy(&spike), None);
    }

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
