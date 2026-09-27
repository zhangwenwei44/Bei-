const memoryStore = (() => {
  const map = new Map();
  return {
    get: (key) => {
      const hit = map.get(key);
      if (!hit) return null;
      if (hit.expires && Date.now() > hit.expires) {
        map.delete(key);
        return null;
      }
      return hit.value;
    },
    set: (key, value, ttl) => map.set(key, { value, expires: ttl ? Date.now() + ttl : 0 })
  };
})();

const normalize = (raw, provider) => {
  if (!raw) return null;
  return {
    id: String(raw.id ?? raw.songmid ?? raw.songId ?? `${provider}-${Math.random().toString(36).slice(2)}`),
    title: String(raw.title ?? raw.name ?? "未知歌曲"),
    artist: String(raw.artist ?? raw.singer ?? "未知歌手"),
    url: raw.url ?? raw.playUrl ?? null,
    duration: Number(raw.duration ?? raw.time ?? 0) || 0,
    bitrate: raw.bitrate ?? 320,
    tags: Array.isArray(raw.tags) ? raw.tags.slice(0, 6) : ["标准"],
    lyrics: Array.isArray(raw.lyrics) ? raw.lyrics.map((l) => [Number(l[0]) || 0, l[1] ?? ""]) : [],
    art: raw.art ?? null,
    provider
  };
};

const createPublicSampleProvider = (config) => {
  const { base, indexes } = config;

  const seed = (n) => {
    const names = [
      ["有风无风皆自由", "王一佳"],
      ["Cloud Nine", "Aurora Fields"],
      ["Night Drive", "Retro Lane"],
      ["山海之间", "云上乐队"],
      ["Ocean Floor", "Blue Harbour"],
      ["Paper Planes", "Morning Tape"]
    ];
    return names[(n - 1) % names.length];
  };

  const track = (n) => {
    const [title, artist] = seed(n);
    return normalize(
      {
        id: `sample-${n}`,
        title,
        artist,
        url: `${base}SoundHelix-Song-${n}.mp3`,
        duration: 0,
        bitrate: 320,
        tags: n === 1 ? ["原唱", "高音质", "标准", "音效"] : ["公开测试音源", "标准"],
        lyrics: []
      },
      "publicSample"
    );
  };

  return {
    label: config.label,
    async getPlaylist() {
      return indexes.map(track);
    },
    async search(query) {
      const q = query.trim().toLowerCase();
      const all = indexes.map(track);
      if (!q) return all;
      return all.filter((t) => t.title.toLowerCase().includes(q) || t.artist.toLowerCase().includes(q));
    },
    async getTrack(id) {
      const n = Number(String(id).replace("sample-", ""));
      return indexes.includes(String(n)) ? track(n) : null;
    },
    async getUrl(track) {
      return track.url;
    },
    async getLyrics(track) {
      if (track.lyrics?.length) return track.lyrics;
      const defaults = {
        "sample-1": [
          [0, "有风 无风 皆自由"],
          [8, "行走人海中 做个某某某"],
          [15, "心若无所求"],
          [21, "有风无风皆自由"],
          [30, "路太长 弯太多"],
          [38, "尽头总会有出口"],
          [46, "把日子唱成歌"],
          [54, "走到哪 唱到哪"],
          [66, "有过 mist 也有过回头"],
          [74, "不为谁停留"],
          [82, "有风 无风 皆自由"]
        ]
      };
      return defaults[track.id] ?? [];
    }
  };
};

const createHttpProvider = (config) => {
  const build = (path, params = {}) => {
    const url = new URL(path.replace(/\{(\w+)\}/g, (_, key) => encodeURIComponent(params[key] ?? "")), config.base);
    return url.toString();
  };
  const getJSON = async (path, params) => {
    const res = await fetch(build(path, params), { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`音源接口 ${res.status}`);
    return res.json();
  };

  return {
    label: config.label,
    async getPlaylist() {
      const data = await getJSON(config.endpoints.playlist);
      const list = Array.isArray(data) ? data : data.data ?? [];
      return list.map((item) => normalize(item, "httpProvider"));
    },
    async search(query) {
      const data = await getJSON(config.endpoints.search, { q: query });
      const list = Array.isArray(data) ? data : data.data ?? [];
      return list.map((item) => normalize(item, "httpProvider"));
    },
    async getTrack(id) {
      const data = await getJSON(config.endpoints.url, { id });
      return normalize(data?.song ?? data, "httpProvider");
    },
    async getUrl(track) {
      const cached = memoryStore.get(`url:${track.id}`);
      if (cached) return cached;
      const data = await getJSON(config.endpoints.url, { id: track.id });
      const url = data?.url ?? data?.data?.url ?? track.url;
      memoryStore.set(`url:${track.id}`, url, AURORA_CONFIG.cache.urlTTL);
      return url;
    },
    async getLyrics(track) {
      const cached = memoryStore.get(`lyrics:${track.id}`);
      if (cached) return cached;
      const data = await getJSON(config.endpoints.lyrics, { id: track.id });
      const lines = (data?.lyrics ?? []).map((line) => {
        const m = String(line).match(/\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]/);
        const text = String(line).replace(/\[[^\]]*\]/g, "").trim() || "♪";
        if (!m) return [0, text];
        return [Number(m[1]) * 60 + Number(m[2]) + Number((m[3] ?? "0").padEnd(2, "0")) / 100, text];
      });
      memoryStore.set(`lyrics:${track.id}`, lines, AURORA_CONFIG.cache.lyricsTTL);
      return lines;
    }
  };
};

const DB_NAME = "aurora-music";
const STORE_NAME = "local-audio";
const openDB = () =>
  new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE_NAME, { keyPath: "id" });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });

const idbAll = async () => {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const req = db.transaction(STORE_NAME).objectStore(STORE_NAME).getAll();
    req.onsuccess = () => resolve(req.result ?? []);
    req.onerror = () => reject(req.error);
  });
};

const idbPut = async (record) => {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).put(record);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
};

const idbDelete = async (id) => {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readwrite");
    tx.objectStore(STORE_NAME).delete(id);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
};

const createLocalProvider = (config) => {
  const toTrack = (record) =>
    normalize(
      {
        ...record,
        url: record.blob ? URL.createObjectURL(record.blob) : record.url,
        artist: record.artist || "本地音频"
      },
      "localFiles"
    );

  return {
    label: "本地音频",
    async getPlaylist() {
      const rows = await idbAll();
      return rows.map(toTrack);
    },
    async search(query) {
      const q = query.trim().toLowerCase();
      const rows = await idbAll();
      return rows.map(toTrack).filter((t) => !q || t.title.toLowerCase().includes(q) || t.artist.toLowerCase().includes(q));
    },
    async getTrack(id) {
      const rows = await idbAll();
      const hit = rows.find((r) => r.id === id);
      return hit ? toTrack(hit) : null;
    },
    async getUrl(track) {
      return track.url;
    },
    async getLyrics() {
      return [];
    },
    async addFiles(fileList) {
      const files = [...fileList].filter((f) => f.type.startsWith("audio") || /\.(mp3|m4a|aac|wav|caf|aiff|flac|ogg)$/i.test(f.name));
      const added = [];
      for (const file of files) {
        const id = `local-${file.name}-${file.size}`;
        await idbPut({
          id,
          title: file.name.replace(/\.[^.]+$/, ""),
          artist: "本地音频",
          blob: file,
          tags: ["本地"],
          addedAt: Date.now()
        });
        added.push(toTrack({ id, title: file.name.replace(/\.[^.]+$/, ""), artist: "本地音频", blob: file, tags: ["本地"] }));
      }
      return added;
    },
    async remove(id) {
      await idbDelete(id);
    }
  };
};

const registry = {
  publicSample: () => createPublicSampleProvider(AURORA_CONFIG.providers.publicSample),
  httpProvider: () => createHttpProvider(AURORA_CONFIG.providers.httpProvider),
  localFiles: () => createLocalProvider({ label: "本地音频" })
};

const AuroraAPI = {
  provider: null,
  name: "",
  onError: null,

  async init(name = AURORA_CONFIG.activeProvider) {
    const key = registry[name] ? name : "publicSample";
    this.name = key;
    this.provider = registry[key]();
    return this.provider;
  },

  async use(name) {
    await this.init(name);
    return this.provider.getPlaylist();
  },

  label() {
    return this.provider?.label ?? "未知音源";
  },

  getPlaylist: () => AuroraAPI.provider.getPlaylist(),
  search: (q) => AuroraAPI.provider.search(q),
  getTrack: (id) => AuroraAPI.provider.getTrack(id),

  async resolve(track) {
    if (!track) return null;
    const [url, lyrics] = await Promise.all([
      this.provider.getUrl(track).catch(() => track.url),
      this.provider.getLyrics(track).catch(() => track.lyrics ?? [])
    ]);
    return { ...track, url, lyrics: lyrics?.length ? lyrics : track.lyrics ?? [] };
  },

  async addFiles(fileList) {
    if (typeof this.provider.addFiles === "function") return this.provider.addFiles(fileList);
    const files = [...fileList].filter((f) => f.type.startsWith("audio") || /\.(mp3|m4a|aac|wav|ogg|flac)$/i.test(f.name));
    return files.map((f) =>
      normalize(
        {
          id: `local-${f.name}-${f.size}`,
          title: f.name.replace(/\.[^.]+$/, ""),
          artist: "本地音频",
          url: URL.createObjectURL(f),
          tags: ["本地"]
        },
        "localFiles"
      )
    );
  },

  async removeTrack(id) {
    if (typeof this.provider.remove === "function") await this.provider.remove(id);
  }
};

window.AuroraAPI = AuroraAPI;
window.AuroraMemoryStore = memoryStore;
