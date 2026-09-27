const AURORA_CONFIG = {
  activeProvider: "publicSample",
  providers: {
    publicSample: {
      label: "公开测试音源",
      base: "https://www.soundhelix.com/examples/mp3/",
      indexes: ["1", "2", "3", "8", "10", "11"]
    },
    httpProvider: {
      label: "自建 HTTP 音源",
      base: "",
      endpoints: {
        search: "/search?q={q}",
        playlist: "/playlist",
        url: "/song/{id}/url",
        lyrics: "/song/{id}/lyrics"
      }
    }
  },
  cache: { lyricsTTL: 6 * 60 * 60 * 1000, urlTTL: 5 * 60 * 1000 }
};
