"use strict";
(() => {
    lucide.createIcons();
    const element = id => document.getElementById(id);
    const put = (id, value) => { element(id).textContent = value; };
    const bytes = value => value == null ? "Unavailable" : value >= 1073741824 ? `${(value / 1073741824).toFixed(2)} GiB` : `${(value / 1048576).toFixed(1)} MiB`;
    const duration = seconds => seconds >= 3600 ? `${(seconds / 3600).toFixed(1)} h` : `${Math.floor(seconds / 60)} min`;
    const color = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    const makeChart = (id, datasets, suffix) => new Chart(element(id), {
        type: "line", data: { labels: [], datasets: datasets.map(([label, variable]) => ({ label, data: [], borderColor: color(variable), borderWidth: 2, pointRadius: 0, tension: 0.1, spanGaps: false })) },
        options: { responsive: true, maintainAspectRatio: false, animation: false, normalized: true, plugins: { legend: { position: "bottom", labels: { boxWidth: 12, font: { family: "IBM Plex Sans" } } } }, scales: { x: { ticks: { maxTicksLimit: 5 }, grid: { display: false } }, y: { beginAtZero: true, ticks: { callback: value => `${value}${suffix}` } } } }
    });
    const memoryChart = makeChart("memory-chart", [["Web process", "--teal"], ["Workers", "--amber"], ["Container", "--muted"]], " MiB");
    const cpuChart = makeChart("cpu-chart", [["Container CPU", "--teal"]], "%");
    let paused = false;
    let pending = false;
    let timer;
    let health;
    let failures = 0;
    function render() {
        if (!health) return;
        const cutoff = Date.now() - Number(element("window").value) * 1000;
        const samples = health.samples.filter(sample => Date.parse(sample.timestamp) >= cutoff);
        const current = samples.at(-1);
        const stale = !current || Date.now() - Date.parse(current.timestamp) > health.sampleSeconds * 3000;
        put("status", paused ? "Paused" : stale ? "Awaiting sample" : "Live");
        element("status").classList.toggle("status--warning", paused || stale);
        put("uptime", duration(health.uptimeSeconds));
        put("cpu", current?.cpuPercent == null ? "Unavailable" : `${current.cpuPercent.toFixed(1)}%`);
        put("memory", bytes(current?.containerMemoryBytes));
        put("limit", `Limit ${bytes(current?.containerMemoryLimitBytes)}`);
        put("workers", current?.workerCount ?? "--");
        put("capacity", `${health.capacity} concurrent scan${health.capacity === 1 ? "" : "s"}`);
        put("sampled", current ? new Date(current.timestamp).toLocaleTimeString() : "Waiting for telemetry");
        put("runtime", health.runtime); put("platform", health.platform); put("version", health.version);
        element("modules").replaceChildren(...Object.entries(health.modules || {}).map(([name, version]) => {
            const row = document.createElement("div");
            const label = document.createElement("dt"); label.textContent = name;
            const value = document.createElement("dd"); value.textContent = version;
            row.append(label, value); return row;
        }));
        put("scan-ready", health.scanReady ? "Ready" : "Test definitions unavailable");
        put("heap", bytes(current?.managedHeapBytes)); put("committed", bytes(current?.committedHeapBytes));
        put("rss", bytes(current?.processMemoryBytes)); put("worker-memory", bytes(current?.workerMemoryBytes));
        put("completed", health.jobs.completed); put("failed", health.jobs.failed); put("active", health.jobs.active);
        put("duration", duration(health.jobs.averageDurationMs / 1000));
        put("gc", current ? `${current.gen0Collections} / ${current.gen1Collections} / ${current.gen2Collections}` : "--");
        put("threads", current?.threadCount ?? "--"); put("working-set", bytes(current?.workingSetBytes));
        put("database", bytes(current?.databaseBytes)); put("disk", bytes(current?.diskFreeBytes)); put("interval", `${health.sampleSeconds} seconds`);
        put("last-updated", current ? `Sampled ${new Date(current.timestamp).toLocaleString()}` : "No samples received");
        const labels = samples.map(sample => new Date(sample.timestamp).toLocaleTimeString());
        memoryChart.data.labels = labels;
        ["processMemoryBytes", "workerMemoryBytes", "containerMemoryBytes"].forEach((key, index) => {
            memoryChart.data.datasets[index].data = samples.map(sample => sample[key] == null ? null : sample[key] / 1048576);
        });
        cpuChart.data.labels = labels;
        cpuChart.data.datasets[0].data = samples.map(sample => sample.cpuPercent);
        memoryChart.update(); cpuChart.update();
    }
    async function refresh() {
        if (pending) return;
        pending = true;
        try {
            const response = await fetch("/health", { cache: "no-store", signal: AbortSignal.timeout(10000) });
            if (!response.ok) throw new Error("Telemetry request failed");
            health = await response.json();
            failures = 0; element("error").hidden = true; render();
        } catch {
            failures++; put("status", "Disconnected"); element("status").classList.add("status--warning");
            put("error", "Health telemetry is unavailable. Reconnecting."); element("error").hidden = false;
        } finally {
            pending = false;
            clearTimeout(timer);
            if (!paused && !document.hidden) timer = setTimeout(refresh, Math.min(60000, 5000 * 2 ** Math.min(failures, 4)));
        }
    }
    element("refresh").addEventListener("click", refresh);
    element("pause").addEventListener("click", () => {
        paused = !paused; element("pause").setAttribute("aria-pressed", String(paused));
        element("pause").title = paused ? "Resume updates" : "Pause updates";
        element("pause").setAttribute("aria-label", element("pause").title);
        clearTimeout(timer); render(); if (!paused) refresh();
    });
    element("window").addEventListener("change", render);
    document.addEventListener("visibilitychange", () => { clearTimeout(timer); if (!document.hidden && !paused) refresh(); });
    document.querySelectorAll("[data-view]").forEach(button => button.addEventListener("click", () => {
        document.querySelectorAll("[data-view]").forEach(tab => tab.setAttribute("aria-pressed", String(tab === button)));
        document.querySelectorAll("[data-section]").forEach(section => { section.hidden = button.dataset.view !== "overview" && section.dataset.section !== button.dataset.view; });
    }));
    refresh();
})();