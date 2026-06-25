const { createApp } = Vue;

createApp({
  data() {
    return {
      dates: [],
      selectedDate: 'current',
      snapshot: {
        total_domains: 0,
        total_up: 0,
        total_down: 0,
        hosts: {},
        timestamp: null
      },
      statusChart: null,
      latencyChart: null,
      ws: null,
      isLive: true,
      error: null,
      loading: false,
    };
  },
  computed: {
    formattedTimestamp() {
      const ts = this.snapshot.timestamp;
      if (!ts) return '-';
      const d = typeof ts === 'string' ? new Date(ts) : new Date(ts);
      return d.toLocaleString('id-ID', {
        dateStyle: 'medium',
        timeStyle: 'short',
      });
    },
    sortedHosts() {
      if (!this.snapshot.hosts) return [];
      return Object.values(this.snapshot.hosts).sort((a, b) => {
        if (a.status === 'down' && b.status !== 'down') return -1;
        if (a.status !== 'down' && b.status === 'down') return 1;
        return (b.latency || 0) - (a.latency || 0);
      });
    },
    statusLabel() {
      if (this.loading) return 'Memuat...';
      if (this.error) return 'Error';
      return this.isLive ? 'Realtime' : 'Laporan Statis';
    },
    statusClass() {
      if (this.loading) return 'loading';
      if (this.error) return 'error';
      return this.isLive ? 'live' : 'static';
    },
  },
  methods: {
    formatDate(value) {
      if (value === 'current') return 'Realtime';
      const p = value.replace(/_/g, '-').split('-');
      if (p.length >= 3) {
        const months = ['Jan','Feb','Mar','Apr','Mei','Jun','Jul','Agu','Sep','Okt','Nov','Des'];
        const m = parseInt(p[1], 10) - 1;
        return `${p[2]} ${months[m] || p[1]} ${p[0]}${p[3] ? ' '+p[3]+':'+p[4] : ''}`;
      }
      return value;
    },

    async fetchReports() {
      try {
        const res = await fetch('/reports');
        if (!res.ok) throw new Error('Gagal memuat daftar laporan');
        const data = await res.json();
        this.dates = data.dates || [];
      } catch (err) {
        this.error = err.message;
      }
    },

    async loadCurrent() {
      this.loading = true;
      this.error = null;
      this.isLive = true;
      try {
        const res = await fetch('/');
        if (!res.ok) throw new Error('Gagal memuat snapshot');
        const data = await res.json();
        this.applySnapshot(data);
        this.connectWebSocket();
      } catch (err) {
        this.error = err.message;
      } finally {
        this.loading = false;
      }
    },

    async loadSelectedDate() {
      if (this.selectedDate === 'current') {
        this.loadCurrent();
        return;
      }
      this.loading = true;
      this.error = null;
      this.isLive = false;
      this.disconnectWebSocket();
      try {
        const res = await fetch(`/reports/${this.selectedDate}`);
        if (!res.ok) throw new Error(`Laporan tidak ditemukan (${res.status})`);
        const data = await res.json();
        this.applySnapshot(data);
      } catch (err) {
        this.error = err.message;
        this.resetSnapshot();
      } finally {
        this.loading = false;
      }
    },

    applySnapshot(data) {
      const hosts = {};
      if (data.hosts) {
        if (Array.isArray(data.hosts)) {
          data.hosts.forEach(h => {
            const name = h.host || h.domain || 'unknown';
            hosts[name] = this.makeHost(h, name);
          });
        } else if (typeof data.hosts === 'object') {
          Object.keys(data.hosts).forEach(key => {
            hosts[key] = this.makeHost(data.hosts[key], key);
          });
        }
      }
      const hostList = Object.values(hosts);
      this.snapshot = {
        total_domains: data.total_domains ?? hostList.length,
        total_up: data.total_up ?? hostList.filter(h => h.status === 'up').length,
        total_down: data.total_down ?? hostList.filter(h => h.status === 'down').length,
        hosts: hosts,
        timestamp: data.timestamp || null,
      };
      this.$nextTick(() => {
        this.renderCharts();
      });
    },

    makeHost(h, fallbackKey) {
      if (!h) return { host: fallbackKey, status: 'unknown', latency: null, uptime_percent: 0 };
      let status = (h.status || '').toLowerCase();
      if (!status || status === 'unknown') status = h.up === 1 ? 'up' : 'down';
      return {
        host: h.host || fallbackKey,
        status: status,
        latency: h.latency != null ? h.latency : null,
        uptime_percent: h.uptime_percent ?? 0,
        timestamp: h.timestamp || null,
      };
    },

    resetSnapshot() {
      this.snapshot = { total_domains: 0, total_up: 0, total_down: 0, hosts: {}, timestamp: null };
      this.$nextTick(() => this.renderCharts());
    },

    refresh() {
      this.error = null;
      this.disconnectWebSocket();
      if (this.selectedDate === 'current') {
        this.loadCurrent();
      } else {
        this.loadSelectedDate();
      }
    },

    // ============ CHART ============
    renderCharts() {
      this.destroyCharts();

      const sCanvas = document.getElementById('statusChart');
      const lCanvas = document.getElementById('latencyChart');
      if (!sCanvas || !lCanvas) return;

      const up = this.snapshot.total_up || 0;
      const down = this.snapshot.total_down || 0;

      // === Status Doughnut ===
      this.statusChart = new Chart(sCanvas.getContext('2d'), {
        type: 'doughnut',
        data: {
          labels: ['Up', 'Down'],
          datasets: [{
            data: [up, down],
            backgroundColor: ['#22c55e', '#ef4444'],
            borderColor: '#1e293b',
            borderWidth: 3,
          }],
        },
        options: {
          responsive: true,
          maintainAspectRatio: true,
          cutout: '65%',
          animation: { duration: 0 },
          plugins: {
            legend: {
              position: 'bottom',
              labels: { color: '#cbd5e1', padding: 16, usePointStyle: true },
            },
          },
        },
      });

      // === Latency Bar ===
      const hosts = this.snapshot.hosts || {};
      const top10 = Object.values(hosts)
        .filter(h => h.latency != null && h.status === 'up')
        .sort((a, b) => b.latency - a.latency)
        .slice(0, 10);

      this.latencyChart = new Chart(lCanvas.getContext('2d'), {
        type: 'bar',
        data: {
          labels: top10.map(h => h.host.length > 28 ? h.host.substring(0, 25) + '...' : h.host),
          datasets: [{
            label: 'Latency (s)',
            data: top10.map(h => h.latency),
            backgroundColor: top10.map(h => {
              if (h.latency > 8) return 'rgba(239,68,68,0.7)';
              if (h.latency > 5) return 'rgba(251,191,36,0.7)';
              return 'rgba(56,189,248,0.7)';
            }),
            borderRadius: 4,
          }],
        },
        options: {
          responsive: true,
          maintainAspectRatio: true,
          indexAxis: 'y',
          animation: { duration: 0 },
          scales: {
            x: { beginAtZero: true, ticks: { color: '#94a3b8' }, grid: { color: 'rgba(148,163,184,0.1)' } },
            y: { ticks: { color: '#cbd5e1', font: { size: 11 } }, grid: { display: false } },
          },
          plugins: { legend: { display: false } },
        },
      });
    },

    destroyCharts() {
      if (this.statusChart) {
        try { this.statusChart.destroy(); } catch (e) {}
        this.statusChart = null;
      }
      if (this.latencyChart) {
        try { this.latencyChart.destroy(); } catch (e) {}
        this.latencyChart = null;
      }
    },

    // ============ WEBSOCKET ============
    connectWebSocket() {
      if (!this.isLive) return;
      this.disconnectWebSocket();
      const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
      try {
        this.ws = new WebSocket(`${proto}://${window.location.host}/ws`);
        this.ws.addEventListener('open', () => { this.ws.send('hello'); });
        this.ws.addEventListener('message', (event) => {
          try {
            const payload = JSON.parse(event.data);
            if (payload.type === 'snapshot') {
              this.applySnapshot(payload.data);
            } else if (payload.type === 'scan_update') {
              this.handleScanUpdate(payload);
            }
          } catch (e) {}
        });
        this.ws.addEventListener('close', () => {
          this.ws = null;
          if (this.isLive) setTimeout(() => { if (this.isLive) this.connectWebSocket(); }, 3000);
        });
        this.ws.addEventListener('error', () => { this.ws = null; });
      } catch (e) {}
    },

    handleScanUpdate(payload) {
      const hosts = { ...this.snapshot.hosts };
      hosts[payload.host] = {
        host: payload.host,
        status: payload.up ? 'up' : 'down',
        latency: payload.latency,
        uptime_percent: payload.uptime_percent || 0,
        timestamp: payload.timestamp || null,
      };
      const hostList = Object.values(hosts);
      this.snapshot = {
        ...this.snapshot,
        hosts: hosts,
        total_up: hostList.filter(h => h.status === 'up').length,
        total_down: hostList.filter(h => h.status === 'down').length,
        total_domains: hostList.length,
      };
      this.$nextTick(() => this.renderCharts());
    },

    disconnectWebSocket() {
      if (this.ws) {
        try { this.ws.onclose = null; this.ws.close(); } catch (e) {}
        this.ws = null;
      }
    },
  },

  mounted() {
    this.fetchReports().then(() => {
      this.loadCurrent();
    });
  },

  beforeUnmount() {
    this.isLive = false;
    this.disconnectWebSocket();
    this.destroyCharts();
  },
}).mount('#app');