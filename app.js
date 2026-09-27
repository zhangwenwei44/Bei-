const $ = (id) => document.getElementById(id);

const els = {
  bgArt: $("bgArt"), bg: $("bg"), lyrics: $("lyrics"), lyricsInner: $("lyricsInner"),
  heroTitle: $("heroTitle"), heroArtist: $("heroArtist"),
  songTitle: $("songTitle"), songArtist: $("songArtist"), btnFollow: $("btnFollow"),
  actLike: $("actLike"), likeCount: $("likeCount"), seek: $("seek"),
  curTime: $("curTime"), durTime: $("durTime"), btnPlay: $("btnPlay"),
  btnPrev: $("btnPrev"), btnNext: $("btnNext"), btnMode: $("btnMode"), btnQueue: $("btnQueue"),
  queueList: $("queueList"), queueCount: $("queueCount"), sheet: $("sheetQueue"),
  backdrop: $("sheetBackdrop"), toast: $("toast"), bitrate: $("bitrateChip"),
};

const MODES = ["order", "single", "shuffle"];
const MODE_TEXT = { order: "列表循环", single: "单曲循环", shuffle: "随机播放" };

const audio = new Audio();
audio.preload = "metadata";

const state = {
  tracks: [],
  index: -1,
  mode: 0,
  liked: new Set(),
  scrubbing: false,
};

const fmt = (s) => {
  if (!isFinite(s) || s < 0) s = 0;
  const m = Math.floor(s / 60);
  const r = Math.floor(s % 60);
  return `${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
};

const artFor = (seed) => {
  let h = 0;
  for (const ch of String(seed)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const a = h % 360, b = (a + 60 + (h >> 8) % 80) % 360;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="hsl(${a} 55% 45%)"/>
      <stop offset="1" stop-color="hsl(${b} 50% 22%)"/>
    </linearGradient></defs>
    <rect width="300" height="300" fill="url(#g)"/>
    <circle cx="150" cy="150" r="72" fill="rgba(255,255,255,.14)"/>
    <circle cx="150" cy="150" r="16" fill="rgba(255,255,255,.3)"/>
  </svg>`;
  return "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
};

const tintFor = (seed) => {
  let h = 0;
  for (const ch of String(seed)) h = (h * 37 + ch.charCodeAt(0)) >>> 0;
  return `linear-gradient(160deg, hsl(${h % 360} 45% 32%), hsl(${(h >> 6) % 360} 55% 12%))`;
};

const api = window.AuroraAPI;

async function boot() {
  try {
    await api.init(window.AURORA_CONFIG?.activeProvider);
    els.sourceLabel && (els.sourceLabel.textContent = `音源：${api.label()}`);
    const list = await api.getPlaylist();
    hydrate(list);
    renderQueue();
    if (list.length) load(0, false);
  } catch (err) {
    toast("音源加载失败，已回退到空列表");
    console.error(err);
  }
}

function hydrate(list) {
  list.forEach((t) => {
    t.id ??= `${t.artist}-${t.title}`;
    t.art ??= artFor(t.id);
    t.tags ??= ["标准"];
    t.lyrics ??= [];
  });
  state.tracks = list;
}

function current() {
  return state.tracks[state.index] || null;
}

function renderLyrics(track) {
  els.lyricsInner.innerHTML = "";
  const hero = document.createElement("div");
  hero.innerHTML = `<h1 class="hero-title"></h1><p class="hero-artist"></p>`;
  hero.querySelector(".hero-title").textContent = track.title;
  hero.querySelector(".hero-artist").textContent = track.artist;
  els.lyricsInner.appendChild(hero);

  if (!track.lyrics.length) {
    const p = document.createElement("div");
    p.className = "lyric-line";
    p.textContent = "纯音乐 · 暂无歌词";
    els.lyricsInner.appendChild(p);
    return;
  }
  track.lyrics.forEach(([time, text]) => {
    const d = document.createElement("div");
    d.className = "lyric-line";
    d.dataset.time = time;
    d.textContent = text;
    els.lyricsInner.appendChild(d);
  });
}

function syncLyric(time) {
  const lines = [...els.lyricsInner.querySelectorAll(".lyric-line")];
  if (!lines.length) return;
  let idx = -1;
  lines.forEach((el, i) => {
    if (+el.dataset.time <= time + 0.25) idx = i;
  });
  lines.forEach((el, i) => el.classList.toggle("active", i === idx));
  els.lyrics.classList.toggle("scrolled", idx > -1);
  if (idx > -1) {
    const el = lines[idx];
    const target = el.offsetTop - els.lyrics.clientHeight / 2 + el.offsetHeight / 2;
    els.lyricsInner.style.transform = `translateY(${-Math.max(0, target)}px)`;
  }
}

function paintMeta(track) {
  els.songTitle.textContent = track.title;
  els.songArtist.textContent = track.artist;
  if (track.art) els.bgArt.src = track.art;
  els.bg.style.setProperty("--tint", tintFor(track.id));
  const liked = state.liked.has(track.id);
  els.actLike.classList.toggle("liked", liked);
  els.likeCount.textContent = liked ? "1.2w" : "421";
  renderLyrics(track);
  syncLyric(0);
}

function load(index, autoplay = true) {
  if (index < 0 || index >= state.tracks.length) return;
  state.index = index;
  const t = current();
  paintMeta(t);
  renderQueue();
  els.durTime.textContent = fmt(0);
  els.seek.value = 0;
  els.seek.style.setProperty("--p", "0%");

  api
    .resolve(t)
    .then((resolved) => {
      if (state.index !== index) return;
      t.url = resolved.url;
      t.lyrics = resolved.lyrics;
      paintMeta(t);
      audio.src = resolved.url;
      audio.load();
      if (autoplay) play();
    })
    .catch(() => {
      toast("音源地址获取失败");
    });
}

function play() {
  audio.play().catch(() => toast("点击播放按钮开始播放"));
}

function toggle() {
  if (!current()) return load(0, true);
  audio.paused ? play() : audio.pause();
}

function step(dir) {
  const n = state.tracks.length;
  if (!n) return;
  if (state.mode === 2) {
    load(Math.floor(Math.random() * n), true);
    return;
  }
  load((state.index + dir + n) % n, true);
}

function nextTrack(auto = false) {
  if (state.mode === 1 && auto) {
    audio.currentTime = 0;
    play();
    return;
  }
  step(1);
}

function renderQueue(source) {
  const list = source ?? state.tracks;
  els.queueCount.textContent = list.length;
  els.queueList.innerHTML = "";
  list.forEach((t) => {
    const i = state.tracks.indexOf(t);
    const row = document.createElement("div");
    row.className = "q-item" + (i === state.index ? " on" : "");
    row.innerHTML = `<img class="q-thumb" alt=""><div class="q-info"><b></b><span></span></div><span class="dur"></span>`;
    row.querySelector(".q-thumb").src = t.art || artFor(t.id);
    row.querySelector("b").textContent = t.title;
    row.querySelector("span").textContent = t.artist;
    row.querySelector(".dur").textContent = t.duration ? fmt(t.duration) : "--:--";
    row.addEventListener("click", () => {
      if (i === -1) {
        hydrate(state.tracks.concat([t]));
        load(state.tracks.length - 1, true);
      } else {
        load(i, true);
      }
      closeSheet();
    });
    els.queueList.appendChild(row);
  });
}

function openSheet() {
  els.sheet.classList.add("show");
  els.backdrop.classList.add("show");
  els.sheet.setAttribute("aria-hidden", "false");
}
function closeSheet() {
  els.sheet.classList.remove("show");
  els.backdrop.classList.remove("show");
  els.sheet.setAttribute("aria-hidden", "true");
}

let toastTimer;
function toast(msg) {
  els.toast.textContent = msg;
  els.toast.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => els.toast.classList.remove("show"), 1600);
}

audio.addEventListener("play", () => els.btnPlay.classList.add("playing"));
audio.addEventListener("pause", () => els.btnPlay.classList.remove("playing"));
audio.addEventListener("timeupdate", () => {
  const { currentTime: t, duration: d } = audio;
  if (!state.scrubbing && isFinite(d) && d > 0) {
    els.seek.value = Math.round((t / d) * 1000);
    els.seek.style.setProperty("--p", `${(t / d) * 100}%`);
  }
  els.curTime.textContent = fmt(t);
  syncLyric(t);
});
audio.addEventListener("loadedmetadata", () => {
  const t = current();
  if (!t) return;
  t.duration = audio.duration;
  els.durTime.textContent = fmt(audio.duration);
  els.bitrate.textContent = "▼ 320 KB/s";
  renderQueue();
});
audio.addEventListener("ended", () => nextTrack(true));
audio.addEventListener("error", () => {
  toast("音源加载失败，请添加本地音频或切换音源");
});

els.seek.addEventListener("input", () => {
  state.scrubbing = true;
  const p = els.seek.value / 10;
  els.seek.style.setProperty("--p", `${p}%`);
  els.curTime.textContent = fmt((p / 100) * (audio.duration || 0));
});
["change", "pointerup", "touchend"].forEach((ev) =>
  els.seek.addEventListener(ev, () => {
    if (!state.scrubbing) return;
    state.scrubbing = false;
    if (isFinite(audio.duration)) audio.currentTime = (els.seek.value / 1000) * audio.duration;
  })
);

els.btnPlay.addEventListener("click", toggle);
els.btnPrev.addEventListener("click", () => step(-1));
els.btnNext.addEventListener("click", () => step(1));
els.btnQueue.addEventListener("click", () => (els.sheet.classList.contains("show") ? closeSheet() : openSheet()));
$("btnCloseQueue").addEventListener("click", closeSheet);
els.backdrop.addEventListener("click", closeSheet);
$("btnCollapse").addEventListener("click", () => (document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.()));

els.btnMode.addEventListener("click", () => {
  state.mode = (state.mode + 1) % MODES.length;
  toast(MODE_TEXT[MODES[state.mode]]);
});

els.btnFollow.addEventListener("click", () => {
  const t = current();
  if (!t) return;
  els.btnFollow.classList.toggle("on");
  els.btnFollow.textContent = els.btnFollow.classList.contains("on") ? "已关注" : "关注";
  toast(els.btnFollow.textContent);
});

els.actLike.addEventListener("click", () => {
  const t = current();
  if (!t) return;
  state.liked.has(t.id) ? state.liked.delete(t.id) : state.liked.add(t.id);
  paintMeta(t);
});

const actStub = (id, msg) => $(id).addEventListener("click", () => toast(msg));
actStub("actComment", "评论区开发中");
$("actDownload").addEventListener("click", () => {
  const t = current();
  if (!t?.url) return;
  const a = document.createElement("a");
  a.href = t.url;
  a.download = `${t.artist} - ${t.title}.mp3`;
  a.click();
});
actStub("actRingtone", "已设为铃声");
actStub("actComment2", "暂无 4K 视频");
actStub("actMore", "更多操作");
$("btnCast").addEventListener("click", () => toast("暂无可用投屏设备"));
[$("btnVip"), $("btnVipOpen")].forEach((b) => b.addEventListener("click", (e) => {
  e.preventDefault();
  toast("会员功能演示版");
}));

$("btnClearQueue").addEventListener("click", () => {
  audio.pause();
  state.tracks = [];
  state.index = -1;
  renderQueue();
  toast("播放列表已清空");
});

$("fileInput").addEventListener("change", async (e) => {
  const files = e.target.files;
  if (!files.length) return;
  const added = await api.addFiles(files);
  if (!added.length) return toast("没有可识别的音频文件");
  hydrate(state.tracks.concat(added));
  if (state.index === -1) load(0, false);
  else renderQueue();
  toast(`已添加 ${added.length} 首`);
  e.target.value = "";
});

let searchTimer;
$("searchInput")?.addEventListener("input", (e) => {
  clearTimeout(searchTimer);
  const q = e.target.value;
  searchTimer = setTimeout(async () => {
    try {
      const results = await api.search(q);
      renderQueue(results);
    } catch {
      toast("搜索失败");
    }
  }, 260);
});

document.addEventListener("keydown", (e) => {
  if (e.code === "Space") { e.preventDefault(); toggle(); }
  if (e.code === "ArrowRight") step(1);
  if (e.code === "ArrowLeft") step(-1);
  if (e.code === "ArrowUp") audio.volume = Math.min(1, audio.volume + .1);
  if (e.code === "ArrowDown") audio.volume = Math.max(0, audio.volume - .1);
});

$("btnSwitchSource").addEventListener("click", async () => {
  const order = ["publicSample", "localFiles", "httpProvider"];
  const next = order[(order.indexOf(api.name) + 1) % order.length];
  if (next === "httpProvider" && !window.AURORA_CONFIG.providers.httpProvider.base) {
    toast("请先在 js/config.js 填写 httpProvider.base");
    return;
  }
  audio.pause();
  const list = await api.use(next);
  hydrate(list);
  els.sourceLabel.textContent = `音源：${api.label()}`;
  if (list.length) load(0, false);
  else {
    state.index = -1;
    renderQueue();
    toast("该音源暂无内容");
  }
});

audio.volume = 0.9;
boot();
