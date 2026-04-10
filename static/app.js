const { createApp } = Vue;

createApp({
  data() {
    return {
      dates: [],
      selectedDate: 'current',
      snapshot: {},
      statusChart: null,
      latencyChart: null,
      ws: null,
      isLive: true,
      error: null,
    };
  },
  computed: {
    formattedTimestamp() {
      const timestamp = this.snapshot.timestamp;
      if (!timestamp) return '-';
      return new Date(timestamp).toLocaleString('id-ID', {
        dateStyle: 'medium',
        timeStyle: 'short',
      });
    },
    sortedHosts() {
      if (!this.snapshot.hosts) return [];
      return Object.values(this.snapshot.hosts).sort((a, b) => {
        if (a.status === b.status) {
          return (b.latency || 0) - (a.latency || 0);
        }
        return a.status === 'down' ? -1 : 1;
      });
    },
    statusLabel() {
      return this.isLive ? 'Realtime' : 'Static laporan';
    },
    statusClass() {
      return this.isLive ? 'live' : 'static';
    },
  },
  methods: {
    formatDate(value) {
      return value === 'current' ? 'Realtime' : value.replace(/_/g, '-');
    },
    async fetchReports() {
      try {
        const response = await fetch('/reports');
        if (!response.ok) throw new Error('Gagal memuat daftar laporan');
        const data = await response.json();
        this.dates = data.dates || [];
        if (this.selectedDate === 'current') {
          this.loadCurrent();
        }
      } catch (err) {
        this.error = err.message;
      }
    },
    async loadCurrent() {
      this.isLive = true;
      this.connectWebSocket();
      try {
        const response = await fetch('/');
        if (!response.ok) throw new Error('Gagal memuat snapshot realtime');
        const data = await response.json();
        this.snapshot = data;
        this.refreshCharts();
      } catch (err) {
        this.error = err.message;
      }
    },
    async loadSelectedDate() {
      if (this.selectedDate === 'current') {
        this.loadCurrent();
        return;
      }
      this.isLive = false;
      this.disconnectWebSocket();
      try {
        const response = await fetch(`/reports/${this.selectedDate}`);
        if (!response.ok) throw new Error('Laporan tidak ditemukan');
        this.snapshot = await response.json();
        this.refreshCharts();
      } catch (err) {
        this.error = err.message;
        this.snapshot = {};
      }
    },
    refresh() {
      if (this.selectedDate === 'current') {
        this.loadCurrent();
      } else {
        this.loadSelectedDate();
      }
    },
    createCharts() {
      const statusCtx = document.getElementById('statusChart').getContext('2d');
      const latencyCtx = document.getElementById('latencyChart').getContext('2d');

      this.statusChart = new Chart(statusCtx, {
        type: 'doughnut',
        data: {
          labels: ['Up', 'Down'],
          datasets: [{
            data: [0, 0],
            backgroundColor: ['#22c55e', '#ef4444'],
            borderColor: 'rgba(255,255,255,0.04)',
            borderWidth: 2,
          }],
        },
        options: {
          responsive: true,
          plugins: {
            legend: { position: 'bottom', labels: { color: '#cbd5e1' } },
          },
        },
      });

      this.latencyChart = new Chart(latencyCtx, {
        type: 'bar',
        data: {
          labels: [],
          datasets: [{
            label: 'Latency (s)',
            data: [],
            backgroundColor: '#38bdf8',
          }],
        },
        options: {
          responsive: true,
          scales: {
            x: { ticks: { color: '#cbd5e1' }, grid: { display: false } },
            y: { ticks: { color: '#cbd5e1' }, grid: { color: 'rgba(148,163,184,0.12)' }, beginAtZero: true },
          },
          plugins: {
            legend: { display: false },
          },
        },
      });
    },
    refreshCharts() {
      const up = this.snapshot.total_up || 0;
      const down = this.snapshot.total_down || 0;
      if (this.statusChart) {
        this.statusChart.data.datasets[0].data = [up, down];
        this.statusChart.update();
      }

      const latencyHosts = Object.values(this.snapshot.hosts || {})
        .filter((item) => item.latency !== null)
        .sort((a, b) => (b.latency || 0) - (a.latency || 0))
        .slice(0, 10);

      if (this.latencyChart) {
        this.latencyChart.data.labels = latencyHosts.map((item) => item.host);
        this.latencyChart.data.datasets[0].data = latencyHosts.map((item) => item.latency || 0);
        this.latencyChart.update();
      }
    },
    connectWebSocket() {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
      this.ws = new WebSocket(`${window.location.protocol === 'https:' ? 'wss' : 'ws'}://${window.location.host}/ws`);

      this.ws.addEventListener('open', () => {
        this.ws.send('hello');
      });

      this.ws.addEventListener('message', (event) => {
        const payload = JSON.parse(event.data);
        if (payload.type === 'snapshot') {
          this.snapshot = payload.data;
          this.refreshCharts();
        } else if (payload.type === 'scan_update') {
          if (this.snapshot.hosts) {
            this.snapshot.hosts[payload.host] = {
              host: payload.host,
              status: payload.up ? 'up' : 'down',
              latency: payload.latency,
              uptime_percent: payload.uptime_percent,
              timestamp: payload.timestamp * 1000,
            };
            this.snapshot.total_up = this.snapshot.total_up || 0;
            this.snapshot.total_down = this.snapshot.total_down || 0;
            this.snapshot.total_up = Object.values(this.snapshot.hosts).filter((item) => item.status === 'up').length;
            this.snapshot.total_down = Object.values(this.snapshot.hosts).filter((item) => item.status === 'down').length;
            this.refreshCharts();
          }
        }
      });

      this.ws.addEventListener('close', () => {
        this.ws = null;
      });

      this.ws.addEventListener('error', () => {
        this.ws = null;
      });
    },
    disconnectWebSocket() {
      if (this.ws) {
        this.ws.close();
        this.ws = null;
      }
    },
  },
  mounted() {
    this.createCharts();
    this.fetchReports();
  },
}).mount('#app');
